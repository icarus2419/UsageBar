# Usage Battery

An iPhone-style battery for your **Claude** and **OpenAI (ChatGPT/Codex)** plan limits. It sits in a small frosted pill that floats on screen, and it also shows in the menu bar next to the Mac's own battery.

```
 ╭──────────────────────────╮
 │ ✳ [▮▮▮▯ 21]   ⬡ [▮▮▮▮ 43] │     click → detail card · right-click → settings · drag → snaps to edges
 ╰──────────────────────────╯
```

The battery shows how much of each limit you have **left** (100 − used). By default it shows whichever window is closer to running out: the 5-hour session or the weekly limit. When the weekly limit is the one shown, a small **W** appears beside the battery.

## Install

Requires macOS 13 or later and the Xcode Command Line Tools (`xcode-select --install`).

```sh
make install     # builds, copies to ~/Applications, launches
```

Other targets:

| Command | What it does |
| --- | --- |
| `make app` | Builds `build/Usage Battery.app` (ad-hoc signed, with its icon) |
| `make run` | Builds and launches from `build/` |
| `make test` | Runs the parser and logic tests |
| `make print` | Prints current usage in the terminal |
| `make uninstall` | Removes the app from `~/Applications` |


To start it when you log in, right-click the widget and choose **Launch at Login**.

## Setup

None, as long as you are signed in to the command-line tools:

