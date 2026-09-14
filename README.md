# Coding Plan Quota (quota-widget)

**English** · [简体中文](README.zh-CN.md)

A macOS menu bar app that shows how much of your coding plan you have left.
The menu bar reports the tracked plan's **5h / 1w / 1m** percentages; click the
gauge and a panel drops down with one card per provider — every metered window
with a progress bar, the reset countdown, and whatever balances or spend the
provider reports. A settings screen inside the panel picks the tracked plan and
which providers are shown.

![The dropdown panel](docs/panel.png)

It is a native SwiftUI app — one Swift package, no Electron, no background
daemon. It reads the credentials your CLI agents already wrote to disk, so in
most cases there is nothing to configure.

```
● Command Code                                   [individual-goat · active]
  alice
  5h                  ███░░░░░░░░░░░░░░░░░  19% left  / 14
  11.41 used  of 14 credits  ·  resets 14:06 · in 2h 52m
  1w                  █████████████░░░░░░░  67% left  / 35
  11.41 used  of 35 credits  ·  resets Sep 21 09:06 · in 6d 21h
  1m                  ████████████████░░░░  84% left  / 70
  11.41 used  of 70 credits  ·  resets Oct 14 08:58 · in 29d 21h
  Credits remaining   58.59   monthly 58.59 · purchased 0 · free 0
  Usage this period   $11.22   4.3k calls · 475.3M tokens
  via ~/.omp/agent/agent.db:commandcode
```

The menu bar itself shows the same three numbers, tinted by the tightest one:

| `menuBarStyle` | Renders as |
| --- | --- |
| `windows` (default) | `19/67/84` |
| `labeled` | `5h19 1w67 1m84` |
| `worst` | `19%` |

The screenshots above are rendered from the real views with illustrative data
(`--preview --demo`), so they contain nobody's account or usage.

## Install

Requires macOS 14+ and the Swift toolchain (Command Line Tools is enough —
Xcode is not required).

```bash
./Scripts/build-app.sh     # builds dist/QuotaWidget.app
./Scripts/install.sh       # copies to /Applications and launches
```

To launch without installing: `open dist/QuotaWidget.app`.

The app has no Dock icon (`LSUIElement`), starts refreshing as soon as it
launches, and picks up `config.json` edits on the next refresh without a
relaunch. Tick **Login** in the panel footer to start it at login.

### Configuring from the panel

The sliders icon in the panel header opens Settings:

- **Tracked plan** — which provider the menu bar reports on. *Tightest across
  all* follows whichever plan is closest to running out; picking one pins it, so
  that plan is still shown when it is failing rather than silently swapping to
  another.
- **Menu bar** — the three summary styles above, and whether to show the numbers
  at all.
- **Providers** — enable, remove, or add a provider. Adding one that still needs
  a key shows up as *unconfigured* with a hint.

Settings writes `config.json` directly (mode `600`), so the panel and the file
never drift apart.

![Settings](docs/settings.png)

## Providers

| Type | Plan | Credential |
| --- | --- | --- |
| `commandcode` | Command Code subscription | `~/.omp/agent/agent.db`, a `commandcode` credential, or `COMMAND_CODE_API_KEY` |
| `opencode-go` | OpenCode Go | `opencode-go` credential, or `OPENCODE_API_KEY` |
| `ollama-cloud` | Ollama Cloud | `ollama-cloud` credential, or `OLLAMA_API_KEY` |
| `zai` | Z.ai GLM Coding Plan | `zai` credential, or `ZAI_API_KEY` |
| `zhipu` | Zhipu / bigmodel.cn Coding Plan | `zhipu` credential, or `ZHIPU_API_KEY` |
| `kimi` | Kimi Code | `kimi-for-coding` credential, or `KIMI_API_KEY` |
| `minimax` | MiniMax Token Plan | `minimax-coding-plan` credential (cookie) |
| `minimax-cn` | MiniMax Token Plan (mainland) | `minimax-cn-coding-plan` credential (cookie) |
| `anthropic` | Claude Pro / Max | `anthropic` credential (OAuth) |
| `openai` | ChatGPT Plus / Pro | `openai` credential (OAuth) |
| `deepseek` | DeepSeek balance | `deepseek` credential, or `DEEPSEEK_API_KEY` |
| `openrouter` | OpenRouter key budget | `openrouter` credential, or `OPENROUTER_API_KEY` |
| `custom` | Anything else | Your own URL (see below) |

