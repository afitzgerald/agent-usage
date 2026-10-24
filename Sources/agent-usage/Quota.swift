import AgentUsageModel
import Foundation

/// Claude Code's subscription quota — the 5-hour session window, the weekly
/// window, and any per-model carve-out — read from the same undocumented OAuth
/// endpoint the CLI's own `/usage` command uses.
///
/// There is exactly one credential on the machine: Claude Code's. Anthropic
/// rotates the refresh token on every use, so any private copy is a second
/// holder of the same token, and whichever of the two renews second finds
/// theirs dead. An earlier build kept such a copy and paid for it with a
/// Keychain dialog every time Claude Code renewed. So this reads Claude Code's
/// item fresh each run, and a renewal done here is written straight back into
/// it — to Claude Code, it's one more of its own sessions.
///
/// Every Keychain access goes through `/usr/bin/security`, because that is the
/// tool Claude Code stores its item with, and an item trusts the binary that
/// created it. Read via Security.framework instead and the item's ACL doesn't
/// list us, so each rewrite of it means an authorization dialog.
enum QuotaRefresh {
    /// What has to survive between runs. A launchd job starts fresh every
    /// time, so it lives in `state.json` beside the snapshot. No secrets.
    struct State: Codable {
        /// The server rejected a token the clock still considers live, so the
        /// stored credential can't be trusted until it's been renewed.
        var renewBeforeUse = false
        /// A single 401 is most often a rotation the next run recovers from;
        /// two in a row means the credential really is dead.
        var consecutiveRejections = 0
    }

    static func run(previous: Quota?, state: inout State, now: Date) async -> Quota {
        /// `.failed` deliberately keeps the last good numbers — one dropped
        /// request shouldn't blank anyone's panel. `.signedOut` and `.idle`
        /// clear them: there the figures aren't merely stale but unauthorised.
        func finish(_ status: Quota.Status, clearing: Bool) -> Quota {
            var quota = previous ?? Quota(status: status, updatedAt: nil, windows: [], spend: nil)
            quota.status = status
            if clearing {
                quota.windows = []
                quota.spend = nil
                quota.updatedAt = nil
            }
            return quota
        }

        /// The first rejection stays `.failed` and keeps the numbers up: a
        /// renewal racing Claude Code's own looks exactly like this, and the
        /// next run reads whatever Claude Code wrote. Two in a row is a real
        /// sign-out, for `claude login` to fix.
        func rejected() -> Quota {
            state.consecutiveRejections += 1
            let dead = state.consecutiveRejections >= 2
            return finish(dead ? .signedOut : .failed, clearing: dead)
        }

        var found = readCredential(now: now)
        if state.renewBeforeUse, case .token(_, let refreshToken) = found {
            found = .expired(refreshToken: refreshToken)
        }

        let token: String
        switch found {
        case .token(let accessToken, _):
            token = accessToken
        case .expired(let refreshToken):
            // Claude Code renews ahead of expiry while it's in use, so an
            // expired token here means it's idle and nobody else is about to
            // spend the refresh token.
            guard let refreshToken else { return finish(.signedOut, clearing: true) }
            do {
                token = try await renew(refreshToken: refreshToken).accessToken
                state.renewBeforeUse = false
            } catch FetchError.unauthorized {
                return rejected()
            } catch {
                // Offline, or the token endpoint having a bad day. The
                // credential may be perfectly good — not a sign-out.
                return finish(.failed, clearing: false)
            }
        case .missing:
            // No Claude Code on this Mac, or never signed in. Not an error.
            return finish(.idle, clearing: true)
        }

        do {
            let usage = try await fetchUsage(token: token)
            state.consecutiveRejections = 0
            return Quota(status: .ok, updatedAt: now, windows: windows(from: usage.limits), spend: usage.spend)
        } catch FetchError.unauthorized {
            // The server just disagreed with the token's own expiry, so
            // reusing it unchanged would only earn the same 401.
            state.renewBeforeUse = true
            return rejected()
        } catch {
            return finish(.failed, clearing: false)
        }
    }

