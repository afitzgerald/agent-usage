import AgentUsageModel
import Foundation

/// `agent-usage refresh` — one pass, run by launchd every 5 minutes: fetch the
/// quota, count what the transcripts gained since the last run (`--scan`
/// recounts them from scratch), write `usage.json`, exit.
/// launchd does the scheduling, so there is no loop here.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("agent-usage: \(message)\n".utf8))
    exit(1)
}

let arguments = CommandLine.arguments.dropFirst()
if arguments.contains("--selftest") { SelfTest.run() }
guard (arguments.first ?? "refresh") == "refresh" else {
    FileHandle.standardError.write(Data("usage: agent-usage [refresh [--scan] | --selftest]\n".utf8))
    exit(2)
}

let directory = Snapshot.directory
do {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
} catch {
    fail("can't create \(directory.path): \(error)")
}

// One run at a time. launchd never overlaps its own runs, but a manual
// `agent-usage refresh` can land on top of one, and two renewals racing spend
// the same refresh token twice — the loser's copy is rotated away. The kernel
// drops the lock when the process exits, crash included.
let lock = open(directory.appending(path: "refresh.lock").path, O_CREAT | O_RDWR, 0o600)
guard lock >= 0, flock(lock, LOCK_EX | LOCK_NB) == 0 else {
    FileHandle.standardError.write(Data("agent-usage: another refresh is running\n".utf8))
    exit(0)
}

let stateURL = directory.appending(path: "state.json")
var state = (try? Data(contentsOf: stateURL))
    .flatMap { try? Snapshot.decoder.decode(QuotaRefresh.State.self, from: $0) } ?? QuotaRefresh.State()
// A snapshot from an unknown schema is treated as no snapshot: the next write
// replaces it with one this build can stand behind.
let snapshot = try? Snapshot.load()
let previous = snapshot?.agent(AgentUsage.claude)
let previousCodex = snapshot?.agent(AgentUsage.codex)
let now = Date()
let forceScan = arguments.contains("--scan")

let quota = await QuotaRefresh.run(previous: previous?.quota, state: &state, now: now)
let codexQuota = await Codex.quota(previous: previousCodex?.quota, now: now)
// Scan progress, not part of the published file. Lost or unreadable is a
// full recount, so plain JSON with no schema check of its own.
func loadScanState<T: Decodable>(_ type: T.Type, _ url: URL) -> T? {
    forceScan ? nil : (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(type, from: $0) }
}
let claudeScanURL = directory.appending(path: "claude-scan.json")
let codexScanURL = directory.appending(path: "codex-scan.json")
let (tokens, claudeScan) = TokenScan.update(loadScanState(TokenScan.State.self, claudeScanURL), now: now)
let (codexTokens, codexScan) = CodexScan.update(loadScanState(CodexScan.State.self, codexScanURL), now: now)

do {
    // Atomic: readers poll this file, and a half-written one would decode as
    // garbage on exactly the read that races the write.
    try Snapshot.encoder.encode(Snapshot(generatedAt: Date(), agents: [
        AgentUsage(agent: AgentUsage.claude, quota: quota, tokens: tokens),
        AgentUsage(agent: AgentUsage.codex, quota: codexQuota, tokens: codexTokens),
    ]))
        .write(to: Snapshot.defaultURL, options: .atomic)
    if Models.isDue(try? ModelCatalog.load(), now: now) {
        try Snapshot.encoder.encode(Models.catalog(now: now)).write(to: ModelCatalog.defaultURL, options: .atomic)
    }
    try Snapshot.encoder.encode(state).write(to: stateURL, options: .atomic)
    // After usage.json: a run that dies between the two writes re-reads the
    // same appends next time from the older state, and counts them once.
    try JSONEncoder().encode(claudeScan).write(to: claudeScanURL, options: .atomic)
    try JSONEncoder().encode(codexScan).write(to: codexScanURL, options: .atomic)
} catch {
    fail("can't write to \(directory.path): \(error)")
}
