import AgentUsageModel
import Foundation
import Security

/// Claude Code's subscription quota — the 5-hour session window, the weekly
/// window, and any per-model carve-out — read from the same undocumented OAuth
/// endpoint the CLI's own `/usage` command uses.
///
/// This process is the only thing on the machine that holds the credential.
/// That is the point of it being a separate job: Anthropic rotates the refresh
/// token on every use, so two apps each renewing their own copy would keep
/// rotating each other's away.
///
/// Claude Code's Keychain item is read only when our own item has nothing to
/// offer — normally once ever. What's found there is copied into our item and
/// renewed from there with the stored refresh token. Claude Code rotates its
/// item periodically, and a rotated item comes back with an ACL that no longer
/// trusts us — so reading it on every run means an authorization dialog every
/// time it rotates.
///
/// The cost: renewing here can leave the CLI's own stored refresh token stale.
/// A credential that's genuinely dead still surfaces as `.signedOut` for
/// `claude login` to fix, never repaired behind the user's back.
enum QuotaRefresh {
    /// What has to survive between runs. The poll loop this came from kept it
    /// in memory; a launchd job starts fresh every time, so it lives in
    /// `state.json` beside the snapshot. No secrets — tokens stay in the
    /// Keychain.
    struct State: Codable {
        /// The server rejected a token the clock still considers live, so the
        /// stored credential can't be trusted until it's been renewed.
        var renewBeforeUse = false
        /// A single 401 is most often a rotation the next run recovers from;
        /// two in a row means the credential really is dead.
        var consecutiveRejections = 0
        /// Set once nothing but `claude login` can change the outcome.
        var notBefore: Date?
    }

    /// Every attempt while signed out walks the credential sources to their
    /// end, which means reading Claude Code's item — a read we may not be
    /// authorised for, and an unauthorised one raises a dialog. So this must
    /// never run at launchd's 5-minute cadence, or the user is prompted every
    /// 5 minutes forever. Shaved by a minute so launchd's own jitter doesn't
    /// push it to the run after.
    static let signedOutBackoff: TimeInterval = 1800 - 60