- **Claude:** sign in to [Claude Code](https://claude.com/claude-code) once (run `claude`).
- **OpenAI:** sign in to [Codex](https://github.com/openai/codex) with your ChatGPT account (`codex login`). Plan limits don't apply to API-key logins.

## Using it

- **Stick it:** drag it anywhere. It snaps to screen edges, corners and the top or bottom centre, and remembers its position. *Widget → Lock Position* pins it in place.
- **On top or on the desktop:** *Widget → Float Above All Windows* keeps it above everything, including full-screen apps and every Space. *Stick to Desktop* puts it behind your windows like a desktop widget.
- **Click** for the detail card: readable remaining percentages, every window's bar, "refills in 2h 13m" countdowns, your plan, the source and age of each reading, and links to each provider's usage page. Switch between Lowest, 5-hour, and Weekly directly in the card.
- **Right-click** (or use the menu bar item) for settings: metric, providers, horizontal/vertical layout, size, opacity, appearance, coloured or iOS-mono batteries, provider names, refresh interval, alerts and launch at login.
- **Low-battery alerts** arrive at 20% and 10%, like an iPhone. You also get a notification when a limit is used up and when it recharges ⚡.
- Colours: green above 50%, yellow from 20% to 50%, red below 20%. A flat battery turns its body red.

## How it gets the numbers

| | Source | Fallback |
| --- | --- | --- |
| Claude | `GET https://api.anthropic.com/api/oauth/usage` (the same data as `/usage` in Claude Code), using Claude Code's login from the Keychain item `Claude Code-credentials` | none |
| OpenAI | `GET https://chatgpt.com/backend-api/wham/usage`, using Codex's login in `~/.codex/auth.json` (`$CODEX_HOME` is honoured) | the latest `rate_limits` snapshot Codex writes to `~/.codex/sessions/…/rollout-*.jsonl` |

- Usage is polled every 2 minutes (1, 2, 5 or 10 are selectable).
- Codex log changes trigger a local read through macOS filesystem events (0.35-second event latency). The battery updates when Codex writes a new usage snapshot; it cannot update before the provider/tool reports one. A 15-second timer with 5 seconds of scheduling tolerance catches missed events.
- The reader considers the 32 most recently modified session files, including resumed sessions in older folders, and selects the newest valid timestamped usage snapshot. It reads at most 512 KiB per changed file and caches unchanged tails in memory. A new empty session or partial Unicode character does not hide valid data.
- The app backs off on errors and rate limits (honouring `Retry-After`), pauses while the Mac sleeps, and shows the last cached reading straight away on launch.
- Checks never overlap for the same provider. Repeated manual refreshes are limited to once per 20 seconds, and cannot bypass a server rate-limit wait.
- When a reset time passes, the battery projects the refill on its next local tick, without waiting for the next fetch. The detail card labels this as awaiting a fresh reading.
- Readings older than about 10 minutes go dim. An orange dot means something needs your attention; the detail card explains what.

Claude updates on the selected polling interval; it does not have the Codex log-event path. These usage endpoints are undocumented, so the parsers read them defensively. If a provider changes its format, that provider shows an error and the other keeps working.

## Do checks use AI tokens?

**No model prompts or inference requests are made by Usage Battery.** It reads existing usage data. Its HTTP transport only accepts the two exact HTTPS usage URLs above, uses `GET` with no body, and refuses redirects. Generation endpoints and URLs with extra query parameters are rejected before a request is sent. Local Codex updates require no network traffic.

The app's checks are separate from the AI conversations whose usage it displays. Using Claude or Codex normally still consumes your plan allowance. Usage-service requests can be rate limited even though they do not run a model.

## Privacy and security

- **Read-only credentials.** The app reads the tokens Claude Code and Codex already stored. It never writes, refreshes or rotates them, so it can't sign either tool out.
- It reads the Keychain item through `/usr/bin/security`. Claude Code created the item with that tool, so macOS doesn't show a Keychain prompt.
- If Claude's token has expired, the app runs `claude auth status` (at most every 10 minutes) and re-reads the login. This is an [authentication-status command](https://code.claude.com/docs/en/cli-reference), not a model prompt. If the installed CLI does not refresh the login, the app asks you to open Claude Code.
- Tokens are held in memory only for the length of a request. They are sent only to the provider that issued them (`api.anthropic.com` or `chatgpt.com`), and they are never logged or cached. The only thing cached is the usage percentages, in the app's preferences.
- The app has no analytics or third-party dependencies. Its own network traffic is limited to usage checks. The optional Claude authentication-status subprocess is managed by Claude Code.

## Command line

```sh
"$HOME/Applications/Usage Battery.app/Contents/MacOS/UsageBattery" --print   # one line per provider
"$HOME/Applications/Usage Battery.app/Contents/MacOS/UsageBattery" --short   # ✳ 21%  ⬡ 43%
"$HOME/Applications/Usage Battery.app/Contents/MacOS/UsageBattery" --json    # machine-readable
```

`--short` works well in a Claude Code status line (`~/.claude/settings.json`):

```json
{ "statusLine": { "type": "command", "command": "\"$HOME/Applications/Usage Battery.app/Contents/MacOS/UsageBattery\" --short" } }
```

## Troubleshooting

| You see | Fix |
| --- | --- |
| `–` with an orange dot, "Not signed in" | Sign in to `claude` or `codex login` (see Setup). |
| "Login expired" on Claude | Open Claude Code once. It refreshes the token, and the widget picks it up within a poll. |
| "Rate limited" | Nothing to do. The app waits and retries. Choose a longer interval if it keeps happening. |
| The widget disappeared | Click the menu bar item → **Show Widget**, or open the app again from Finder or Spotlight. |
| Widget is off-screen after changing displays | Right-click the menu bar item → **Widget → Reset Position**. |

## Layout

```
Sources/UsageCore/      data layer: providers, parsing, formatting (no UI, unit tested)
  ClaudeSource.swift    Keychain login + /api/oauth/usage
  CodexSource.swift     auth.json login + /wham/usage + session-log fallback
  CodexLogWatcher.swift filesystem events for live local updates
  Models.swift          UsageWindow / ProviderUsage, reset projection
Sources/UsageBattery/   the app
  WidgetPanel.swift     floating panel: drag, snap, stick modes, popover
  UsageStore.swift      polling, back-off, caching, sleep/wake
  Views/                battery glyph, widget, detail card
  StatusItemController, MenuBuilder, Notifier, CLI
scripts/                build-app.sh (bundle + sign), make-icon.swift
```
