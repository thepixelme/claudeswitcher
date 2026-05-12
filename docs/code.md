# Code reference

File-by-file walkthrough. Each file's section calls out the non-obvious patterns and explains why they exist. Line numbers are clickable links into the source.

For high-level "why does the design look like this," start with [`architecture.md`](architecture.md).

---

## [`ClaudeAccount.swift`](../ClaudeSwitcher/ClaudeAccount.swift)

The two-case enum that everything else hangs off. Exposes the config-dir path (both tilde-form for display and expanded form for env injection), the per-account SF Symbol used in the menu bar, and the existence check.

### Non-obvious bits

- **`configDirExists` checks `isDirectory`, not just existence** ([`ClaudeAccount.swift:33-40`](../ClaudeSwitcher/ClaudeAccount.swift#L33-L40)). A stray regular file at `~/.claude-personal` would pass a bare `fileExists(atPath:)` and let the misconfiguration through silently. The `isDirectory: &isDirectory` pattern catches that. Both the first-run gate (in `SetupView`) and per-launch validation (in `MenuBarView.onAppear`) call this — don't replace either site with `fileExists`.

---

## [`AppState.swift`](../ClaudeSwitcher/AppState.swift)

Single `@MainActor ObservableObject` carrying all UI state. Combines persistent (UserDefaults-backed) and session-only fields. See [`architecture.md`](architecture.md) for the lifetime table.

### Non-obvious bits

- **Persistent fields use `didSet` to write through to UserDefaults** ([`AppState.swift:12-17`](../ClaudeSwitcher/AppState.swift#L12-L17)). Any assignment to `lastLaunched` or `hasCompletedSetup` after init writes the new value to disk.

- **`init()` assigns to backing storage, not the properties** ([`AppState.swift:42-57`](../ClaudeSwitcher/AppState.swift#L42-L57)). The four `_foo = Published(initialValue: ...)` lines are deliberate. The Swift "didSet does not fire during init" rule applies cleanly to plain stored properties, but property-wrapped properties with `didSet` have had subtler behavior across compiler versions — going through `_foo` (the synthesized storage) is provably safe regardless. Don't "simplify" to `self.lastLaunched = ...` — at minimum it makes a redundant write of the loaded value back to UserDefaults; on some compiler versions it would overwrite the loaded value with the fallback (`.personal` / `false`) before the load is read.

- **`personalConfigDirExists` / `workConfigDirExists` are seeded from disk in `init()`** ([`AppState.swift:52-57`](../ClaudeSwitcher/AppState.swift#L52-L57)). The `MenuBarExtra` label binds to `menuBarIconName` *before* any view's `.onAppear` fires. If these defaulted to `false`, the label would resolve to the warning triangle for one frame on every fresh launch even when both dirs exist. The two `stat` calls during init prevent that flash. Refresh on every popover open via `refreshConfigDirExistence()` ([`AppState.swift:70-73`](../ClaudeSwitcher/AppState.swift#L70-L73)).

- **`menuBarIconName` is computed, not stored** ([`AppState.swift:62-67`](../ClaudeSwitcher/AppState.swift#L62-L67)). It folds the warning-triangle swap into one property so the menu bar label can bind to a single string and the swap happens automatically. The implementer of `ClaudeSwitcherApp` must bind to this — never inline `state.lastLaunched.menuBarIcon` in the label, which bypasses the swap.

- **`currentlyRunningAccount` and `launchedProcessIdentifier` are `@Published` but session-only** ([`AppState.swift:20-21`](../ClaudeSwitcher/AppState.swift#L20-L21)). They have no `didSet` writes to UserDefaults. The launcher sets them on every fresh launch; the fast path reads them. Persisting either would create stale state that doesn't match what VS Code is actually running.

---

## [`VSCodeLauncher.swift`](../ClaudeSwitcher/VSCodeLauncher.swift)

The trickiest file. Contains the `VSCodeLauncher` struct (top), the error enum + `LocalizedError` extension, and `ShellEnvironment` (bottom).

### `VSCodeLaunchError`

Five cases ([`VSCodeLauncher.swift:3-9`](../ClaudeSwitcher/VSCodeLauncher.swift#L3-L9)). `quitRequestFailed` is the one deliberate deviation from the original spec — added because `NSRunningApplication.terminate()` can return `false` when macOS denies the Apple Event (typically because the user denied the Automation TCC permission). Without this case, a TCC denial would fall into the 8-second `waitForExit` and surface as `quitTimedOut` with the misleading "unsaved changes" message.

Each case has a user-facing string via `LocalizedError.errorDescription` ([`VSCodeLauncher.swift:16-31`](../ClaudeSwitcher/VSCodeLauncher.swift#L16-L31)). `userCancelledQuit` returns `nil` on purpose: the catch-ordering in `MainMenuView.openVSCode` handles that case explicitly and shows no alert, but the `nil` here is defence-in-depth.

### `VSCodeLauncher.launch`

The main flow. Annotated path through it:

1. **Resolve the VS Code bundle** ([`vsCodeURL`](../ClaudeSwitcher/VSCodeLauncher.swift#L40-L46)). Tries LaunchServices first, falls back to `/Applications/Visual Studio Code.app`. Returns `nil` only if VS Code is genuinely not installed.

2. **Filter `runningApplications` by bundle ID FIRST** ([`VSCodeLauncher.swift:66-67`](../ClaudeSwitcher/VSCodeLauncher.swift#L66-L67)). Load-bearing for safety. The fast path matches on PID next, and kernel PIDs can be reused. Filtering by bundle ID first means a reused PID belonging to something that isn't VS Code is implicitly excluded. **Don't move this filter below the PID check during refactors.**

3. **Same-account fast path — PID-gated** ([`VSCodeLauncher.swift:76-81`](../ClaudeSwitcher/VSCodeLauncher.swift#L76-L81)). Skips the prompt only if both the account matches AND the exact PID we tracked is still alive. Tracking the account alone would skip the prompt for an externally-relaunched VS Code with no `CLAUDE_CONFIG_DIR`. See [`architecture.md`](architecture.md#the-pid-gated-same-account-fast-path).

4. **Quit-and-relaunch** ([`VSCodeLauncher.swift:83-114`](../ClaudeSwitcher/VSCodeLauncher.swift#L83-L114)). Shows the confirmation modal, then calls `terminate()` on every running VS Code instance. **Checks the Bool return of each `terminate()` call** ([`VSCodeLauncher.swift:94-100`](../ClaudeSwitcher/VSCodeLauncher.swift#L94-L100)) — if none succeed, throws `quitRequestFailed` immediately rather than waiting out the timeout. Then `waitForExit` polls for `isTerminated` for up to 8 seconds. After it returns, **re-checks the world** ([`VSCodeLauncher.swift:109-113`](../ClaudeSwitcher/VSCodeLauncher.swift#L109-L113)) — if anything matching the bundle ID is still alive, throws `quitTimedOut`. *Do NOT fall through to `openApplication` in that state* — it would attach to the surviving instance and silently drop the env override.

5. **Fresh launch with env injected** ([`VSCodeLauncher.swift:116-128`](../ClaudeSwitcher/VSCodeLauncher.swift#L116-L128)). Merges the login-shell PATH from `ShellEnvironment.shared.loginPath()`, sets `CLAUDE_CONFIG_DIR` to the account's expanded path, and crucially sets `config.createsNewApplicationInstance = true`. The last flag defends against the microsecond race where the user manually opens VS Code between our "still alive?" re-check and this call — without it, `openApplication` would attach to that user-spawned instance and silently drop `config.environment`.

6. **Post-launch duplicate-instance detection** ([`VSCodeLauncher.swift:149-155`](../ClaudeSwitcher/VSCodeLauncher.swift#L149-L155)). If we observe more than one VS Code alive after the launch returns, surface a user-visible warning naming the PID we just launched. **The `!$0.isTerminated` filter is load-bearing** — `runningApplications` can briefly include a just-terminated process whose entry hasn't been pruned, and without the filter the old VS Code would be counted alongside the new one and trigger a spurious alert.

### `confirmQuit` and `warnDuplicateInstance`

Both modals start with `NSApp.activate()` ([`VSCodeLauncher.swift:167`](../ClaudeSwitcher/VSCodeLauncher.swift#L167), [`VSCodeLauncher.swift:188`](../ClaudeSwitcher/VSCodeLauncher.swift#L188)). Menu-bar-only apps have no key window, so without this the alerts can end up hidden behind the user's other windows. Cooperative activation works here because for a menu-bar app the user just clicked, the frontmost-yields case is the normal one.

### `ShellEnvironment`

Resolves the user's login-shell PATH once and caches the result. Singleton via `static let shared` ([`VSCodeLauncher.swift:232`](../ClaudeSwitcher/VSCodeLauncher.swift#L232)).

**Concurrency model** ([`VSCodeLauncher.swift:250-258`](../ClaudeSwitcher/VSCodeLauncher.swift#L250-L258)): the shell spawn runs inside a single `Task.detached` shared by all callers. The `NSLock` only guards creation of that `Task` — it is **never** held across the spawn. So even if `loginPath()` arrives before `prewarm()` has resolved, the caller suspends via `await ensureTask().value` rather than blocking on a lock. This matters because `loginPath()` is called from the main actor in `VSCodeLauncher.launch`: a lock held across a 3-second shell spawn would freeze the UI.

**The shell spawn itself** ([`VSCodeLauncher.swift:266-324`](../ClaudeSwitcher/VSCodeLauncher.swift#L266-L324)):

- `-ilc` for interactive + login + run-command, so `~/.zshrc` and login-only files both source.
- **Sentinel-marker `$PATH` extraction** ([`VSCodeLauncher.swift:279-280`](../ClaudeSwitcher/VSCodeLauncher.swift#L279-L280), [`VSCodeLauncher.swift:317-323`](../ClaudeSwitcher/VSCodeLauncher.swift#L317-L323)). Rc-file banners contaminate plain `echo $PATH`; wrapping the printf in `__CLAUDESWITCHER_PATH__` markers and slicing between them isolates the real value.
- **stdin = `/dev/null`, stderr = `/dev/null`** ([`VSCodeLauncher.swift:287`](../ClaudeSwitcher/VSCodeLauncher.swift#L287), [`VSCodeLauncher.swift:290`](../ClaudeSwitcher/VSCodeLauncher.swift#L290)). Interactive shells can attempt to `read` from stdin (fzf init, version managers) which deadlocks the wait. An unread stderr `Pipe()` can fill its buffer and block the child. Nulling both avoids both failure modes.
- **3-second hard timeout** via `DispatchGroup` ([`VSCodeLauncher.swift:299-310`](../ClaudeSwitcher/VSCodeLauncher.swift#L299-L310)). On timeout, send SIGTERM and return `[:]`. The launch proceeds with the launchd PATH — VS Code's integrated terminal won't see Homebrew, but the app doesn't freeze.

---

## [`MenuBarView.swift`](../ClaudeSwitcher/MenuBarView.swift)

Three view structs: `MenuBarView` (popover root), `MainMenuView` (the two launch buttons), `SetupView` (first-run / recovery flow).

### `MenuBarView`

Popover gate ([`MenuBarView.swift:12-18`](../ClaudeSwitcher/MenuBarView.swift#L12-L18)). Shows `MainMenuView` only if **all three** are true: `hasCompletedSetup`, `personalConfigDirExists`, `workConfigDirExists`. Any missing dir re-enters `SetupView` — this is what makes post-setup recovery work (delete `~/.claude-work`, app immediately offers the setup flow again instead of stranding the user with a disabled button).

`.onAppear { appState.refreshConfigDirExistence() }` ([`MenuBarView.swift:20`](../ClaudeSwitcher/MenuBarView.swift#L20)) re-stats both dirs on every popover open. `.onAppear` can fire more than once per open depending on view recreation; the check is two `stat` calls so re-running it is harmless. Don't wire this to a timer or `NSApplication.didActivateNotification` — popover-open is the only moment it matters.

### `MainMenuView.openVSCode`

The launch-button action ([`MenuBarView.swift:64-91`](../ClaudeSwitcher/MenuBarView.swift#L64-L91)). Three details that are easy to get wrong:

- **Re-entrancy guard flipped synchronously, BEFORE `Task { }`** ([`MenuBarView.swift:75-78`](../ClaudeSwitcher/MenuBarView.swift#L75-L78)). `Task { ... }` *enqueues* the body; it doesn't run it inline. A rapid second click can slip in between the `Task` returning and its body running, both clicks see `isLaunching == false`, and both proceed. The `.disabled(isLaunching)` modifier doesn't save us because SwiftUI's disabled propagation is driven by the same `@Published` flip. The synchronous flip *before* `Task` is what actually closes the window. If a regression ever combines the second launch's `terminate()` with the first launch's just-spawned VS Code, it will kill the freshly-correctly-configured process.

- **`lastLaunched` set AFTER `await launch(...)` returns** ([`MenuBarView.swift:81-84`](../ClaudeSwitcher/MenuBarView.swift#L81-L84)). Setting it optimistically before the await would leave the icon pointing at an account whose launch then failed.

- **`userCancelledQuit` caught explicitly with no alert** ([`MenuBarView.swift:85-86`](../ClaudeSwitcher/MenuBarView.swift#L85-L86)). Popping an error dialog for "you clicked Cancel" is silly. All other errors go through `presentLaunchError` which uses `error.localizedDescription` (the per-case `LocalizedError` strings) — no per-case branching needed at the call site.

### `SetupView`

Three-way detection: both dirs present → short "Both accounts detected" status; one present → instructions + hint about which side is done; neither → full instructions. Per-account **Log In — …** buttons sit beside each copyable command; the already-detected account's button is disabled and re-labeled "Logged in — …".

**Log In buttons launch a `.command` file** (`openLoginInTerminal`). Each button writes `CLAUDE_CONFIG_DIR=<account.configDir> claude` (wrapped in a `#!/bin/zsh` shebang) to `FileManager.default.temporaryDirectory/claudeswitcher-login-<account>.command`, sets `0o755`, and calls `NSWorkspace.shared.open(_:)`. Launch Services hands the document to the registered `.command` handler (Terminal.app out of the box; iTerm/Ghostty if remapped). **Don't "simplify" back to `NSAppleScript`.** A previous implementation drove Terminal via `tell application "Terminal" / do script` and hit `errAEEventNotPermitted` with no consent dialog ever appearing — for `LSUIElement` apps the Automation TCC prompt does not reliably surface, leaving users with an invisible, unrecoverable failure. `.command` files are document-open, not Apple Events, so the Automation TCC class doesn't apply. The login shell that Terminal spawns to run the script still inherits the user's PATH (Homebrew/nvm/asdf), so `claude` resolves normally.

**Auto-advance via `tryAutoAdvance()`** (private function). Refreshes `*ConfigDirExists` flags, returns early if either dir is missing, runs the same-canonical-path check, and only then flips `hasCompletedSetup = true`. Two signals fire it:

- `.onAppear { tryAutoAdvance() }` — cold-open path. If both dirs already exist when the popover opens, the screen advances to `MainMenuView` immediately. Without this, the user would briefly see "Both accounts detected." for up to 2 s before the first timer tick.
- `.onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect())` — popover-stays-open path. Covers the user who keeps the popover visible while finishing the second `claude` login in Terminal.

The redundant "I've logged in — Get Started" button has been removed. The `*ConfigDirExists` flags on `AppState` are still re-stat'd by every `tryAutoAdvance` call — same staleness concern as before, just answered by polling instead of by a click.

**Same-canonical-path check.** If both expanded paths resolve to the same canonical location — user symlinked them, or pointed both at the same dir — the app's whole premise is silently broken: both launch buttons would inject identical `CLAUDE_CONFIG_DIR`. `resolvingSymlinksInPath().standardizedFileURL` catches the symlink case and normalizes `./..` / trailing slashes. **Don't reduce this to string equality** — that would let the symlink case pass. On collision, `tryAutoAdvance` sets `validationError` and refuses to advance.

---

## [`ClaudeSwitcherApp.swift`](../ClaudeSwitcher/ClaudeSwitcherApp.swift)

The smallest file. Two important things:

- **`ShellEnvironment.shared.prewarm()` is called from `App.init()`** ([`ClaudeSwitcherApp.swift:12-14`](../ClaudeSwitcher/ClaudeSwitcherApp.swift#L12-L14)), not lazily from the launcher. The whole point is that the shell spawn is already in flight by the time the user clicks a launch button. Wiring this into the launcher's first-call path defers the cost to exactly the moment it matters most — defeating pre-warming entirely.

- **The `MenuBarExtra` label is wrapped in a private `MenuBarLabel` view** ([`ClaudeSwitcherApp.swift:19-26`](../ClaudeSwitcher/ClaudeSwitcherApp.swift#L19-L26), [`ClaudeSwitcherApp.swift:31-36`](../ClaudeSwitcher/ClaudeSwitcherApp.swift#L31-L36)). `MenuBarExtra`'s label closure runs through an `NSImage` conversion path that's finicky with `@Published` change propagation when state is read directly in the closure. Routing through a child `View` that explicitly observes `AppState` via `@EnvironmentObject` makes the label re-render reliably. **Don't "simplify" by inlining `Image(systemName: state.menuBarIconName)` into the label closure** — verification scenario 14 will fail (the icon would only update on next popover open).