    static func run(previous: Quota?, state: inout State, now: Date) async -> Quota {
        if let notBefore = state.notBefore, now < notBefore, let previous { return previous }
        state.notBefore = nil

        /// `.failed` deliberately keeps the last good numbers — one dropped
        /// request shouldn't blank anyone's panel. `.signedOut` and `.idle`
        /// clear them: there the figures aren't merely stale but unauthorised.
        func finish(_ status: Quota.Status, clearing: Bool, backoff: Bool = false) -> Quota {
            if backoff { state.notBefore = now.addingTimeInterval(signedOutBackoff) }
            var quota = previous ?? Quota(status: status, updatedAt: nil, windows: [], spend: nil)
            quota.status = status
            if clearing {
                quota.windows = []
                quota.spend = nil
                quota.updatedAt = nil
            }
            return quota
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
            // Renewing costs one request and no dialog, so it's always worth
            // trying before declaring a sign-out. Without a refresh token only
            // `claude login` clears it, hence the backoff.
            guard let refreshToken else { return finish(.signedOut, clearing: true, backoff: true) }
            do {
                token = try await renew(refreshToken: refreshToken).accessToken
                state.renewBeforeUse = false
            } catch FetchError.unauthorized {
                // Our stored refresh token is dead — Claude Code renewed and
                // Anthropic rotated ours away. Its presence is exactly what
                // makes `readCredential` stop at our own item, so keeping it
                // would retry this same dead token forever and never look at
                // Claude Code's live one again. Dropping it reopens the walk;
                // only if there was nothing to drop is this a real sign-out.
                if forgetOwnCredential() {
                    state.renewBeforeUse = false
                    return finish(.failed, clearing: false)
                }
                return finish(.signedOut, clearing: true, backoff: true)
            } catch {
                // Offline, or the token endpoint having a bad day. The
                // credential may be perfectly good — not a sign-out.
                return finish(.failed, clearing: false)
            }
        case .missing:
            // No Claude Code on this Mac, or never signed in. Not an error —
            // but still worth backing off, because every retry is another
            // Keychain read.
            return finish(.idle, clearing: true, backoff: true)
        }

        do {
            let usage = try await fetchUsage(token: token)
            state.consecutiveRejections = 0
            return Quota(status: .ok, updatedAt: now, windows: windows(from: usage.limits), spend: usage.spend)
        } catch FetchError.unauthorized {
            // Mark the stored token untrustworthy — the server just disagreed
            // with its own expiry, so reusing it unchanged would only earn the
            // same 401. The first rejection stays `.failed` and keeps the
            // numbers up: a rotation looks exactly like this and the next
            // run's renewal recovers from it. Two in a row is a real sign-out.
            state.renewBeforeUse = true
            state.consecutiveRejections += 1
            let dead = state.consecutiveRejections >= 2
            return finish(dead ? .signedOut : .failed, clearing: dead, backoff: dead)
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

    /// Claude Code's own on-disk shape, so one coder reads their item, their
    /// file, and ours.
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

    static let ownKeychainService = "com.fitzgeraldweb.agent-usage.claude-oauth"

    /// Our own Keychain item first, then `~/.claude/.credentials.json`, then
    /// Claude Code's item — cheapest and quietest first, because the last of
    /// the three raises an authorization dialog whenever Claude Code has
    /// rotated it, and reaching it copies what it finds into ours so that
    /// dialog is a one-off. The file sits in the middle because it's a stale
    /// mirror on a current install — worth reading for free, never worth
    /// trusting first.
    ///
    /// An expired credential of our own ends the walk. Its refresh token
    /// revives it without a dialog, so reading further would buy nothing and
    /// cost one.
    static func readCredential(now: Date = Date()) -> Credential {
        var sawCredential = false
        var refreshToken: String?
        // Closures, not values: evaluating this eagerly would read Claude
        // Code's item — and raise its dialog — even when our own item already
        // had a live token.
        let sources: [(load: () -> Data?, isOurs: Bool)] = [
            (ownCredentials, true), (fileCredentials, false), (keychainCredentials, false),
        ]
        for source in sources {
            guard let data = source.load(),
                  let oauth = try? JSONDecoder().decode(Credentials.self, from: data).claudeAiOauth
            else { continue }
            sawCredential = true
            refreshToken = refreshToken ?? oauth.refreshToken
            if case .token = classify(oauth, now: now) {
                if !source.isOurs { store(oauth) }
                return .token(oauth.accessToken, refreshToken: oauth.refreshToken)
            }
            // Only our own item earns this shortcut. The file is a known-stale
            // mirror, so its refresh token may itself have been rotated away.
            if source.isOurs, refreshToken != nil { break }
        }
        return sawCredential ? .expired(refreshToken: refreshToken) : .missing
    }

    /// Checking expiry here rather than letting the server say so keeps a
    /// long-dead token (the stale file above) from costing a round trip.
    static func classify(_ oauth: Credentials.OAuth, now: Date) -> Credential {
        guard Date(timeIntervalSince1970: oauth.expiresAt / 1000) > now else {
            return .expired(refreshToken: oauth.refreshToken)
        }
        return .token(oauth.accessToken, refreshToken: oauth.refreshToken)
    }

    /// Trades a refresh token for a fresh access token against the same public
    /// OAuth client the CLI uses. The refresh token rotates on use, so the
    /// result has to be stored or the next renewal has nothing to spend.
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

    /// Our own item's ACL trusts us, so reading it back never prompts — as
    /// long as the binary keeps the same signature, which is why the Makefile
    /// signs with a Developer ID when there is one.
    private static func store(_ oauth: Credentials.OAuth) {
        // Never let an older credential overwrite a newer one. Once we've
        // renewed past what Claude Code last wrote, that copy's refresh token
        // has been rotated away — writing it back would trade the only
        // spendable one for a dead one.
        if let held = ownCredentials().flatMap({ try? JSONDecoder().decode(Credentials.self, from: $0) })?
            .claudeAiOauth, held.expiresAt >= oauth.expiresAt { return }
        guard let data = try? JSONEncoder().encode(Credentials(claudeAiOauth: oauth)) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: ownKeychainService,
        ]
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        guard update == errSecItemNotFound else { return }
        var insert = query
        insert[kSecValueData as String] = data
        SecItemAdd(insert as CFDictionary, nil)
    }

    /// Returns whether there was an item to remove — the caller distinguishes
    /// "our copy went stale" from "nothing here works".
    @discardableResult
    private static func forgetOwnCredential() -> Bool {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: ownKeychainService,
        ] as CFDictionary) == errSecSuccess
    }

    private static func ownCredentials() -> Data? { credentialData(service: ownKeychainService) }

    private static func keychainCredentials() -> Data? { credentialData(service: "Claude Code-credentials") }

    private static func credentialData(service: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    private static func fileCredentials() -> Data? {
        let path = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/.credentials.json")
        return try? Data(contentsOf: path)
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
