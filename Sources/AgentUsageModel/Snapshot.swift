import Foundation

/// `usage.json` — everything `agent-usage refresh` knows, and the only
/// interface between it and the apps that display it. Readers never touch a
/// credential or a transcript: they decode this and check `isStale`.
///
/// Adding an optional field keeps `schema` as it is. Renaming or removing
/// anything bumps it, and `load` refuses a schema it doesn't know rather than
/// half-decoding one.
public struct Snapshot: Codable, Sendable {
    public static let currentSchema = 3

    public var schema: Int
    public var generatedAt: Date
    /// One entry per agent this build tracks, in display order.
    public var agents: [AgentUsage]

    public init(generatedAt: Date, agents: [AgentUsage]) {
        self.schema = Self.currentSchema
        self.generatedAt = generatedAt
        self.agents = agents
    }

    public func agent(_ id: String) -> AgentUsage? {
        agents.first { $0.agent == id }
    }

    public static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/AgentUsage")
    }

    public static var defaultURL: URL { directory.appending(path: "usage.json") }

    /// Three missed runs at launchd's 5-minute cadence. Past this the numbers
    /// aren't just old, the job isn't running — say so instead of showing them
    /// as current.
    public static let staleAfter: TimeInterval = 15 * 60

    public func isStale(now: Date = Date()) -> Bool {
        now.timeIntervalSince(generatedAt) > Self.staleAfter
    }

    public struct SchemaError: Error {
        public let found: Int
    }

    public static func load(from url: URL = defaultURL) throws -> Snapshot {
        let snapshot = try decoder.decode(Snapshot.self, from: Data(contentsOf: url))
        guard snapshot.schema == currentSchema else { throw SchemaError(found: snapshot.schema) }
        return snapshot
    }

    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    public static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

// MARK: - Agent

public struct AgentUsage: Codable, Sendable, Identifiable {
    public static let claude = "claude"

    /// "claude", or one this build has never heard of.
    public var agent: String
    /// Nil only before the first run has finished, or for an agent with no
    /// quota to report.
    public var quota: Quota?
    public var tokens: Tokens?

    public var id: String { agent }

    public init(agent: String, quota: Quota?, tokens: Tokens?) {
        self.agent = agent
        self.quota = quota
        self.tokens = tokens
    }
}

// MARK: - Quota

/// An agent's subscription quota, as served by its API — the server's own
/// percentages, not a local count, so it stays right across machines sharing
/// one account.
public struct Quota: Codable, Sendable {
    public enum Status: String, Codable, Sendable {
        /// No credential for this agent on this Mac. Nothing to show and
        /// nothing to complain about.
        case idle
        case ok
        /// Only signing the agent back in fixes this (`claude login` for
        /// Claude Code). `windows` is empty.
        case signedOut
        /// Network trouble, or a single rejection that the next run is likely
        /// to recover from. `windows` still holds the last good numbers.
        case failed
    }

    public var status: Status
    /// When `windows` was last fetched. Nil while there are none.
    public var updatedAt: Date?
    public var windows: [QuotaWindow]
    /// Credit spend past the plan's included usage. Nil on an account with no
    /// credits configured — most of them.
    public var spend: Spend?

    public init(status: Status, updatedAt: Date?, windows: [QuotaWindow], spend: Spend?) {
        self.status = status
        self.updatedAt = updatedAt
        self.windows = windows
        self.spend = spend
    }
}

public struct QuotaWindow: Codable, Sendable, Identifiable {
    /// The server's `kind` — Claude's are "session", "weekly_all" and
    /// "weekly_scoped" — or one this build has never heard of.
    public var kind: String
    /// Set on per-model carve-outs ("Opus", "Fable").
    public var model: String?
    /// How much of the window is used up, not how much is left — the
    /// server's figure rounded to a whole number, the same one `/usage` shows.
    public var percentUsed: Int
    public var resetsAt: Date?

    /// Folds in the model — two `weekly_scoped` windows share a kind.
    public var id: String { kind + (model ?? "") }

    public init(kind: String, model: String?, percentUsed: Int, resetsAt: Date?) {
        self.kind = kind
        self.model = model
        self.percentUsed = percentUsed
        self.resetsAt = resetsAt
    }

    /// The two windows every account has.
    public var isHeadline: Bool { kind == "session" || kind == "weekly_all" }

    /// "5h", "Week", the model's name, or an unknown kind spelled out — so a
    /// new window renders as a row instead of vanishing.
    public var name: String {
        switch kind {
        case "session": return "5h"
        case "weekly_all": return "Week"
        case "weekly_scoped": return model ?? "Scoped"
        default:
            let words = kind.replacingOccurrences(of: "_", with: " ")
            return words.prefix(1).uppercased() + words.dropFirst()
        }
    }

