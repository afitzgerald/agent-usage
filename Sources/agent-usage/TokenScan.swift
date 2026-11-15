import AgentUsageModel
import Foundation

/// Token counts reconstructed from Claude Code's session logs in
/// `~/.claude/projects`. The quota comes authoritatively from the API; token
/// history exists only in these local JSONL transcripts.
enum TokenScan {
    static let windowDays = 30
    /// The file filter looks a few days further back than the window, so a log
    /// written just before the boundary still contributes its in-window records.
    static let fileCutoffDays = 35

    /// What the scans so far have counted, so the next one reads only what was
    /// appended since. A full read is ~12 s of CPU over 3 GB; the appends
    /// between two 5-minute runs are a few MB.
    struct State: Codable {
        static let version = 1
        var version = State.version
        var offsetMinutes: Int
        var files: [String: Tail.Mark] = [:]
        /// Request ID → local day, so a record copied into another transcript
        /// is counted once even when the copy turns up runs later.
        var seen: [String: Int] = [:]
        /// Local day → model → usage.
        var totals: [Int: [String: TokenCounts]] = [:]
    }

    /// A whole scan from nothing. Tests only; `refresh` goes through `update`.
    static func scan(root: URL? = nil, now: Date = Date()) -> Tokens {
        update(nil, root: root, now: now).tokens
    }

    /// Adds every transcript line written since `previous` and aggregates
    /// usage by local day and by model. No state, a state from another
    /// version or another UTC offset (the day buckets would be wrong) starts
    /// over from a full read.
    ///
    /// Deliberately `JSONSerialization` rather than `Codable`: a full read
    /// decodes >100k records and reads a handful of fields from each, which is
    /// exactly where `JSONDecoder`'s per-value overhead shows up.
    static func update(_ previous: State?, root: URL? = nil, now: Date = Date()) -> (tokens: Tokens, state: State) {
        let base = root ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/projects")
        let offsetMinutes = TimeZone.current.secondsFromGMT(for: now) / 60
        let newestDay = localEpochDay(of: now)
        let oldestDay = newestDay - windowDays + 1

        var state = previous.flatMap { $0.version == State.version && $0.offsetMinutes == offsetMinutes ? $0 : nil }
            ?? State(offsetMinutes: offsetMinutes)
        var files: [String: Tail.Mark] = [:]

        let needle = Array("\"usage\"".utf8)

        // Pooled per file: the read buffers are autoreleased, and a full
        // recount holds GBs of them without it.
        for url in recentLogs(under: base, now: now) { autoreleasepool {
            let mark = state.files[url.path]
            guard let read = Tail.read(url, after: mark) else {
                files[url.path] = mark
                return
            }
            files[url.path] = read.mark
            Tail.forEachLine(in: read.data) { start, length in
                // Cheap reject before the expensive parse — only a
                // fraction of lines are assistant messages with usage.
                guard memmem(start, length, needle, needle.count) != nil else { return }
                let line = Data(bytes: start, count: length)
                guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let message = object["message"] as? [String: Any],
                      let usageJSON = message["usage"] as? [String: Any],
                      let model = message["model"] as? String,
                      // Claude Code's own placeholder records, not
                      // API calls.
                      model != "<synthetic>",
                      let timestamp = object["timestamp"] as? String,
                      let day = localEpochDay(iso8601: timestamp, offsetMinutes: offsetMinutes),
                      day >= oldestDay, day <= newestDay
                else { return }

                // A record can appear in several transcripts — resuming
                // or forking a session copies the history into the new
                // file — and that was 46% of all usage records on the
                // machine this was written on. Without this the totals
                // very nearly double.
                if let requestID = object["requestId"] as? String ?? message["id"] as? String {
                    guard state.seen[requestID] == nil else { return }
                    state.seen[requestID] = day
                }
                state.totals[day, default: [:]][model, default: TokenCounts()].add(tokenCounts(from: usageJSON))
            }
        } }

        state.files = files
        state.seen = state.seen.filter { $0.value >= oldestDay }
        state.totals = state.totals.filter { $0.key >= oldestDay }
        return (tokens(from: state.totals, now: now), state)
    }

