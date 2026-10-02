# Claude Usage Widget

A macOS menu bar app that shows how much of your Claude subscription limits you have
used. Optionally, it pauses runaway Claude Code sessions when usage suddenly jumps.

```
✳︎ S 42%  W 17%
```

`S` is the current 5-hour session limit, `W` the weekly (7-day) limit. Both are the same
numbers as on [claude.ai/settings/usage](https://claude.ai/settings/usage).

> Unofficial. Not affiliated with or endorsed by Anthropic. It relies on the usage
> endpoint and login that Claude Code itself uses, neither of which is a documented
> public API, so it can stop working when Claude Code changes.

## Features

### Usage in the menu bar

- Session (5h) and weekly (7d) utilization, refreshed every 60 seconds and right after
  the Mac wakes from sleep.
- Values turn orange from 75% and red from 90%.
- `⏸N` appears while N processes are paused by the spike guard, `⚠︎` when the last
  refresh failed (the reason is shown in the menu).

### Details in the menu

- Each limit with its reset time: current session, weekly, weekly Opus, weekly Sonnet.
- Extra usage spent against the monthly limit, if extra usage is enabled on the account.
- **Top sessions this window**: the five local Claude Code sessions that used the most
  tokens since the current 5-hour window started, with folder, git branch, session title
  and share of local tokens. Subagent usage counts towards the session that spawned it.
- **Refresh Now** (`⌘R`), **Open Usage Page…**, **Launch at Login**, **Quit** (`⌘Q`).

### Spike guard (optional)

The widget asks on first launch whether to turn it on. You can change that any time
with **Spike Guard** in the menu; the choice is remembered. While it is off the widget only shows usage: it never looks at your processes, shows no
alert and pauses nothing.

A spike is the session utilization rising by X percentage points or more within
N minutes. Both are set in the menu under **Threshold** (5, 10, 15, 20 or 30% of the limit)
and **Window** (2, 5, 10, 15 or 30 minutes); the default is +10% of the limit in 5 minutes and
the choice is remembered. When a spike happens the widget:

1. Works out which local Claude Code sessions made API calls during the rise, and matches
   them to running `claude` processes by working directory.
2. Shows an alert listing each session: folder, branch, title, last prompt, process id,
   host app (Terminal, iTerm2, VS Code, tmux, …), API calls, models and token counts.
3. Pauses the sessions marked `PAUSE` after 15 seconds unless you click **Don't pause**.
   **Pause now** does it immediately. Both buttons need a click; Return and Escape are
   ignored so a stray keystroke can't decide for you.

Pausing sends `SIGSTOP` to the `claude` process and everything it started (tool
commands, builds, …). Nothing is killed and no work is lost.

To resume a paused session:

- If it was running in the foreground of a terminal, type `fg` in that terminal. The
  menu tells you which terminal.
- Otherwise use **Resume …** in the widget's menu.

Things worth knowing:

- If the usage came from somewhere else (claude.ai, another device, Claude Code on the
  web), the alert says so and nothing is paused.
- Several `claude` processes in the same folder can't be told apart, so all of them are
  paused.
- The Claude desktop app is never paused; only the `claude` CLI is matched.
- The list of paused processes lives in memory. If you quit the widget while something
  is paused, resume it with `fg` or `kill -CONT <pid>`.
- While the usage API rate-limits the widget, it backs off (2 to 10 minutes) and the
  spike guard can't see usage until it recovers.

While the guard is on, **Test Spike Alert** shows the alert for your current sessions
without pausing anything.

### No tracking

The widget keeps no log and no history. Everything it knows about your sessions is held
in memory for the current 5-hour window and is gone when it quits. The only thing it
saves is your menu settings (spike guard on/off, threshold, window).

## Requirements

- macOS 13 or later on Apple silicon
- Xcode Command Line Tools (`xcode-select --install`) for `swiftc`
- [Claude Code](https://claude.com/claude-code) installed and logged in with a Claude
  subscription (Pro, Max, Team). The widget reuses that login; it has no login of its own.

## Install

```sh
git clone https://github.com/Alex-Sessler/claude-usage-widget.git
cd claude-usage-widget
./build.sh --install
```

This builds `ClaudeUsage.app`, copies it to `~/Applications` and launches it. Run the
same command again to update. Without `--install` the app is only built to
`build/ClaudeUsage.app`.

The app is ad-hoc signed and has no Dock icon; it lives in the menu bar only. Enable
**Launch at Login** from its menu if you want it to start automatically.

## Uninstall

1. If the menu lists anything under **Paused by spike guard**, resume it first: use
   **Resume …** in the menu, or type `fg` in the terminal it names.
2. Untick **Launch at Login** in the menu if it is ticked, so macOS drops the login item.
3. Choose **Quit**.
4. Delete the app and its saved menu settings:

```sh
rm -rf ~/Applications/ClaudeUsage.app
defaults delete local.claude-usage-widget
```

That removes everything; the widget keeps no other files. If you quit while a session
was still paused, resume it with `fg` in its terminal or `kill -CONT <pid>`.

## Configuration

Environment variables, read at launch. To set them, start the binary directly, for
example:

```sh
CLAUDE_USAGE_POLL_SECONDS=30 ~/Applications/ClaudeUsage.app/Contents/MacOS/ClaudeUsage
```

| Variable | Default | Purpose |
| --- | --- | --- |
| `CLAUDE_USAGE_POLL_SECONDS` | `60` | Seconds between refreshes |
| `CLAUDE_CONFIG_DIR` | `~/.claude` | Claude Code's config folder, same override Claude Code honors |
| `CLAUDE_USAGE_FAKE_FILE` | – | Testing: read the usage response from this JSON file instead of the API |
| `CLAUDE_USAGE_SNAPSHOT` | – | Testing: write a PNG of the spike alert to this path |

The spike threshold and window are set in the menu (see [Spike guard](#spike-guard)).
The alert timeout (15 seconds) is a constant in
[`Sources/Config.swift`](Sources/Config.swift); change it there and rebuild.

## How it works

- **Usage numbers** come from `https://api.anthropic.com/api/oauth/usage`, called with
  Claude Code's OAuth access token. The token is read from the login Keychain on every
  poll via `/usr/bin/security`, used for that one request and never stored or logged.
- **Local activity** comes from tailing Claude Code's transcripts in
  `~/.claude/projects/**/*.jsonl` and summing the token usage of each API response.
- **Processes** are found with `ps` and their working directories with `lsof`, only
  while the spike guard is on.

Spike detection uses only the account-wide utilization from the API, because that is
what the limit is counted on. Local token counts are used only to find out who was
active.

The only network request the widget makes is the usage call to `api.anthropic.com`.

## Troubleshooting

| Menu shows | What to do |
| --- | --- |
| No Claude Code login found in Keychain | Run `claude` and log in |
| Token expired | Run `claude` once so it refreshes the login |
| Usage API is rate limiting | Wait; the widget retries on its own |
| Usage API returned HTTP … | Usually temporary; **Refresh Now** to retry |

## Project layout

| File | Role |
| --- | --- |
| `Sources/main.swift` | Menu bar app, polling, spike alert, menu |
| `Sources/Usage.swift` | Usage API client, Keychain access, formatting |
| `Sources/SpikeGuard.swift` | Spike detection, candidate attribution |
| `Sources/Transcripts.swift` | Transcript tailing, per-window token tally, session context |
| `Sources/Processes.swift` | Process table, pause and resume |
| `Sources/Config.swift` | Constants and environment overrides |
| `build.sh` | Builds, signs and optionally installs the app |

No dependencies beyond the macOS SDK.

## License

[MIT](LICENSE)
