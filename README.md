# agent-usage

Tracks Claude Code usage once per machine and writes it to a file that any app
can read. Apps that display it never touch a credential or a transcript.

- **Quota** — the 5-hour, weekly and per-model windows, from the same OAuth
  endpoint Claude Code's `/usage` uses.
- **Tokens** — 30 days of input, output and cache tokens per day and per model,
  counted from `~/.claude/projects`. Counts only, nothing priced.

It's one process on purpose. Anthropic rotates the OAuth refresh token every
time it's used, so two apps each renewing their own copy keep invalidating each
other. Here only `agent-usage` ever holds the credential.

## Install

```sh
make install     # builds, self-tests, signs, and loads the launchd job
make run         # refresh now instead of waiting for the next interval
make uninstall
```

launchd runs `agent-usage refresh` every 5 minutes. Each run fetches the quota,
rescans the transcripts if the last scan is 10+ minutes old, writes the file and
exits. Errors go to `~/Library/Logs/agent-usage.log`.

The first run reads Claude Code's Keychain item, so expect one "allow access"
dialog; after that it keeps its own copy.

## The file

`~/Library/Application Support/AgentUsage/usage.json`, written atomically:

```json
{
  "schema": 1,
  "generatedAt": "2026-09-30T17:05:00Z",
  "quota": {
    "status": "ok",
    "updatedAt": "2026-09-30T17:05:00Z",
    "windows": [
      { "kind": "session", "percent": 30, "resetsAt": "2026-09-30T20:00:00Z" },
      { "kind": "weekly_all", "percent": 37, "resetsAt": "2026-10-03T14:00:00Z" },
      { "kind": "weekly_scoped", "model": "Opus", "percent": 62 }
    ],
    "spend": { "used": { "amountMinor": 4265, "currency": "USD", "exponent": 2 }, "enabled": true }
  },
  "tokens": {
    "updatedAt": "2026-09-30T17:00:00Z",
    "windowDays": 30,
    "days": [
      { "day": "2026-09-30", "usage": { "input": 0, "output": 0, "cacheWrite": 0, "cacheRead": 0, "requests": 0 } }
    ],
    "models": [
      { "model": "claude-opus-5-5", "usage": { "input": 0, "output": 0, "cacheWrite": 0, "cacheRead": 0, "requests": 0 } }
    ]
  }
}
```

Reading it:

- **Check `generatedAt`.** More than 15 minutes old means the job isn't
  running — say so rather than showing the numbers as current.
- **`quota.status`**: `ok`; `failed` (the last good windows are kept); `signedOut`
  (run `claude login`; windows are empty); `idle` (no Claude Code credential on
  this Mac).
- **`tokens.days`** covers every day in the window, idle days as zeroes. Empty
  means no history at all.
- **Lead with input + output.** Cache reads are usually most of the total.
- **`schema`** only changes when a field is renamed or removed. New optional
  fields keep it as is.

Swift apps can link the `AgentUsageModel` product instead of decoding by hand:
`Snapshot.load()`, `isStale()`, `windows.headline` / `.carveOuts`,
`QuotaWindow.label()`, `TokenCounts.format()`, `Day.label`.

## Checks

```sh
make selftest
```

## License

MIT, see [LICENSE](LICENSE). Not affiliated with or endorsed by Anthropic. The
quota endpoint is undocumented and may change without notice.
