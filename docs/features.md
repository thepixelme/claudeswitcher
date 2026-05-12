# Features

User-visible behavior, organized as **feature → mechanism**. For *why* the mechanisms look the way they do, see [`architecture.md`](architecture.md). For the source lines, see [`code.md`](code.md).

## Account launch (cold path)

**Behavior.** VS Code isn't running. User clicks *Open VS Code — Personal* (or *Work*). VS Code launches with `CLAUDE_CONFIG_DIR` set to the expanded path of the requested account.

**Mechanism.** `runningApplications` filtered by bundle ID is empty, so we skip straight to `NSWorkspace.openApplication(at:configuration:)` with `config.environment` carrying `CLAUDE_CONFIG_DIR` plus the merged login-shell PATH. `config.createsNewApplicationInstance = true` defends against a Finder-spawned VS Code racing in.

## Account launch (hot switch, different account)

**Behavior.** VS Code is already running under Personal. User clicks *Open VS Code — Work*. Confirmation modal appears in front: *"Quit VS Code to switch accounts?"* with "Quit & Relaunch" (default) and "Cancel" buttons. Confirming terminates VS Code, waits for it to exit, then launches afresh with the new env. Cancelling leaves everything untouched.

**Mechanism.** `runningApplications` is non-empty and the PID-gated fast path doesn't fire (different account). `confirmQuit` activates ClaudeSwitcher first so the alert is owned by a foreground app, then `runModal()`s. On confirm, `app.terminate()` is called on each running VS Code; `waitForExit` polls `isTerminated` for up to 8 seconds; a final re-check of `runningApplications` runs before `openApplication`.

## Account launch (same-account fast path)

**Behavior.** Same ClaudeSwitcher session, VS Code already running under Personal. User clicks *Open VS Code — Personal* again. **No quit prompt.** VS Code simply comes forward.

**Mechanism.** The PID-gated fast path: `currentlyRunningAccount == account` AND the tracked `launchedProcessIdentifier` is still in `runningApplications`. We call `NSRunningApplication.activate()` and return immediately. If the user has since Cmd-Q'd VS Code and reopened it from the Dock, the PID won't match — we fall through to the normal prompt path.

## Quit-and-relaunch error states

Three failure modes, three distinct user-facing messages:

- **TCC denied.** `NSRunningApplication.terminate()` returns `false` (Apple Event blocked because the user denied the "Control Visual Studio Code" permission). Surfaces as: *"ClaudeSwitcher could not ask VS Code to quit. macOS may have denied the Apple Events (Automation) permission — check System Settings → Privacy & Security → Automation…"*

- **Quit timed out.** `terminate()` returned `true` but VS Code is still alive after 8 seconds. Most likely cause: VS Code is showing its own "Save?" dialog for unsaved changes. Surfaces as: *"VS Code did not quit — likely waiting for you to handle unsaved changes. Try again."*

- **Launch failed.** `openApplication` threw. Surfaces as: *"VS Code failed to launch: <underlying message>"* — the underlying error is preserved.

All three produce an `NSAlert` modal. `userCancelledQuit` is the one error that produces **no** alert (deliberate user choice).

## Menu bar icon

**Behavior.**
- `person.circle` when Personal was the last-launched account.
- `building.2.crop.circle` when Work was the last-launched account.
- `exclamationmark.triangle.fill` when either config dir is missing.

**Mechanism.** The icon is bound to `AppState.menuBarIconName`, a computed property that folds the warning swap into a single string. The label closure of `MenuBarExtra` wraps an `@EnvironmentObject`-observing `MenuBarLabel` view (not a direct `state` read) so SwiftUI re-renders the label when `@Published` properties change. Icons render as **template images** — no color is set, so macOS tints them to match the menu bar's appearance (light/dark, focus state, accent-colour wallpaper). The two account symbols are visually distinct shapes; the warning triangle communicates by shape alone, no color guarantee.

The icon updates the instant a launch completes, without requiring the user to re-open the popover. If you see the icon only updating on next popover open, the `MenuBarLabel` wrapper has regressed.

## First-run setup

**Behavior.** Setup screen appears whenever `!hasCompletedSetup` OR either config dir is missing. The screen shows the curl install command and per-account `claude` login commands, all selectable. Three layouts depending on what's already present on disk:

- **Both `~/.claude-personal` and `~/.claude-work` exist** → short *"Both accounts detected."* status. Click "Get Started" to advance.
- **Exactly one exists** → full instructions plus a hint *"Personal detected; Work still needed."* (or the converse).
- **Neither exists** → full instructions, no hint.

