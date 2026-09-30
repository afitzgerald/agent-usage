import AgentUsageModel
import Foundation

/// `agent-usage --selftest` — the smallest thing that fails if the shaping,
/// credential judgement, scan arithmetic or file format breaks. No test
/// target: SwiftPM can't cleanly test an executable, and this needs no
/// framework. `precondition`, not `assert`, so it still runs under -O.
///
/// The Keychain and network halves of `QuotaRefresh.run` aren't covered —
/// there's nothing pure to extract from them without adding injection nobody
/// asked for.
enum SelfTest {
    static func run() -> Never {
        // precondition survives -O but not -Ounchecked — prove it's live
        // before trusting any check below.
        var checksAreLive = false
        precondition({ checksAreLive = true; return true }())
        guard checksAreLive else {
            print("FAIL: built with -Ounchecked — checks are compiled out, nothing was verified")
            exit(1)
        }
        quotaShaping()
        credentials()
        calendar()
        tokenCounting()
        scan()
        snapshotFormat()
        print("selftest: ok")
        exit(0)
    }

    private static func quotaShaping() {
        // Six fractional-second digits — the format the endpoint really sends,
        // and the one ISO8601DateFormatter refuses without help.
        let reset = QuotaRefresh.parseResetDate("2026-09-04T05:59:59.795218+00:00")
        precondition(reset == Date(timeIntervalSince1970: 1_788_501_599), "got \(String(describing: reset))")
        precondition(QuotaRefresh.parseResetDate("2026-09-04T05:59:59Z") == reset)
        precondition(QuotaRefresh.parseResetDate("not a date") == nil)

        let now = Date(timeIntervalSince1970: 1_788_500_000)
        func label(_ percent: Int, _ offset: TimeInterval?) -> String {
            QuotaWindow(kind: "session", model: nil, percent: percent, resetsAt: offset.map { now.addingTimeInterval($0) })
                .label(now: now)
        }
        precondition(label(30, nil) == "30%")
        precondition(label(30, 45 * 60) == "30% · resets in 45m")
        precondition(label(30, 2 * 3600 + 15 * 60) == "30% · resets in 2h 15m")
        precondition(label(38, 50 * 3600) == "38% · resets in 2d 2h", "got \(label(38, 50 * 3600))")
        // An already-passed reset reads as a bare percentage, not a countdown
        // past zero.
        precondition(label(30, -60) == "30%")

        let fixture = """
        {"limits":[
          {"kind":"session","group":"session","percent":30,"severity":"normal",
           "resets_at":"2026-09-04T05:59:59.795218+00:00","scope":null,"is_active":false},
          {"kind":"weekly_all","group":"weekly","percent":37,"severity":"normal",
           "resets_at":"2026-09-04T14:00:00.795242+00:00","scope":null,"is_active":true},
          {"kind":"weekly_scoped","group":"weekly","percent":0,"severity":"normal",
           "resets_at":null,"scope":{"model":{"id":null,"display_name":"Fable"},"surface":null},"is_active":false},
          {"kind":"weekly_scoped","group":"weekly","percent":62,"severity":"normal",
           "resets_at":null,"scope":{"model":{"id":null,"display_name":"Opus"},"surface":null},"is_active":true},
          {"kind":"future_window","group":"weekly","percent":5,"severity":"normal",
           "resets_at":null,"scope":null,"is_active":true}
        ],
        "spend":{"used":{"amount_minor":4265,"currency":"USD","exponent":2},
                 "limit":{"amount_minor":100000,"currency":"USD","exponent":2},
                 "percent":4,"severity":"normal","enabled":true}}
        """
        let decoded = try! QuotaRefresh.apiDecoder.decode(QuotaRefresh.UsageResponse.self, from: Data(fixture.utf8))
        let windows = QuotaRefresh.windows(from: decoded.limits)

        // Every row is kept, and a `kind` this build has never heard of still
        // renders rather than breaking the section.
        precondition(windows.map(\.name) == ["5h", "Week", "Fable", "Opus", "Future window"],
                     "got \(windows.map(\.name))")
        precondition(windows.map(\.percent) == [30, 37, 0, 62, 5])
        precondition(windows[0].resetsAt == reset)
        // Apps find the two headline windows by these exact strings.
        precondition(windows[0].kind == "session" && windows[1].kind == "weekly_all")
        // Ids have to stay distinct or SwiftUI's ForEach collapses the rows —
        // the two weekly_scoped entries differ only by model.
        precondition(Set(windows.map(\.id)).count == windows.count)

        // An exact partition: anything in both is shown twice, anything in
        // neither vanishes.
        precondition(windows.headline.map(\.name) == ["5h", "Week"])
        precondition(windows.carveOuts.map(\.name) == ["Fable", "Opus", "Future window"])
        precondition(windows.headline.count + windows.carveOuts.count == windows.count)

        // Minor units with their own exponent, never assumed cents.
        let spend = decoded.spend!
        precondition(spend.used.amountMinor == 4265 && spend.used.exponent == 2)
        precondition(spend.percent == 4 && spend.enabled == true)
        precondition(spend.used.formatted == "$42.65", "got \(spend.used.formatted)")
        precondition(spend.limit?.formatted == "$1000.00")
        func money(_ minor: Int, _ exponent: Int, _ currency: String?) -> String {
            let json = #"{"amountMinor":\#(minor),"exponent":\#(exponent)\#(currency.map { #","currency":"\#($0)""# } ?? "")}"#
            return try! JSONDecoder().decode(Spend.Amount.self, from: Data(json.utf8)).formatted
        }
        precondition(money(4265, 0, "JPY") == "JPY 4265", "got \(money(4265, 0, "JPY"))")
        precondition(money(4265, 2, nil) == "42.65")
    }