    /// Percent used plus how long until the window rolls over. An
    /// already-elapsed reset (the run straddled it, or the clock is skewed)
    /// drops the phrase rather than rendering a negative countdown.
    public func label(now: Date = Date()) -> String {
        let used = "\(percentUsed)% used"
        guard let resetsAt, resetsAt > now else { return used }
        let minutes = Int((resetsAt.timeIntervalSince(now) / 60).rounded(.up))
        let (hours, remainder) = (minutes / 60, minutes % 60)
        if hours >= 24 { return "\(used) · resets in \(hours / 24)d \(hours % 24)h" }
        if hours > 0 { return "\(used) · resets in \(hours)h \(remainder)m" }
        return "\(used) · resets in \(remainder)m"
    }
}

extension Array where Element == QuotaWindow {
    /// `headline` and `carveOuts` partition the array exactly, so nothing is
    /// shown twice and nothing is dropped.
    public var headline: [QuotaWindow] { filter(\.isHeadline) }
    public var carveOuts: [QuotaWindow] { filter { !$0.isHeadline } }
}

/// Decoded straight from the API (snake_case there, camelCase in the file).
public struct Spend: Codable, Sendable {
    /// Minor units with their own exponent — 4265 at exponent 2 is $42.65.
    /// Never assume cents.
    public struct Amount: Codable, Sendable {
        public let amountMinor: Int
        public let currency: String?
        public let exponent: Int

        public var formatted: String {
            let symbol = currency == "USD" ? "$" : currency.map { "\($0) " } ?? ""
            let value = Double(amountMinor) / pow(10, Double(exponent))
            return symbol + String(format: "%.\(exponent)f", value)
        }
    }

    public let used: Amount
    public let limit: Amount?
    /// Share of `limit` spent, not left. Keeps the API's name because this
    /// struct decodes straight from it.
    public let percent: Int?
    public let enabled: Bool?
}

// MARK: - Tokens

/// Token counts reconstructed from an agent's local session logs
/// (`~/.claude/projects` for Claude Code). Counts only — nothing here is priced.
public struct Tokens: Codable, Sendable {
    public var updatedAt: Date
    public var windowDays: Int
    /// Ascending, one entry per calendar day in the window, idle days
    /// included as zeroes. Empty means no history at all, not an idle month.
    public var days: [Day]
    /// Whole window, heaviest first by `inputOutput`.
    public var models: [ModelUsage]

    public init(updatedAt: Date, windowDays: Int, days: [Day], models: [ModelUsage]) {
        self.updatedAt = updatedAt
        self.windowDays = windowDays
        self.days = days
        self.models = models
    }
}

public struct TokenCounts: Codable, Sendable, Equatable {
    public var input: Int
    public var output: Int
    public var cacheWrite: Int
    public var cacheRead: Int
    /// API requests, after de-duplicating records copied between transcripts.
    public var requests: Int

    public init(input: Int = 0, output: Int = 0, cacheWrite: Int = 0, cacheRead: Int = 0, requests: Int = 0) {
        self.input = input
        self.output = output
        self.cacheWrite = cacheWrite
        self.cacheRead = cacheRead
        self.requests = requests
    }

    /// The headline figure. Cache reads are usually the vast majority of all
    /// tokens — every turn re-reads the cached context — so a grand total is
    /// mostly them, and moves in ways nobody can act on.
    public var inputOutput: Int { input + output }

    public mutating func add(_ other: TokenCounts) {
        input += other.input
        output += other.output
        cacheWrite += other.cacheWrite
        cacheRead += other.cacheRead
        requests += other.requests
    }

    public static func format(_ count: Int) -> String {
        switch count {
        case ..<1_000: return "\(count)"
        case ..<1_000_000: return "\(count / 1_000)K"
        case ..<1_000_000_000: return "\(count / 1_000_000)M"
        default: return String(format: "%.1fB", Double(count) / 1_000_000_000)
        }
    }
}

public struct Day: Codable, Sendable, Identifiable {
    /// Local calendar day, "2026-09-04".
    public var day: String
    public var usage: TokenCounts

    public var id: String { day }

    public init(day: String, usage: TokenCounts) {
        self.day = day
        self.usage = usage
    }

    /// Short axis label — "Sep 4".
    public var label: String {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        guard parts.count == 3, (1...12).contains(parts[1]) else { return day }
        return "\(months[parts[1] - 1]) \(parts[2])"
    }
}

public struct ModelUsage: Codable, Sendable, Identifiable {
    public var model: String
    public var usage: TokenCounts

    public var id: String { model }

    public init(model: String, usage: TokenCounts) {
        self.model = model
        self.usage = usage
    }
}
