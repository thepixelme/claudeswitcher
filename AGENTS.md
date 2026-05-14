# AGENTS.md

Notes for AI coding agents working on this repository. Read this before changing code.

## Read this first

The [docs/](docs/) directory contains the architectural rationale. Skim it before making non-trivial changes — this codebase has a high concentration of patterns that look removable but encode load-bearing invariants. **Most "simplifications" here are silent regressions.**

Recommended reading order for an agent picking up a task:

1. [docs/architecture.md](docs/architecture.md) — the central traps (silent IPC, PID-reuse, env-on-running-process)
2. [docs/code.md](docs/code.md) — file-by-file with line references
3. [docs/verification.md](docs/verification.md) — what "working" means

For deeper rationale on any design choice, the historical 1122-line build prompt at [claude-switcher-prompt.md](claude-switcher-prompt.md) is authoritative.

**When you ship a feature, update the docs in the same change** so they keep matching reality. 

## Project facts

- **Stack.** macOS SwiftUI menu-bar app. Deployment target: **macOS 26 (Tahoe) or later**. Built in Xcode. No SwiftPM, no third-party Swift packages, no CocoaPods.
- **Tests.** None. No CI. Verification is the 16 manual scenarios in [docs/verification.md](docs/verification.md). **The cross-cutting check is `echo $CLAUDE_CONFIG_DIR` inside every launched VS Code.** If you can't run that check, you can't verify the change.
- **Git.** Local repo at the project root. There is no remote at the time of writing.
- **Out of scope.** VS Code Insiders / Cursor / VSCodium (different bundle IDs). The `npm install -g @anthropic-ai/claude-code` route — the setup screen shows the curl one-liner only. Preferences window. Auto-update. App Sandbox. Mac App Store distribution.
- **Spec deviation.** One: `VSCodeLaunchError.quitRequestFailed` was added to handle `NSRunningApplication.terminate()` returning `false` (typically TCC-denied Apple Events). The original spec ignored the Bool return. Everything else in [claude-switcher-prompt.md](claude-switcher-prompt.md) is authoritative.

## Load-bearing patterns — do not "simplify"

Each of these has a *why* in [docs/code.md](docs/code.md). The short version:

- **Never replace `NSWorkspace.openApplication(at:configuration:)` with the `code` CLI.** The CLI silently drops `CLAUDE_CONFIG_DIR` when handing off to a running VS Code. This is the bug the entire launcher exists to prevent. See [docs/architecture.md → The central trap](docs/architecture.md#the-central-trap).
- **The PID-gated fast path matches on BOTH account AND PID.** Don't reduce to account-only — that reintroduces the silent-IPC bug for the Cmd-Q-and-reopen-from-Dock case.
- **Filter `runningApplications` by bundle ID BEFORE matching on PID.** Kernel PIDs can be reused. The bundle-ID filter is what makes the PID check safe. Don't reorder.
- **`Published(initialValue:)` backing-storage assignments in `AppState.init()` are intentional.** Don't replace with `self.lastLaunched = ...` — at minimum it writes the loaded value back to UserDefaults; on some compiler versions it overwrites the loaded value with the fallback before the load is read.
- **`personalConfigDirExists` / `workConfigDirExists` are seeded from disk in `init()`.** Don't default them to `false` and rely on `.onAppear` — the `MenuBarExtra` label binds to `menuBarIconName` *before* any view's `.onAppear` fires, which would flash the warning triangle on every fresh launch.
- **The `MenuBarLabel` wrapper view in [ClaudeSwitcher/ClaudeSwitcherApp.swift](ClaudeSwitcher/ClaudeSwitcherApp.swift) is intentional.** Don't inline `Image(systemName: state.menuBarIconName)` directly in the `MenuBarExtra` label closure — `MenuBarExtra`'s `NSImage` conversion path doesn't reliably re-render on `@Published` changes without the wrapper.
- **`isLaunching = true` must be flipped SYNCHRONOUSLY BEFORE `Task { ... }`** (not inside the Task body). `Task { ... }` only *enqueues* — a rapid second click slips between the `Task` returning and its body running. `.disabled(isLaunching)` doesn't save you because SwiftUI's disabled propagation is driven by the same `@Published` flip.
- **`ShellEnvironment.shared.prewarm()` runs in `App.init()`, not lazily.** Moving it to the launcher's first-call path defers the 3-second shell spawn to exactly the moment it matters most.
- **`ShellEnvironment`'s lock guards Task *creation*, not the spawn.** Never hold the lock across the `await` or the shell process. A slow rc file would freeze the UI for 3 seconds.
- **In duplicate-instance detection, `!$0.isTerminated` matters.** `runningApplications` can briefly include a just-terminated process whose entry hasn't been pruned. Without the filter, the old VS Code is counted alongside the new one and triggers a spurious duplicate alert.
- **Setup's same-canonical-path check uses `resolvingSymlinksInPath().standardizedFileURL`.** Don't reduce to string equality — that lets the symlink misconfiguration through silently, and both launch buttons end up injecting the same `CLAUDE_CONFIG_DIR`.
- **`ClaudeAccount.configDirExists` checks `isDirectory`, not just existence.** A stray regular file would pass a bare `fileExists(atPath:)` check.
- **`createsNewApplicationInstance = true` defends against a Finder-spawned race.** Removing it reintroduces the silent-IPC bug.

## Quirks worth knowing

- **Ad-hoc rebuilds re-prompt for TCC.** The macOS Automation grant is keyed on the binary's code-signature hash. Every ad-hoc rebuild produces a fresh hash, so macOS treats it as a different app. Not a bug; goes away with Developer ID signing.
- **Config-dir validation is shallow.** An empty `~/.claude-personal` directory passes the check. A logged-out account surfaces its problem only when the user tries to use Claude inside VS Code. Documented as a known limitation.
- **The app needs `NSAppleEventsUsageDescription`.** Required because `NSRunningApplication.terminate()` sends an Apple Event to ask VS Code to quit. The string must be set via `INFOPLIST_KEY_NSAppleEventsUsageDescription` on the build target. See [README.md](README.md) for the exact value. (The setup-screen Log In buttons do **not** use Apple Events — they hand a `.command` file to Launch Services. An earlier iteration used `NSAppleScript`, but the resulting Automation TCC prompt never surfaced for this `LSUIElement` app, leaving users with an invisible failure. Don't reintroduce AppleScript here.)
- **App Sandbox is disabled.** This app needs to launch other apps with custom env vars and enumerate running apps via `NSWorkspace`. Sandboxing is more trouble than it's worth here. The trade-off precludes Mac App Store distribution.

## When in doubt

[claude-switcher-prompt.md](claude-switcher-prompt.md) — the original design spec — is the deepest source of "why." [docs/](docs/) is the conventional reference. Read the spec when the docs feel thin.