    /// Getting this wrong is what makes the Keychain dialog come back: an
    /// expiry misread as live spends a run on a 401, and one misread as dead
    /// sends the next run back to Claude Code's item.
    private static func credentials() {
        typealias Q = QuotaRefresh
        let now = Date(timeIntervalSince1970: 1_788_500_000)
        // Milliseconds, not seconds — a credential a minute from expiring.
        let live = Q.Credentials.OAuth(accessToken: "at", refreshToken: "rt", expiresAt: (now.timeIntervalSince1970 + 60) * 1000)
        precondition(Q.classify(live, now: now) == .token("at", refreshToken: "rt"))
        let dead = Q.Credentials.OAuth(accessToken: "at", refreshToken: "rt", expiresAt: (now.timeIntervalSince1970 - 1) * 1000)
        precondition(Q.classify(dead, now: now) == .expired(refreshToken: "rt"))
        let orphan = Q.Credentials.OAuth(accessToken: "at", refreshToken: nil, expiresAt: (now.timeIntervalSince1970 - 1) * 1000)
        precondition(Q.classify(orphan, now: now) == .expired(refreshToken: nil))

        // Our stored copy round-trips through Claude Code's shape, or the item
        // we write is one we can't read back.
        let json = try! JSONEncoder().encode(Q.Credentials(claudeAiOauth: live))
        let decoded = try! JSONDecoder().decode(Q.Credentials.self, from: json).claudeAiOauth
        precondition(decoded.map { Q.classify($0, now: now) } == .token("at", refreshToken: "rt"))

        // A `+` in a form body decodes as a space, so a token carrying one is
        // renewed with the wrong string and 401s forever.
        let body = Q.formBody(["grant_type": "refresh_token", "refresh_token": "a+b/c=~d_e"])
        precondition(body == "grant_type=refresh_token&refresh_token=a%2Bb%2Fc%3D~d_e", "got \(body)")

        // State survives the trip through state.json, backoff date included.
        var state = Q.State()
        state.renewBeforeUse = true
        state.consecutiveRejections = 1
        state.notBefore = now
        let restored = try! Snapshot.decoder.decode(Q.State.self, from: Snapshot.encoder.encode(state))
        precondition(restored.renewBeforeUse && restored.consecutiveRejections == 1 && restored.notBefore == now)
    }

