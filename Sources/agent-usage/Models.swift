import AgentUsageModel
import Foundation

/// The models each agent offers, read from the catalog the agent itself
/// fetches and caches. No request and no credential of our own: the agent
/// already asked its server, with its own account, and keeps the answer fresh.
enum Models {
    /// `~/.claude/cache/model-catalog/<account>-<org>-cc.json`. One file per
    /// signed-in account, so the most recently fetched one wins.
    static func claude(directory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: ".claude/cache/model-catalog")) -> [AvailableModel]? {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let catalogs = files.filter { $0.lastPathComponent.hasSuffix("-cc.json") }.compactMap { url -> [String: Any]? in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
        let newest = catalogs.max { ($0["fetchedAt"] as? Double ?? 0) < ($1["fetchedAt"] as? Double ?? 0) }
        guard let catalog = newest?["catalog"] as? [String: Any],
              let config = catalog["config"] as? [String: Any],
              let models = config["models"] as? [[String: Any]] else { return nil }
        return models.compactMap { model in
            guard model["hidden"] as? Bool != true, let id = model["id"] as? String else { return nil }
            return AvailableModel(id: id, name: model["name"] as? String ?? id)
        }
    }

    /// `$CODEX_HOME/models_cache.json`, already in Codex's priority order.
    /// Hidden entries are internal (auto-review and the like), not choices.
    static func codex(home: URL = Codex.home) -> [AvailableModel]? {
        guard let data = try? Data(contentsOf: home.appending(path: "models_cache.json")),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else { return nil }
        return models.compactMap { model in
            guard model["visibility"] as? String != "hide", let id = model["slug"] as? String else { return nil }
            return AvailableModel(id: id, name: model["display_name"] as? String ?? id)
        }
    }
}
