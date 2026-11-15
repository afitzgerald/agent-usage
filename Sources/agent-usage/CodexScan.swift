import AgentUsageModel
import Foundation

enum CodexScan {
    /// Per rollout, not running totals like Claude's: Codex records carry no
    /// request ID to de-duplicate a re-read with, so a rollout read again from
    /// the top replaces what it contributed instead of adding to it.
    struct State: Codable {
        static let version = 1
        var version = State.version
        var offsetMinutes: Int
        /// Keyed by file name: the same rollout moves from `sessions` to
        /// `archived_sessions`.
        var files: [String: Rollout] = [:]
    }

    struct Rollout: Codable {
        var mark: Tail.Mark
        /// The cumulative total the next delta is measured from.
        var previous: [String: Int] = [:]
        var model = "Unknown"
        var forked = false
        /// Local day → model → usage.
        var usage: [Int: [String: TokenCounts]] = [:]
    }

    /// A whole scan from nothing. Tests only; `refresh` goes through `update`.
    static func scan(root: URL = Codex.home, now: Date = Date()) -> Tokens {
        update(nil, root: root, now: now).tokens
    }

    static func update(_ previousState: State?, root: URL = Codex.home, now: Date = Date()) -> (tokens: Tokens, state: State) {
        let newest = TokenScan.localEpochDay(of: now)
        let oldest = newest - TokenScan.windowDays + 1
        let offset = TimeZone.current.secondsFromGMT(for: now) / 60
        let old = previousState.flatMap { $0.version == State.version && $0.offsetMinutes == offset ? $0 : nil }
        var state = State(offsetMinutes: offset)
        for folder in ["sessions", "archived_sessions"] {
            for url in TokenScan.recentLogs(under: root.appending(path: folder), now: now) { autoreleasepool {
                let name = url.lastPathComponent
                // The same rollout can be present in both directories.
                guard state.files[name] == nil else { return }
                let known = old?.files[name]
                guard let read = Tail.read(url, after: known?.mark) else {
                    state.files[name] = known
                    return
                }
                var rollout = read.fresh ? Rollout(mark: read.mark) : known!
                rollout.mark = read.mark
                for line in String(decoding: read.data, as: UTF8.self).split(separator: "\n") {
                    guard let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                          let payload = obj["payload"] as? [String: Any] else { continue }
                    if obj["type"] as? String == "session_meta" { rollout.forked = payload["forked_from_id"] != nil }
                    if obj["type"] as? String == "turn_context", let name = payload["model"] as? String { rollout.model = name }
                    guard payload["type"] as? String == "token_count",
                          let info = payload["info"] as? [String: Any],
                          let total = info["total_token_usage"] as? [String: Int] else { continue }
                    let keys = ["input_tokens", "cached_input_tokens", "output_tokens"]
                    let delta = keys.map { max(0, (total[$0] ?? 0) - (rollout.previous[$0] ?? 0)) }
                    let first = rollout.previous.isEmpty
                    rollout.previous = total
                    // Forked rollouts can inherit their parent's cumulative total.
                    if first && rollout.forked { continue }
                    guard delta.contains(where: { $0 > 0 }),
                          let timestamp = obj["timestamp"] as? String,
                          let day = TokenScan.localEpochDay(iso8601: timestamp, offsetMinutes: offset),
                          day >= oldest, day <= newest else { continue }
                    let cached = min(delta[0], delta[1])
                    let counts = TokenCounts(input: delta[0] - cached, output: delta[2], cacheRead: cached, requests: 1)
                    rollout.usage[day, default: [:]][rollout.model, default: TokenCounts()].add(counts)
                }
                rollout.usage = rollout.usage.filter { $0.key >= oldest }
                state.files[name] = rollout
            } }
        }
        var totals: [Int: [String: TokenCounts]] = [:]
        for rollout in state.files.values {
            for (day, models) in rollout.usage {
                for (model, usage) in models { totals[day, default: [:]][model, default: TokenCounts()].add(usage) }
            }
        }
        return (TokenScan.tokens(from: totals, now: now), state)
    }
}