    /// Every `.jsonl` under `base` modified within the file cutoff.
    static func recentLogs(under base: URL, now: Date) -> [URL] {
        let cutoff = now.addingTimeInterval(-Double(fileCutoffDays) * 86400)
        guard let walker = FileManager.default.enumerator(
            at: base,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return walker.compactMap { item in
            guard let url = item as? URL, url.pathExtension == "jsonl",
                  let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  modified >= cutoff
            else { return nil }
            return url
        }
    }

    /// Day → model → usage, cut to the window and shaped for `usage.json`.
    static func tokens(from totals: [Int: [String: TokenCounts]], now: Date) -> Tokens {
        let newestDay = localEpochDay(of: now)
        let oldestDay = newestDay - windowDays + 1
        var byDay: [Int: TokenCounts] = [:]
        var byModel: [String: TokenCounts] = [:]
        for (day, models) in totals where day >= oldestDay && day <= newestDay {
            for (model, usage) in models {
                byDay[day, default: TokenCounts()].add(usage)
                byModel[model, default: TokenCounts()].add(usage)
            }
        }
        // No records at all is no history, not a month of zeroes.
        guard !byDay.isEmpty else { return Tokens(updatedAt: now, windowDays: windowDays, days: [], models: []) }
        // Otherwise every calendar day in the window — a fortnight away from
        // the keyboard has to stay a gap, or the x-axis stops being time.
        let days = (oldestDay...newestDay).map { Day(day: isoDay($0), usage: byDay[$0] ?? TokenCounts()) }
        return Tokens(updatedAt: now, windowDays: windowDays, days: days, models: ranked(byModel))
    }

    /// Heaviest first, ties broken by name. Dictionary order alone differs
    /// between runs, so an even split between two models would flip the top
    /// spot on every scan.
    static func ranked(_ byModel: [String: TokenCounts]) -> [ModelUsage] {
        byModel
            .map { ModelUsage(model: $0.key, usage: $0.value) }
            .sorted {
                $0.usage.inputOutput == $1.usage.inputOutput
                    ? $0.model < $1.model
                    : $0.usage.inputOutput > $1.usage.inputOutput
            }
    }

    /// One record's usage. Cache writes arrive either split by TTL
    /// (`cache_creation`) or, on older records, as one combined field — the
    /// split only matters for pricing, so both collapse to `cacheWrite`.
    static func tokenCounts(from json: [String: Any]) -> TokenCounts {
        var usage = TokenCounts(requests: 1)
        usage.input = json["input_tokens"] as? Int ?? 0
        usage.output = json["output_tokens"] as? Int ?? 0
        usage.cacheRead = json["cache_read_input_tokens"] as? Int ?? 0
        if let split = json["cache_creation"] as? [String: Any] {
            usage.cacheWrite = (split["ephemeral_5m_input_tokens"] as? Int ?? 0)
                + (split["ephemeral_1h_input_tokens"] as? Int ?? 0)
        } else {
            usage.cacheWrite = json["cache_creation_input_tokens"] as? Int ?? 0
        }
        return usage
    }

    // MARK: - Local day bucketing

    /// `"2026-09-04T03:47:33.335Z"` to the local calendar day it belongs to, as
    /// days since the epoch.
    ///
    /// The timestamp's own `YYYY-MM-DD` prefix would be free but wrong: the
    /// logs are UTC, so west of Greenwich an evening's work lands on
    /// tomorrow. `ISO8601DateFormatter` costs seconds per scan at this record
    /// count, hence the hand-rolled parse.
    static func localEpochDay(iso8601: String, offsetMinutes: Int) -> Int? {
        let bytes = Array(iso8601.utf8)
        guard bytes.count >= 16 else { return nil }
        func number(_ range: Range<Int>) -> Int? {
            var value = 0
            for index in range {
                let digit = Int(bytes[index]) - 48
                guard (0...9).contains(digit) else { return nil }
                value = value * 10 + digit
            }
            return value
        }
        guard let year = number(0..<4), let month = number(5..<7), let day = number(8..<10),
              let hour = number(11..<13), let minute = number(14..<16),
              (1...12).contains(month), (1...31).contains(day)
        else { return nil }

        let minutesLocal = hour * 60 + minute + offsetMinutes
        // Floor division — a negative local time means the previous day.
        let shift = Int(floor(Double(minutesLocal) / 1440))
        return daysFromCivil(year: year, month: month, day: day) + shift
    }

    static func localEpochDay(of date: Date) -> Int {
        let shifted = date.timeIntervalSince1970 + Double(TimeZone.current.secondsFromGMT(for: date))
        return Int(floor(shifted / 86400))
    }

    static func isoDay(_ epochDay: Int) -> String {
        let civil = civilFromDays(epochDay)
        return String(format: "%04d-%02d-%02d", civil.year, civil.month, civil.day)
    }

    /// Howard Hinnant's `days_from_civil` / `civil_from_days`, used instead of
    /// `Calendar` because this runs once per log record.
    static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = year - (month <= 2 ? 1 : 0)
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    static func civilFromDays(_ epochDay: Int) -> (year: Int, month: Int, day: Int) {
        let z = epochDay + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let day = doy - (153 * mp + 2) / 5 + 1
        let month = mp + (mp < 10 ? 3 : -9)
        return (yoe + era * 400 + (month <= 2 ? 1 : 0), month, day)
    }
}

/// Reads JSONL transcripts from where the last run stopped. They're
/// append-only while a session lives, so a byte offset is all the progress
/// there is to keep.
enum Tail {
    struct Mark: Codable, Equatable {
        var inode: UInt64
        var offset: UInt64
    }

