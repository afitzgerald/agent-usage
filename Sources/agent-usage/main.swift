import AgentUsageModel
import Foundation

/// `agent-usage refresh` — one pass, run by launchd every 5 minutes: fetch the
/// quota, rescan the transcripts if that's due, write `usage.json`, exit.
/// launchd does the scheduling, so there is no loop here.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("agent-usage: \(message)\n".utf8))
    exit(1)
}

let arguments = CommandLine.arguments.dropFirst()
if arguments.contains("--selftest") { SelfTest.run() }
guard (arguments.first ?? "refresh") == "refresh" else {
    FileHandle.standardError.write(Data("usage: agent-usage [refresh | --selftest]\n".utf8))
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
let previous = try? Snapshot.load()
let now = Date()

let quota = await QuotaRefresh.run(previous: previous?.quota, state: &state, now: now)
let tokens = TokenScan.isDue(previous?.tokens, now: now) ? TokenScan.scan(now: now) : previous?.tokens

do {
    // Atomic: readers poll this file, and a half-written one would decode as
    // garbage on exactly the read that races the write.
    try Snapshot.encoder.encode(Snapshot(generatedAt: Date(), quota: quota, tokens: tokens))
        .write(to: Snapshot.defaultURL, options: .atomic)
    try Snapshot.encoder.encode(state).write(to: stateURL, options: .atomic)
} catch {
    fail("can't write to \(directory.path): \(error)")
}
