# Architecture

ClaudeSwitcher is a SwiftUI menu-bar app that launches VS Code under one of two `CLAUDE_CONFIG_DIR` accounts. It is small — five source files, ~600 lines — but the design contains several non-obvious decisions. This document explains *why* the code looks the way it does. The full historical rationale lives in [`claude-switcher-prompt.md`](../claude-switcher-prompt.md); pointers below send you there when more detail helps.

## The problem

Claude Code stores all authentication tokens and configuration under a single directory, `~/.claude/` by default. Only one account can be "active" at a time. The community workaround is to set `CLAUDE_CONFIG_DIR` per launch (e.g. `~/.claude-personal` vs `~/.claude-work`) and start VS Code with that variable injected. ClaudeSwitcher automates the injection — one menu-bar click, no terminal.

## The central trap

The naive implementation is to shell out to the `code` CLI. **This silently produces wrong behavior.**

When VS Code is already running, the `code` CLI does not start a new process — it hands the request off to the existing VS Code via IPC. The IPC handoff drops every environment-variable change: the running process keeps the env it was launched with, and the Claude Code extension stays on the old account. The user sees VS Code come to the foreground and assumes the switch worked.

`NSWorkspace.openApplication(at:configuration:)` has the same trap baked in deeper: `OpenConfiguration.environment` is **only honored when launching a fresh process**. If an instance of the target app is already running, `openApplication` attaches to it and the environment override is silently ignored. There is no API to mutate the environment of a running process.

**Therefore:** if VS Code is already running and the user clicks a launch button, we must first terminate it (and wait for it to actually exit) before re-launching. This is the entire reason for the terminate-then-relaunch flow in [`VSCodeLauncher.launch`](../ClaudeSwitcher/VSCodeLauncher.swift). See [`claude-switcher-prompt.md` §5](../claude-switcher-prompt.md) for the full launcher edge-case taxonomy.

## "No active account" mental model

The app does **not** carry a globally "active" account. Each launch button is self-contained: *"Open VS Code — Personal"* launches with the personal config dir, *"Open VS Code — Work"* launches with the work config dir. The menu bar icon reflects the **last-launched** account purely as a visual hint — clicking either button always works regardless of icon state.

This avoids a class of bugs where a persisted "active" account drifts out of sync with what VS Code is actually running.

## Session-only vs persistent state

Two distinct lifetimes coexist in [`AppState`](../ClaudeSwitcher/AppState.swift):

| State | Lifetime | Why |
|---|---|---|
| `lastLaunched` | UserDefaults (persistent) | Menu bar icon survives relaunch. Cosmetic only — never gates launch behavior. |
| `hasCompletedSetup` | UserDefaults (persistent) | First-run flag. Means "the user has acknowledged setup at least once," not "setup is permanently done" — a later missing dir re-enters the setup flow. |
| `currentlyRunningAccount` | In-memory (session only) | Used by the PID-gated fast path. Persisting it would let a stale value claim VS Code is still running under an account when in fact the process is gone. |
| `launchedProcessIdentifier` | In-memory (session only) | The exact PID we launched. Persisting it is even worse — kernel PIDs are reused. |
| `isLaunching` | In-memory (session only) | Re-entrancy guard on the launch buttons. |
| `personalConfigDirExists` / `workConfigDirExists` | In-memory (session only) | Seeded from disk in `init()`, refreshed on every popover open. Persisting would let a deletion-while-app-closed go unnoticed. |

The session-only fields all begin `nil`/`false` on every fresh ClaudeSwitcher start, which means the first launch each session always falls through to the full quit-and-relaunch check. This is intentional: the app has no reliable way to know what env a VS Code it didn't launch was started with.

## The PID-gated same-account fast path

If the user clicks "Open VS Code — Personal" twice in a row, we shouldn't prompt them to quit and relaunch the second time. But we also can't skip the prompt just because the account matches: the user may have quit VS Code (Cmd-Q) and reopened it from the Dock in between — that externally-spawned process has no `CLAUDE_CONFIG_DIR`, and bringing it forward would silently leave the user on the default `~/.claude` dir.