    private static func calendar() {
        typealias T = TokenScan
        precondition(T.daysFromCivil(year: 1970, month: 1, day: 1) == 0)
        precondition(T.daysFromCivil(year: 2000, month: 3, day: 1) == 11_017)
        precondition(T.daysFromCivil(year: 2026, month: 9, day: 4) == 20_700)
        for day in [0, 11_017, 20_454, 20_700, -1, 25_000] {
            let civil = T.civilFromDays(day)
            precondition(T.daysFromCivil(year: civil.year, month: civil.month, day: civil.day) == day,
                         "round trip failed at \(day) -> \(civil)")
        }
        precondition(T.isoDay(20_700) == "2026-09-04")
        precondition(T.isoDay(0) == "1970-01-01")

        // Logs are UTC, so an evening's work in the Americas is already
        // "tomorrow" by the timestamp's own date.
        let evening = "2026-09-04T03:47:33.335Z"
        precondition(T.localEpochDay(iso8601: evening, offsetMinutes: 0) == 20_700)
        precondition(T.localEpochDay(iso8601: evening, offsetMinutes: -7 * 60) == 20_699)
        precondition(T.localEpochDay(iso8601: "2026-09-04T22:10:00.000Z", offsetMinutes: 9 * 60) == 20_701)
        // A half-hour zone still resolves, so the minutes term isn't dead code.
        precondition(T.localEpochDay(iso8601: "2026-09-04T18:45:00.000Z", offsetMinutes: 5 * 60 + 30) == 20_701)
        precondition(T.localEpochDay(iso8601: "not-a-timestamp-at-all", offsetMinutes: 0) == nil)
        precondition(T.localEpochDay(iso8601: "2026-13-04T00:00:00Z", offsetMinutes: 0) == nil)

        precondition(Day(day: "2026-09-04", usage: TokenCounts()).label == "Sep 4")
        precondition(Day(day: "2026-01-01", usage: TokenCounts()).label == "Jan 1")
        precondition(Day(day: "garbage", usage: TokenCounts()).label == "garbage")
    }

    private static func tokenCounting() {
        // Split-by-TTL cache writes and the older combined field both land in
        // `cacheWrite`.
        let split = TokenScan.tokenCounts(from: [
            "input_tokens": 2, "output_tokens": 705, "cache_read_input_tokens": 35_336,
            "cache_creation_input_tokens": 30_939,
            "cache_creation": ["ephemeral_1h_input_tokens": 30_000, "ephemeral_5m_input_tokens": 939],
        ])
        precondition(split == TokenCounts(input: 2, output: 705, cacheWrite: 30_939, cacheRead: 35_336, requests: 1),
                     "got \(split)")
        precondition(TokenScan.tokenCounts(from: ["cache_creation_input_tokens": 4_096]).cacheWrite == 4_096)
        // A record missing every field is zero tokens and one request, not a crash.
        precondition(TokenScan.tokenCounts(from: [:]) == TokenCounts(requests: 1))
        precondition(split.inputOutput == 707)

        precondition(TokenCounts.format(999) == "999")
        precondition(TokenCounts.format(45_000) == "45K")
        precondition(TokenCounts.format(45_000_000) == "45M")
        precondition(TokenCounts.format(10_200_000_000) == "10.2B")

        // Ties broken by name — hash order alone flips between runs.
        let ranked = TokenScan.ranked([
            "b-model": TokenCounts(output: 5), "a-model": TokenCounts(output: 5), "c-model": TokenCounts(output: 9),
        ])
        precondition(ranked.map(\.model) == ["c-model", "a-model", "b-model"], "got \(ranked.map(\.model))")
    }

