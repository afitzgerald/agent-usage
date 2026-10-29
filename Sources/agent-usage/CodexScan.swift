import AgentUsageModel
import Foundation

enum CodexScan {
    static func scan(root: URL = Codex.home, now: Date = Date()) -> Tokens {
        let newest = TokenScan.localEpochDay(of: now)
        let oldest = newest - TokenScan.windowDays + 1
        let cutoff = now.addingTimeInterval(-35 * 86400)
        let offset = TimeZone.current.secondsFromGMT(for: now) / 60
        var days: [Int: TokenCounts] = [:]
        var models: [String: TokenCounts] = [:]
        var seen = Set<String>()
        for folder in ["sessions", "archived_sessions"] {
            guard let walker = FileManager.default.enumerator(at: root.appending(path: folder), includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in walker {
                guard url.pathExtension == "jsonl",
                      let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                      modified >= cutoff, let data = try? Data(contentsOf: url),
                      let content = String(data: data, encoding: .utf8) else { continue }
                // The same rollout can be present in both directories.
                guard seen.insert(url.lastPathComponent).inserted else { continue }
                var previous: [String: Int] = [:]
                var model = "Unknown"
                var forked = false
                for line in content.split(separator: "\n") {
                    guard let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                          let payload = obj["payload"] as? [String: Any] else { continue }
                    if obj["type"] as? String == "session_meta" { forked = payload["forked_from_id"] != nil }
                    if obj["type"] as? String == "turn_context", let name = payload["model"] as? String { model = name }
                    guard payload["type"] as? String == "token_count",
                          let info = payload["info"] as? [String: Any],
                          let total = info["total_token_usage"] as? [String: Int] else { continue }
                    let keys = ["input_tokens", "cached_input_tokens", "output_tokens"]
                    let delta = keys.map { max(0, (total[$0] ?? 0) - (previous[$0] ?? 0)) }
                    let first = previous.isEmpty
                    previous = total
                    // Forked rollouts can inherit their parent's cumulative total.
                    if first && forked { continue }
                    guard delta.contains(where: { $0 > 0 }),
                          let timestamp = obj["timestamp"] as? String,
                          let day = TokenScan.localEpochDay(iso8601: timestamp, offsetMinutes: offset),
                          day >= oldest, day <= newest else { continue }
                    let cached = min(delta[0], delta[1])
                    let counts = TokenCounts(input: delta[0] - cached, output: delta[2], cacheRead: cached, requests: 1)
                    days[day, default: TokenCounts()].add(counts)
                    models[model, default: TokenCounts()].add(counts)
                }
            }
        }
        let history = days.isEmpty ? [] : (oldest...newest).map { Day(day: TokenScan.isoDay($0), usage: days[$0] ?? TokenCounts()) }
        return Tokens(updatedAt: now, windowDays: TokenScan.windowDays, days: history, models: TokenScan.ranked(models))
    }
}