A provider with no credential is shown as **unconfigured** with a hint, rather
than disappearing — so you can see what the app knows how to read.

## Everything lives in one file

`~/.config/quota-widget/config.json` holds the provider list **and** the
credentials. Nothing else needs editing, and once credentials are in there the
widget does not depend on any other file.

```json
{
  "refreshIntervalSeconds": 300,
  "warnThreshold": 25,
  "criticalThreshold": 10,
  "showMenuBarText": true,
  "credentials": {
    "opencode-go": { "type": "api", "key": "..." },
    "ollama-cloud": { "type": "api", "key": "..." },
    "deepseek": { "type": "api", "key": "..." },
    "minimax-cn-coding-plan": { "type": "cookie", "cookie": "session=..." },
    "anthropic": { "type": "oauth", "access": "...", "refresh": "...", "expires": 4102444800000 }
  },
  "providers": [
    { "type": "commandcode" },
    { "type": "opencode-go", "credential": "opencode-go" },
    { "type": "ollama-cloud", "credential": "ollama-cloud" },
    { "type": "deepseek", "credential": "deepseek" }
  ]
}
```

The file contains secrets, so it is written with mode `600`. If it is ever
group- or world-readable while holding credentials, the panel says so with the
`chmod` command to fix it.

### Credentials are pulled in automatically

A config with nothing stored yet gets the keys its providers need copied in on
first launch, so a fresh install ends up fully centralized without a manual
step. After that the file is left alone: an empty slot means you removed it.

If a credential is still only available outside the file — a key added by a CLI
since, or a provider you just enabled — the panel says so and offers a one-click
**Copy into config.json**:

```
1 credential (commandcode) still read from ~/.omp/agent/agent.db (sqlite)
[ Copy into config.json ]
```

The same thing from the command line:

```bash
Q="/Applications/QuotaWidget.app/Contents/MacOS/QuotaWidget"
$Q --migrate-auth     # scans agent DBs + auth files + shell env, writes config.json
$Q --auth             # shows which credential each provider will use
```

OAuth access tokens are deliberately **not** copied. They rotate every few hours,
so a snapshot in the config would shadow the fresh token the CLI keeps writing and
break the provider; those stay live-read from the CLI's own file.

`--migrate-auth` reads the `omp`/`pi` agent SQLite databases
(`~/.omp/agent/agent.db`, table `auth_credentials`) plus `~/.commandcode/auth.json`,
`~/.pi/agent/auth.json`, `~/.omp/agent/auth.json`,
`~/.local/share/opencode/auth.json`, `~/.config/opencode/auth.json`,
`~/.codex/auth.json` and `~/.claude/.credentials.json`. It leaves all of those
untouched, keeps any value already in your config, never prints secret material,
and by default copies only the names your configured providers read — pass
`--all` to take everything found.

Agents that keep logins in SQLite (notably `omp`) are read directly, so a
Command Code key stored in `~/.omp/agent/agent.db` is used without any migration
step at all.

Re-run it after a new CLI login. It is also worth running once from your
terminal even if you set keys via `.zshrc`: **a menu bar app launched from Finder
does not inherit your shell environment**, so an exported `ZAI_API_KEY` never
reaches the widget. Moving it into the config file makes it work everywhere.

### Where a credential comes from

Resolution order, highest first:

1. `credential` on the provider — names an entry in the `credentials` map
2. `apiKey` on the provider (`${VAR}` is expanded)
3. The `credentials` entry matching the provider's id or an alias
   (`kimi` → `kimi-for-coding`, `minimax-cn` → `minimax-cn-coding-plan`, …)
4. `apiKeyEnv`, then the provider's own environment variables
5. The omp/pi agent SQLite databases (`~/.omp/agent/agent.db`), then the JSON
   auth files above, if `useExternalAuthFiles` is left on. Anything found here
   that a provider needs shows up in the panel as *Copy into config.json*.

Set `"useExternalAuthFiles": false` to make `config.json` the *only* source;
then a new CLI login is picked up only after `--migrate-auth`. Leaving it on is
the more forgiving default: the config always wins, and the files act as a
fallback for names the config does not mention.

Values may point at a secret manager — `"key": "${MY_KEY}"` reads the
environment variable at load time.

## Configuration reference

`~/.config/quota-widget/config.json` is created on first launch (and by
`--init`). Every field is optional except `type`.