    // MARK: - Credentials

    enum FetchError: Error { case unauthorized, badStatus }

    /// What a credential lookup found. "Nothing here" and "here but expired"
    /// have to stay distinct: the first is a Mac without Claude Code and
    /// deserves silence, the second is the common real failure.
    enum Credential: Equatable {
        case missing
        /// A non-nil refresh token means it can be revived without asking
        /// anyone; nil means only `claude login` will.
        case expired(refreshToken: String?)
        case token(String, refreshToken: String?)
    }

    /// Claude Code's own on-disk shape. Only the fields read here — writing
    /// back goes through `patched`, which keeps the rest.
    struct Credentials: Codable {
        struct OAuth: Codable {
            let accessToken: String
            /// Absent on older Claude Code layouts.
            let refreshToken: String?
            /// Milliseconds since epoch, not seconds.
            let expiresAt: Double
        }

        let claudeAiOauth: OAuth?
    }

    static let keychainService = "Claude Code-credentials"
    static let credentialsFile = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: ".claude/.credentials.json")

    /// Claude Code's Keychain item, or the file it falls back to where there is
    /// no Keychain. Never both: on a Mac with the item, the file is a stale
    /// mirror whose refresh token was rotated away long ago.
    static func readCredential(now: Date = Date()) -> Credential {
        guard let data = keychainCredentials() ?? (try? Data(contentsOf: credentialsFile)),
              let oauth = try? JSONDecoder().decode(Credentials.self, from: data).claudeAiOauth
        else { return .missing }
        return classify(oauth, now: now)
    }

    /// Checking expiry here rather than letting the server say so keeps a
    /// long-dead token from costing a round trip.
    static func classify(_ oauth: Credentials.OAuth, now: Date) -> Credential {
        guard Date(timeIntervalSince1970: oauth.expiresAt / 1000) > now else {
            return .expired(refreshToken: oauth.refreshToken)
        }
        return .token(oauth.accessToken, refreshToken: oauth.refreshToken)
    }

    /// Trades a refresh token for a fresh access token against the same public
    /// OAuth client the CLI uses. The refresh token rotates on use, so the
    /// result goes back where it came from or Claude Code is left holding a
    /// dead one.
    static func renew(refreshToken: String) async throws -> Credentials.OAuth {
        var request = URLRequest(url: URL(string: "https://platform.claude.com/v1/oauth/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(formBody([
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            // Claude Code's OAuth client ID — a public identifier, not a secret.
            "client_id": "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
        ]).utf8)
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        // `invalid_grant` — a refresh token spent or revoked — arrives as a 400.
        if code == 400 || code == 401 || code == 403 { throw FetchError.unauthorized }
        guard code == 200 else { throw FetchError.badStatus }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let renewed = try decoder.decode(TokenResponse.self, from: data)
        let oauth = Credentials.OAuth(
            accessToken: renewed.accessToken,
            // A response without one means the old token stays valid.
            refreshToken: renewed.refreshToken ?? refreshToken,
            expiresAt: Date().addingTimeInterval(renewed.expiresIn).timeIntervalSince1970 * 1000
        )
        store(oauth)
        return oauth
    }

    /// `application/x-www-form-urlencoded`, escaping everything but the
    /// unreserved set — by hand, because `+` survives URLComponents and comes
    /// back out of a form body as a space.
    static func formBody(_ fields: [String: String]) -> String {
        var unreserved = CharacterSet.alphanumerics
        unreserved.insert(charactersIn: "-._~")
        return fields.keys.sorted().map { key in
            let value = fields[key]?.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
            return "\(key)=\(value)"
        }.joined(separator: "&")
    }

    private struct TokenResponse: Decodable {
        let accessToken: String
        let refreshToken: String?
        /// Seconds from now, unlike `expiresAt` on the stored credential.
        let expiresIn: TimeInterval
    }

    /// Writes a renewal back into whichever of Claude Code's stores it came
    /// from. Re-read just before writing, so MCP tokens and anything else
    /// Claude Code changed meanwhile survive.
    private static func store(_ oauth: Credentials.OAuth) {
        if let current = keychainCredentials() {
            guard let data = patched(current, with: oauth) else { return }
            // In argv, so briefly visible to this user's own processes —
            // `security -i` would hide it, but it truncates long lines and
            // the item runs to 15KB with MCP tokens in it.
            let hex = data.map { String(format: "%02x", $0) }.joined()
            _ = security(["add-generic-password", "-U", "-a", NSUserName(), "-s", keychainService, "-X", hex])
            // A failed write leaves Claude Code holding the refresh token this
            // renewal just spent — worth a line in the log.
            if keychainCredentials() != data {
                FileHandle.standardError.write(Data("agent-usage: couldn't write the renewed credential back\n".utf8))
            }
        } else if let current = try? Data(contentsOf: credentialsFile), let data = patched(current, with: oauth) {
            try? data.write(to: credentialsFile, options: .atomic)
        }
    }

    /// Replaces the three token fields and leaves every other key as it was.
    static func patched(_ stored: Data, with oauth: Credentials.OAuth) -> Data? {
        guard var root = (try? JSONSerialization.jsonObject(with: stored)) as? [String: Any] else { return nil }
        var entry = root["claudeAiOauth"] as? [String: Any] ?? [:]
        entry["accessToken"] = oauth.accessToken
        entry["refreshToken"] = oauth.refreshToken
        entry["expiresAt"] = Int64(oauth.expiresAt)
        root["claudeAiOauth"] = entry
        return try? JSONSerialization.data(withJSONObject: root)
    }

    private static func keychainCredentials() -> Data? {
        security(["find-generic-password", "-s", keychainService, "-w"])
            .map { Data($0.trimmingCharacters(in: .newlines).utf8) }
    }

    /// Runs `/usr/bin/security`, returning stdout on success.
    private static func security(_ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: output, as: UTF8.self)
    }

    // MARK: - Fetch

    struct UsageResponse: Decodable {
        struct Limit: Decodable {
            struct Scope: Decodable {
                struct Model: Decodable { let displayName: String? }
                let model: Model?
            }

            let kind: String
            let percent: Double
            let resetsAt: String?
            let scope: Scope?
        }

        let limits: [Limit]
        let spend: Spend?
    }

    static var apiDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    private static func fetchUsage(token: String) async throws -> UsageResponse {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        // Required, not cosmetic: requests without a claude-code User-Agent land
        // in a much more aggressively rate-limited bucket and start returning
        // 429s. The endpoint buckets on the product prefix, so the version
        // doesn't have to track the installed CLI.
        request.setValue("claude-code/2.1.260", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 || code == 403 { throw FetchError.unauthorized }
        guard code == 200 else { throw FetchError.badStatus }
        return try apiDecoder.decode(UsageResponse.self, from: data)
    }

    // MARK: - Shaping

    /// Reads the `limits` array rather than the response's top-level
    /// `five_hour`/`seven_day` twins: the top level is a churning pile of
    /// server-side codenames, whereas each `limits` entry is self-describing
    /// and an unrecognised `kind` still comes through. Every row is kept,
    /// carve-outs at zero included — which reaches which surface is the app's
    /// call.
    static func windows(from limits: [UsageResponse.Limit]) -> [QuotaWindow] {
        limits.map { limit in
            QuotaWindow(
                kind: limit.kind,
                model: limit.scope?.model?.displayName,
                percentUsed: Int(limit.percent.rounded()),
                resetsAt: limit.resetsAt.flatMap(parseResetDate)
            )
        }
    }

    /// `resets_at` arrives with six fractional-second digits, which
    /// `ISO8601DateFormatter` rejects outright — so the fraction, meaningless
    /// on a window measured in hours, is dropped before parsing.
    static func parseResetDate(_ raw: String) -> Date? {
        var trimmed = raw
        if let dot = raw.firstIndex(of: "."),
           let offset = raw[dot...].firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" }) {
            trimmed = String(raw[..<dot] + raw[offset...])
        }
        return ISO8601DateFormatter().date(from: trimmed)
    }
}
