import AgentUsageModel
import Foundation

enum Codex {
    static var home: URL {
        if let path = ProcessInfo.processInfo.environment["CODEX_HOME"], !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex")
    }

    static func quota(previous: Quota?, now: Date) async -> Quota {
        func result(_ status: Quota.Status, keep: Bool = false) -> Quota {
            if keep, var old = previous { old.status = status; return old }
            return Quota(status: status, updatedAt: nil, windows: [], spend: nil)
        }
        let auth = home.appending(path: "auth.json")
        guard FileManager.default.fileExists(atPath: auth.path) else { return result(.idle) }
        guard let data = try? Data(contentsOf: auth),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tokens = json["tokens"] as? [String: Any],
              let token = tokens["access_token"] as? String, !token.isEmpty else {
            return result(.failed, keep: true)
        }
        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let account = tokens["account_id"] as? String, !account.isEmpty {
            request.setValue(account, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return result(.failed, keep: true) }
            if http.statusCode == 401 || http.statusCode == 403 { return result(.signedOut) }
            guard http.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let windows = windows(from: json) else { return result(.failed, keep: true) }
            return Quota(status: .ok, updatedAt: now, windows: windows, spend: nil)
        } catch { return result(.failed, keep: true) }
    }

    static func windows(from json: [String: Any]) -> [QuotaWindow]? {
        guard let limits = json["rate_limit"] as? [String: Any] else { return nil }
        var windows: [QuotaWindow] = []
        func append(_ source: [String: Any], _ key: String, _ kind: String, _ model: String? = nil) {
            guard let window = source[key] as? [String: Any],
                  let percent = window["used_percent"] as? NSNumber else { return }
            let reset = (window["reset_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            let seconds = (window["limit_window_seconds"] as? NSNumber)?.intValue
            let resolvedKind = model == nil && seconds != nil ? (seconds! >= 6 * 86400 ? "weekly_all" : "session") : kind
            windows.append(QuotaWindow(kind: resolvedKind, model: model, percentUsed: Int(percent.doubleValue.rounded()), resetsAt: reset))
        }
        append(limits, "primary_window", "session")
        append(limits, "secondary_window", "weekly_all")
        for extra in json["additional_rate_limits"] as? [[String: Any]] ?? [] {
            guard let name = extra["limit_name"] as? String ?? extra["metered_feature"] as? String,
                  let limit = extra["rate_limit"] as? [String: Any] else { continue }
            append(limit, "primary_window", "codex_scoped", name + " 5h")
            append(limit, "secondary_window", "codex_scoped", name + " weekly")
        }
        return windows.isEmpty ? nil : windows
    }
}