```json
{
  "refreshIntervalSeconds": 300,
  "warnThreshold": 25,
  "criticalThreshold": 10,
  "showMenuBarText": true,
  "menuBarProvider": null,
  "useExternalAuthFiles": true,
  "credentials": {},
  "providers": [
    { "type": "commandcode" },
    { "type": "opencode-go" },
    { "type": "ollama-cloud" },
    { "type": "zai", "apiKeyEnv": "ZAI_API_KEY" },
    { "type": "zhipu", "enabled": false },
    { "type": "kimi" },
    { "type": "minimax" },
    { "type": "minimax-cn", "enabled": false },
    { "type": "anthropic" },
    { "type": "openai" },
    { "type": "deepseek", "enabled": false },
    { "type": "openrouter", "enabled": false }
  ]
}
```

| Field | Meaning |
| --- | --- |
| `refreshIntervalSeconds` | Poll interval, minimum 30. Default 300. |
| `warnThreshold` / `criticalThreshold` | The percentages that turn a bar orange / red. |
| `showMenuBarText` | Show the percentage next to the menu bar icon. |
| `menuBarProvider` | Pin the menu bar reading to one provider instead of the tightest across all. |
| `useExternalAuthFiles` | Also read the CLI agents' `auth.json` files and databases. Default `true`. |
| `autoConsolidateCredentials` | On a config with no stored credentials, copy in the keys the providers need. Default `true`. |
| `credentials` | The credential vault, keyed by name. See above. |
| `name` | Label for the card. Defaults to the provider's own name. |
| `id` | Stable identity — set it to run two accounts of the same provider side by side. |
| `credential` | Name of the `credentials` entry this provider should use. |
| `authScheme` | `raw` (default for `zai`/`zhipu`) or `bearer`. |
| `cookie` / `cookieEnv` | Full `Cookie` header value, for providers gated on a web session (MiniMax). |
| `enabled` | Set `false` to keep an entry configured but out of the panel. |

Keep only what you use — a short `providers` list makes the panel quicker to
scan. The menu bar shows the tightest window across all healthy providers, so a
plan about to run dry is visible without opening the panel.

## Custom providers

For a coding plan with no built-in support, point `custom` at any JSON endpoint.

**`quota-v1`** — the endpoint returns the shape the panel wants:

```json
{
  "plan": "Studio",
  "account": "team@example.com",
  "windows": [
    { "label": "5-hour", "used": 10, "limit": 50, "unit": "requests",
      "resetAt": "2026-09-14T15:30:00Z" }
  ],
  "metrics": [{ "label": "Balance", "value": "12.50", "detail": "USD" }]
}
```

**`json-v1`** — map your endpoint's own shape with dot paths:

```json
{
  "type": "custom",
  "name": "My Plan",
  "url": "https://api.example.com/quota",
  "format": "json-v1",
  "planPath": "data.plan_name",
  "windowsPath": "data.limits",
  "windowFields": {
    "label": "name",
    "used": "used_count",
    "limit": "total",
    "resetAt": "reset_at"
  },
  "metricPaths": { "Balance": "data.balance" }
}
```

Headers may reference the environment (`"headers": { "x-api-key": "${MY_KEY}" }`),
and a header whose variable resolves empty is dropped. If your plan has a fixed
allowance and no usage endpoint, declare `staticWindows` instead of a `url` and
the panel will still show the reset schedule:

```json
{
  "type": "custom",
  "name": "Flat plan",
  "url": "https://api.example.com/quota",
  "staticWindows": [{ "label": "Monthly", "remainingPercent": 100 }]
}
```

## Command line

The same binary doubles as a scriptable status command.

```bash
Q="/Applications/QuotaWidget.app/Contents/MacOS/QuotaWidget"

$Q --check                 # text report; exit 1 if any quota is under warnThreshold
$Q --check --quiet         # exit code only — handy for a shell prompt or CI gate
$Q --json                  # full report as JSON
$Q --json --provider zai   # one provider
$Q --preview /tmp/panel.png  # render the panel offscreen to a PNG
$Q --preview /tmp/s.png --settings   # render the settings screen instead
$Q --migrate-auth          # copy credentials in from auth files + shell env
$Q --auth                  # show where each credential comes from
$Q --init                  # write a config template
```