**Mechanism.** The popover root (`MenuBarView`) gates on `hasCompletedSetup && personalConfigDirExists && workConfigDirExists`. `SetupView` switches over `(personalConfigDirExists, workConfigDirExists)` for its three layouts. "Get Started" re-stats both dirs at click time, then runs the same-canonical-path check (`resolvingSymlinksInPath().standardizedFileURL`) before flipping `hasCompletedSetup = true`. The re-stat is necessary because the user may have just finished `claude` login in another terminal while the popover was open.

## Post-setup recovery

**Behavior.** User deletes `~/.claude-work` while the app is running. Next popover open: the icon shows the warning triangle, and the popover shows `SetupView` (not `MainMenuView` with a disabled button).

**Mechanism.** Same gate as first-run — `MenuBarView` doesn't distinguish "first run" from "post-deletion." The seeded `*ConfigDirExists` flags in `AppState.init()` make the warning-triangle icon work *immediately* on app launch, before any popover opens. The `MainMenuView` safety-net branch (disabled button + inline "*~/.claude-work* not found. Re-run setup." text) exists for the brief window between popover open and `refreshConfigDirExistence` completing; in practice rarely visible because the seeded flags make the gate flip before the first render.

## Login-shell PATH inheritance

**Behavior.** VS Code launched by ClaudeSwitcher inherits the user's `~/.zshrc` PATH — Homebrew, nvm, asdf, anything else added there. So when the Claude Code extension runs `node` / `npm` / `git`, it finds them.

If the user's rc file is broken (a `read` hanging on stdin, a slow network probe), the app does **not** freeze. After up to 3 seconds it proceeds with the launchd PATH, logs `ShellEnvironment: ...` to Console.app, and VS Code's integrated terminal sees the limited launchd PATH.

**Mechanism.** `ShellEnvironment.shared.prewarm()` from `App.init()` starts a detached `Task` that spawns `$SHELL -ilc 'printf "%s" "$PATH"'` (wrapped in sentinel markers). The launcher awaits the same `Task` via `loginPath()` — the lock guards `Task` creation only, never the spawn, so the main thread suspends rather than blocking. 3-second `DispatchGroup` timeout sends SIGTERM and returns an empty dict on failure.

## Re-entrancy guard on launch buttons

**Behavior.** Double-clicking a launch button (or clicking the other one while one launch is mid-flight) does nothing. Both buttons appear disabled while a launch is in progress.

**Mechanism.** `AppState.isLaunching` is set to `true` **synchronously before** the launch `Task` is enqueued (not inside the Task body — `Task { ... }` only schedules, and a rapid second click slips between the schedule and the body running). `.disabled(appState.isLaunching || !dirExists)` on both buttons backs this up visually. The guard, the disabled modifier, AND the synchronous flip-before-Task must all be present for correctness.

## Duplicate-instance warning

**Behavior.** If the user manually opens VS Code (Finder, Dock) during the microsecond window between our "is anything still alive?" re-check and the `openApplication` call, both instances end up alive. ClaudeSwitcher detects this immediately after launch and shows an alert: *"Two VS Code instances are running. … The instance ClaudeSwitcher just launched (PID N) is the one configured for the requested Claude account."*

**Mechanism.** After `openApplication` returns, re-check `runningApplications` filtered by `bundleIdentifier == "com.microsoft.VSCode" && !isTerminated`. The `!isTerminated` filter excludes the just-terminated old VS Code (whose `runningApplications` entry can briefly persist). If count > 1, show the warning naming the freshly-launched PID. The race is astronomically rare in practice; the warning makes the corruption risk loud and recoverable instead of silent.

## Quit

**Behavior.** "Quit" button in the popover quits ClaudeSwitcher. Does not quit VS Code.

**Mechanism.** `NSApplication.shared.terminate(nil)`. Session-only state is lost on next launch — the first launch each session always falls through to the full quit-and-relaunch check.

## What's intentionally NOT a feature

Listed in [`claude-switcher-prompt.md`](../claude-switcher-prompt.md) under "What NOT to Build":

- No symlink swapping of `~/.claude`
- No `code` CLI invocation
- No "active account" global state
- No support for VS Code Insiders / Cursor / VSCodium (different bundle IDs)
- No preferences window, no auto-update
- No npm install path in the setup screen — curl install one-liner only
- Zero third-party Swift packages