    private static func scan() {
        let root = FileManager.default.temporaryDirectory.appending(path: "agent-usage-selftest-\(UUID().uuidString)")
        let project = root.appending(path: "-Users-someone-project")
        try! FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let now = Date()
        let today = TokenScan.localEpochDay(of: now)
        // Noon UTC keeps each record on its intended local day for every
        // real-world zone offset.
        func stamp(daysAgo: Int) -> String { TokenScan.isoDay(today - daysAgo) + "T12:00:00.000Z" }
        func record(_ requestID: String, _ model: String, _ daysAgo: Int, _ usage: String) -> String {
            """
            {"type":"assistant","requestId":"\(requestID)","timestamp":"\(stamp(daysAgo: daysAgo))",\
            "message":{"id":"msg_\(requestID)","model":"\(model)","usage":{\(usage)}}}
            """
        }

        let opus = record("req-a", "claude-opus-5", 2, #""input_tokens":1000,"output_tokens":1000"#)
        let sonnet = record("req-b", "claude-sonnet-5", 0,
                            #""input_tokens":0,"output_tokens":500,"cache_read_input_tokens":1000000"#)
        let unknown = record("req-c", "model-from-the-future", 0, #""output_tokens":999"#)
        let sonnet2 = record("req-d", "claude-sonnet-5", 2, #""output_tokens":100"#)
        let synthetic = record("req-e", "<synthetic>", 0, #""output_tokens":0"#)
        // `req-a` appears in both transcripts — exactly what resuming a
        // session produces.
        try! (opus + "\n" + sonnet + "\n" + sonnet2 + "\n" + synthetic + "\n").write(
            to: project.appending(path: "one.jsonl"), atomically: true, encoding: .utf8)
        try! (opus + "\n" + unknown + "\n" + "not json at all\n").write(
            to: project.appending(path: "two.jsonl"), atomically: true, encoding: .utf8)

        let result = TokenScan.scan(root: root, now: now)

        // Padded to the full window, so an idle stretch stays a gap.
        precondition(result.days.count == TokenScan.windowDays, "got \(result.days.count)")
        precondition(result.days.first?.day == TokenScan.isoDay(today - TokenScan.windowDays + 1))
        precondition(result.days.last?.day == TokenScan.isoDay(today))

        func day(_ daysAgo: Int) -> TokenCounts {
            result.days.first { $0.day == TokenScan.isoDay(today - daysAgo) }!.usage
        }
        // req-a counted once despite appearing in both files.
        precondition(day(2) == TokenCounts(input: 1000, output: 1100, requests: 2), "got \(day(2))")
        precondition(day(1) == TokenCounts())
        // An unknown model is counted in full — there's no price to be missing
        // any more. The synthetic record isn't counted at all.
        precondition(day(0) == TokenCounts(output: 1499, cacheRead: 1_000_000, requests: 2), "got \(day(0))")

        // Opus has 2000 input+output against Sonnet's 600, however many cache
        // reads Sonnet racked up.
        precondition(result.models.map(\.model) == ["claude-opus-5", "model-from-the-future", "claude-sonnet-5"],
                     "got \(result.models.map(\.model))")
        precondition(result.models.last?.usage.requests == 2)

        // An empty tree is no history, not a month of zeroes.
        let empty = TokenScan.scan(root: root.appending(path: "does-not-exist"), now: now)
        precondition(empty.days.isEmpty && empty.models.isEmpty)

        precondition(TokenScan.isDue(nil, now: now))
        precondition(!TokenScan.isDue(result, now: now.addingTimeInterval(60)))
        precondition(TokenScan.isDue(result, now: now.addingTimeInterval(600)))
    }

    /// The file is the contract with every app — a round trip has to be exact,
    /// and a schema this build doesn't know has to be refused.
    private static func snapshotFormat() {
        let now = Date(timeIntervalSince1970: 1_788_500_000)
        let snapshot = Snapshot(
            generatedAt: now,
            quota: Quota(status: .failed, updatedAt: now, windows: [
                QuotaWindow(kind: "weekly_scoped", model: "Opus", percent: 62, resetsAt: now),
            ], spend: nil),
            tokens: Tokens(updatedAt: now, windowDays: 30,
                           days: [Day(day: "2026-09-04", usage: TokenCounts(input: 1, requests: 1))],
                           models: [ModelUsage(model: "claude-opus-5", usage: TokenCounts(output: 2))])
        )
        let url = FileManager.default.temporaryDirectory.appending(path: "agent-usage-selftest-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try! Snapshot.encoder.encode(snapshot).write(to: url)

        let loaded = try! Snapshot.load(from: url)
        precondition(loaded.schema == Snapshot.currentSchema && loaded.generatedAt == now)
        precondition(loaded.quota?.status == .failed && loaded.quota?.windows.first?.id == "weekly_scopedOpus")
        precondition(loaded.tokens?.days.first?.usage == TokenCounts(input: 1, requests: 1))
        precondition(loaded.tokens?.models.first?.usage.output == 2)

        // Days are plain date strings, so a non-Swift reader needs no calendar.
        let text = try! String(contentsOf: url, encoding: .utf8)
        precondition(text.contains(#""day" : "2026-09-04""#), text)

        precondition(!loaded.isStale(now: now.addingTimeInterval(Snapshot.staleAfter)))
        precondition(loaded.isStale(now: now.addingTimeInterval(Snapshot.staleAfter + 1)))

        var future = snapshot
        future.schema = Snapshot.currentSchema + 1
        try! Snapshot.encoder.encode(future).write(to: url)
        do {
            _ = try Snapshot.load(from: url)
            preconditionFailure("loaded a schema this build doesn't know")
        } catch let error as Snapshot.SchemaError {
            precondition(error.found == Snapshot.currentSchema + 1)
        } catch {
            preconditionFailure("wrong error: \(error)")
        }
    }
}