`--json` emits `summary` plus a `providers` array, where each window carries
`used`, `limit`, `remainingPercent`, `resetAt` and `resetsInSeconds`:

```json
{
  "summary": { "ok": 1, "failed": 1, "unconfigured": 1, "worstRemainingPercent": 33 },
  "providers": [
    {
      "id": "commandcode", "name": "Command Code", "status": "ok",
      "plan": "pro · active", "account": "acme · laptop",
      "windows": [
        { "id": "fiveHour", "label": "5-hour", "used": 12, "limit": 40,
          "remainingPercent": 70, "resetAt": "2026-09-14T15:30:00Z", "resetsInSeconds": 47000 }
      ]
    }
  ]
}
```

A `status-bar` snippet, for example:

```bash
$Q --json | jq -r '.summary.worstRemainingPercent | "⬤ \(.)%"'
```

## Development

```bash
swift build            # debug binary at .build/debug/QuotaWidget
swift test             # 199 tests, no network access required
./Scripts/build-app.sh --debug
```

The test suite drives every provider through a stubbed HTTP transport, so the
parsers are verified against recorded payload shapes without needing real keys.

### Layout

```
Sources/QuotaWidget/
  App/           @main entry point and app delegate
  Core/          config, credentials, auth migration, HTTP, models, refresh orchestration
  Providers/     one file per provider family
  UI/            menu bar label, dropdown panel, cards, offscreen renderer
  CLI/           argument parsing, JSON and text reports
Tests/QuotaWidgetTests/
Scripts/         build-app.sh, install.sh
```

### Adding a provider

1. Add a type conforming to `QuotaProvider` under `Providers/`. Implement
   `typeID`, `displayName`, and `fetch(_:)`, returning `ProviderQuota`.
   Return `.notConfigured` when no credential is present — never throw for that.
   Report `credentialSource` on failures too, so the panel can say which
   credential was used.
2. Register it in `ProviderRegistry.providers`.
3. Add its credential aliases to `ProviderRegistry.credentialAliases`.
4. Add it to `QuotaWidgetConfig.default` (with `enabled: false` if it needs
   manual setup), and to `AuthMigrator.providerNames` so `--migrate-auth` knows
   the name is consumed.
5. Add a test using `Stub.routing([...])` to cover the payload shape and the
   missing-credential path.

Use `Parse.window(...)` for windows: it handles the used/limit, remaining
percentage, reset-timestamp and reset-offset aliases that these APIs use
inconsistently.

### Notes on the upstream APIs

- **OpenCode Go** is behind Cloudflare, whose bot rule rejects requests without
  a `User-Agent`. The shared client always sends one; a bare `curl`-style client
  gets `403 Error 1010`. The three windows report `percent` as *used*.
- **Ollama Cloud** reports `limits.{session,weekly}.usage` as a *fraction used*
  (0…1), not a percentage, and `activity.period` is a trailing lookback — so it
  shows the date range rather than a reset countdown.
- **Z.ai / Zhipu** read the bare API key in `Authorization` (no `Bearer`) and
  report failures as HTTP 200 with `success: false`.
- **MiniMax** returns `current_interval_usage_count` as *remaining* on the
  international endpoint and as *used* on the mainland one. Its quota endpoints
  are gated on the platform **web session**, not an API key — an API key gets
  `1004 login fail`. Sign in to `minimax.io` / `minimaxi.com`, copy the `Cookie`
  request header from devtools, and set `MINIMAX_COOKIE` / `MINIMAX_CN_COOKIE`
  (or a `cookie` credential in the config). An API key is still tried first,
  since some plans do accept one.
- **Claude and ChatGPT** use OAuth tokens from the CLIs. Expired tokens are
  reported as such rather than silently refreshed, and a plain API key cannot
  read subscription quota.
- **Command Code** follows the same `/alpha/whoami` → `billing/credits` +
  `billing/subscriptions` + `usage/summary` sequence as the
  `pi-commandcode-provider` extension. Set `CMD_ZDR=1` to forward
  `x-cmd-zdr: 1`. Its API reports caps for the 5h and 1w windows and only the
  *remaining* monthly balance, so the 1m percentage comes from the plan's
  published monthly allowance (Go 10, GOAT 70, Pro 80, Max 10× 150, Max 20× 300,
  Team Pro 40). An unrecognised plan gets no 1m window rather than an invented
  number; override with `"monthlyAllowance": 70` on the provider.

## License

MIT