The fast path therefore matches on **both** the account *and* the exact PID we launched ([`VSCodeLauncher.swift:76-81`](../ClaudeSwitcher/VSCodeLauncher.swift#L76-L81)). If either condition fails — different account, externally-relaunched VS Code, or our PID is gone — we fall through to the prompt path.

There is one further safety wrinkle. The kernel can reuse a PID for an unrelated process. So before matching on PID, we **filter `runningApplications` by bundle ID** ([`VSCodeLauncher.swift:66-67`](../ClaudeSwitcher/VSCodeLauncher.swift#L66-L67)) — a reused PID belonging to something that isn't VS Code is then implicitly excluded.

## The login-shell PATH dance

When the menu-bar app is launched from Login Items / Finder, `ProcessInfo.processInfo.environment` is the limited launchd environment. It typically lacks Homebrew, nvm, asdf, and any other PATH additions made in `~/.zshrc`. The Claude Code extension may need `node` / `npm` / `git` on PATH, so we have to inject the user's login-shell PATH into the launched VS Code.

[`ShellEnvironment.resolve`](../ClaudeSwitcher/VSCodeLauncher.swift#L266-L324) spawns the user's shell with `-ilc` (interactive + login + run-command) and extracts `$PATH` from its output. Three things make this robust against pathological rc files:

1. **Sentinel markers.** Rc files routinely print banners (oh-my-zsh, nvm progress) to stdout during init. A plain `echo $PATH` would be contaminated. We wrap the printf in `__CLAUDESWITCHER_PATH__%s__CLAUDESWITCHER_PATH__` and extract between the markers.
2. **stdin = /dev/null, stderr = /dev/null.** Interactive shells often try to `read` from stdin (fzf, version managers) or write to stderr in volumes that could fill an unread `Pipe()` and block the child. Both are nulled.
3. **3-second hard timeout via DispatchGroup.** A misconfigured rc file (a `read` blocking on terminal input, a network probe hanging) must not freeze the menu bar app. On timeout we send SIGTERM, log loudly via NSLog, and fall back to the launchd env. The launch still works; the user just won't see Homebrew on PATH inside VS Code.

The resolution is pre-warmed in [`ClaudeSwitcherApp.init()`](../ClaudeSwitcher/ClaudeSwitcherApp.swift#L12-L14) so the shell spawn is already in flight by the time the user clicks a launch button. The lock in `ShellEnvironment` only guards creation of the resolution `Task` — it is **never** held across the shell spawn. So even if the launcher's `await loginPath()` arrives before pre-warm finishes, the main thread suspends rather than blocks.

## Defending against the two-instance race

After the terminate-then-relaunch flow, there's a microsecond window where the user could manually open VS Code (from Finder or the Dock) between our "is anything still alive?" re-check and the `openApplication` call. To prevent silently attaching to that user-spawned instance (which would drop `CLAUDE_CONFIG_DIR`), we set `config.createsNewApplicationInstance = true` ([`VSCodeLauncher.swift:128`](../ClaudeSwitcher/VSCodeLauncher.swift#L128)). This forces a fresh process even if one is alive.

The trade-off: if the race actually happens, we end up with two VS Code processes alive simultaneously, which corrupts shared workspace-state files. So immediately after `openApplication` returns, we re-check `runningApplications` (filtered by `bundleIdentifier && !isTerminated`, [`VSCodeLauncher.swift:149-150`](../ClaudeSwitcher/VSCodeLauncher.swift#L149-L150)) and surface a user-visible alert naming the PID we launched, so the user can quit the *other* instance.

The bug is therefore **loud** (alert + two Dock entries), **recoverable**, and **astronomically rare** (the race window is on the order of microseconds and requires the user to physically launch VS Code in that window).

## See also

- [`code.md`](code.md) — file-by-file walkthrough with line references
- [`features.md`](features.md) — user-visible behavior
- [`verification.md`](verification.md) — the 16 manual test scenarios
- [`../claude-switcher-prompt.md`](../claude-switcher-prompt.md) — original design spec with full rationale