    private static let newline = UInt8(ascii: "\n")

    /// The complete lines appended to `url` since `mark`, and the mark after
    /// them. `fresh` when it read from the top: no mark, or the file was
    /// replaced (new inode) or rewritten shorter.
    ///
    /// Read, not mapped. These files are being written by live sessions, and
    /// touching a mapped page whose file has since been truncated raises
    /// SIGBUS, which can't be caught.
    static func read(_ url: URL, after mark: Mark?) -> (data: Data, mark: Mark, fresh: Bool)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0 else { return nil }
        let inode = UInt64(info.st_ino)
        let size = UInt64(info.st_size)
        let resume = mark.flatMap { $0.inode == inode && $0.offset <= size ? $0.offset : nil }
        let start = resume ?? 0
        guard size > start else { return (Data(), Mark(inode: inode, offset: start), resume == nil) }
        guard (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.read(upToCount: Int(size - start))
        else { return nil }

        // A session mid-write leaves half a line; it's read whole next run.
        // A last line that already parses is just a file that doesn't end
        // in a newline.
        var end = data.count
        if data.last != newline {
            let lineStart = data.lastIndex(of: newline).map { $0 + 1 } ?? 0
            if (try? JSONSerialization.jsonObject(with: Data(data[lineStart...]))) == nil { end = lineStart }
        }
        return (data.prefix(end), Mark(inode: inode, offset: start + UInt64(end)), resume == nil)
    }

    /// Calls `body` with each non-empty line. Hand-rolled: the generic
    /// Collection split was ~60% of a full scan's CPU, and its per-line
    /// temporaries pushed peak footprint past 500 MB.
    static func forEachLine(in data: Data, _ body: (UnsafeRawPointer, Int) -> Void) {
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let start = base + offset
                let remaining = buffer.count - offset
                let length = memchr(start, Int32(newline), remaining).map { UnsafeRawPointer($0) - start } ?? remaining
                offset += length + 1
                if length > 0 { body(start, length) }
            }
        }
    }
}
