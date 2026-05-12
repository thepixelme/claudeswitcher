# Verification

ClaudeSwitcher has **no automated tests**. Verification is a manual walkthrough of the 16 scenarios below. Run them on macOS 14+ before shipping any change that touches the launcher, state machine, or popover gate.

## The cross-cutting check

**For every scenario that ends with VS Code running, open VS Code's integrated terminal (`Terminal → New Terminal`) and run:**

```bash
echo $CLAUDE_CONFIG_DIR
```

The value must match the expanded path of the requested account (e.g. `/Users/<you>/.claude-personal`). If it is empty, mismatched, or stale, **the launcher is broken** — you have reproduced the silent-IPC bug warned about in [`architecture.md`](architecture.md#the-central-trap). Do not ship.

This is the single check that most matters. Any new change is suspect until this passes for both accounts across the cold and hot paths.

---

## Scenarios

### 1. Cold launch — Personal

**Setup.** VS Code not running.
**Action.** Click *Open VS Code — Personal*.
**Expected.** VS Code launches, comes forward, `CLAUDE_CONFIG_DIR` = `~/.claude-personal` (expanded).

### 2. Cold launch — Work

Same as #1 with Work.

### 3. Hot switch (different account)

**Setup.** VS Code already running under Personal (verified via the echo above).
**Action.** Click *Open VS Code — Work*.
**Expected.** Quit-confirmation alert appears in front. *Quit & Relaunch* terminates VS Code, then it relaunches. `CLAUDE_CONFIG_DIR` = `~/.claude-work`.

### 4. Hot same-account

**Setup.** VS Code already running under Personal **in this ClaudeSwitcher session**.
**Action.** Click *Open VS Code — Personal* again.
**Expected.** **No** quit prompt. VS Code simply comes forward. `CLAUDE_CONFIG_DIR` unchanged. This verifies the PID-gated fast path.

### 5. Same account, different session

**Setup.** VS Code launched under Personal, then ClaudeSwitcher quit and reopened.
**Action.** Click *Open VS Code — Personal*.
**Expected.** Quit prompt **does** appear (session-only fast-path state is gone). Accepting relaunches; cancelling leaves things untouched.

### 6. Cancel the quit prompt

**Setup.** Trigger any path that would prompt (scenarios 3 or 5).
**Action.** Click *Cancel*.
**Expected.** No VS Code restart, no error alert, popover remains usable, menu bar icon unchanged.

### 6a. Popover dismissal during confirm dialog

**Setup.** Trigger the quit-confirm prompt (scenario 3).
**Action.** While the alert is visible, click somewhere on screen *outside* the menu bar item — the popover dismisses.
**Expected.** The alert stays up, remains responsive, both buttons work. *Quit & Relaunch* continues the launch flow correctly; *Cancel* leaves the world untouched and `appState.isLaunching` returns to `false`. If the alert disappears with the popover or its buttons stop responding, the `confirmQuit` activation dance has regressed.

### 7. Quit-timeout / unsaved changes

**Setup.** Open a new untitled file in VS Code, type something, do not save.
**Action.** Click the other account's launch button and accept the quit prompt. VS Code shows its own "Save?" dialog. Leave it sitting.
**Expected.** After ~8 seconds, ClaudeSwitcher shows an error alert: *"VS Code did not quit — likely waiting for you to handle unsaved changes. Try again."* ClaudeSwitcher does **not** silently proceed to `openApplication`.

### 7a. TCC-denied terminate (new — covers spec deviation finding #2)

**Setup.** Revoke ClaudeSwitcher's Automation grant: *System Settings → Privacy & Security → Automation → ClaudeSwitcher → toggle off Visual Studio Code*. Make sure VS Code is running.
**Action.** Click the other account's launch button and accept the quit prompt.
**Expected.** Immediately (no 8-second wait), ClaudeSwitcher shows: *"ClaudeSwitcher could not ask VS Code to quit. macOS may have denied the Apple Events (Automation) permission…"* If you see the 8-second hang followed by "unsaved changes" message instead, the `terminate()` Bool-return handling has regressed.

### 8. TCC permission prompt (first ever switch)

**Setup.** Clean machine (or revoked Automation grant — but better to test on truly clean).
**Action.** Trigger the first quit-and-relaunch.
**Expected.** macOS shows *"ClaudeSwitcher would like to control 'Visual Studio Code'"*. Approve. Subsequent switches must not prompt again until the next ad-hoc rebuild.

### 9. Missing config dir (post-setup recovery)

**Setup.** Quit ClaudeSwitcher. `rm -rf ~/.claude-work`. Reopen ClaudeSwitcher.
**Expected.** Menu bar icon shows the warning symbol **immediately on launch, before opening the popover** (seeded `*ConfigDirExists` flags do this without an `onAppear` round-trip). Open the popover — `SetupView` takes over (Work missing). Re-create `~/.claude-work` via the displayed login command and click *Get Started*; expect to land back on `MainMenuView` with both buttons enabled and the icon back to the last-launched account symbol.

### 9a. Both dirs present — no false warning

**Setup.** Both `~/.claude-personal` and `~/.claude-work` in place.
**Action.** Quit and relaunch ClaudeSwitcher.
**Expected.** Menu bar icon shows the last-launched account's symbol immediately on launch — **never** the warning triangle, not even for a frame. Watch carefully; the buggy version flashes the warning until the user opens the popover.

### 10. First-run, both dirs missing

**Setup.** Quit ClaudeSwitcher. `defaults delete com.thepixelme.ClaudeSwitcher hasCompletedSetup`. `rm -rf ~/.claude-personal ~/.claude-work`. Reopen.
**Expected.** Setup screen. *Get Started* does **not** advance until both dirs exist. After creating them and clicking, normal UI appears.

### 11. First-run, both dirs already present

**Setup.** Same as #10 but leave both dirs in place.
**Expected.** Setup screen shows *"Both accounts detected."* *Get Started* advances on click.

### 11a. Same-directory / symlink misconfiguration

**Setup.** `rm -rf ~/.claude-work && ln -s ~/.claude-personal ~/.claude-work`. `defaults delete com.thepixelme.ClaudeSwitcher hasCompletedSetup`. Reopen.
**Expected.** Both `configDirExists` checks return true (symlink target exists and is a directory), but the canonical paths are identical. Click *Get Started* — setup refuses to advance with inline error: *"~/.claude-personal and ~/.claude-work resolve to the same directory…"* Remove the symlink and recreate `~/.claude-work` as a real directory; *Get Started* advances.

### 12. Login-shell PATH inheritance

**Setup.** Launch VS Code via ClaudeSwitcher (either account).
**Action.** Open the integrated terminal and run `echo $PATH`.
**Expected.** Includes Homebrew / nvm / asdf directories from `~/.zshrc`, not just `/usr/bin:/bin:/usr/sbin:/sbin`.

### 12a. Hostile rc file — login-shell timeout

**Setup.** Temporarily prepend to `~/.zshrc`: `read -r dummy < /dev/tty || true`.
**Action.** Quit ClaudeSwitcher, relaunch, click a launch button.
**Expected.** The app does **not** freeze. After up to 3 seconds it proceeds to launch VS Code with the launchd PATH (so `echo $PATH` inside VS Code's integrated terminal will lack Homebrew etc.). Console.app shows `ShellEnvironment: login shell timed out after 3s; using launchd PATH`. Remove the rc-file edit afterward. If the menu bar app freezes on click, the `Pipe()` for stdin/stderr or the `DispatchGroup.wait` timeout has regressed.

### 13. Setup screen renders fast

**Setup.** Cold start (ClaudeSwitcher not previously running). `defaults delete com.thepixelme.ClaudeSwitcher hasCompletedSetup`.
**Action.** Launch the app and click the menu bar icon immediately — before the background pre-warm of `ShellEnvironment` can plausibly have finished.
**Expected.** Setup screen appears with no perceptible delay. If you see a hang, the pre-warm is wired wrong; trace before shipping.

### 14. Menu bar label refreshes without re-opening popover

**Setup.** Trigger any successful launch (cold or hot switch).
**Expected.** Menu bar icon updates to the just-launched account's symbol immediately — **without** the user clicking the menu bar item to open and close the popover. If the icon only updates on next popover open, the `MenuBarLabel` wrapper view in [`ClaudeSwitcherApp.swift`](../ClaudeSwitcher/ClaudeSwitcherApp.swift) has been removed or its `@EnvironmentObject` binding broken.

---

## Useful resets

For repeatable testing, these commands reset specific state without uninstalling:

```bash
# Clear all UserDefaults state
defaults delete com.thepixelme.ClaudeSwitcher

# Clear just the setup flag
defaults delete com.thepixelme.ClaudeSwitcher hasCompletedSetup

# Clear just the last-launched account
defaults delete com.thepixelme.ClaudeSwitcher lastLaunchedAccount

# Wipe one account's config (forces re-login via `claude`)
rm -rf ~/.claude-work
```

For the TCC-grant scenario (7a, 8), the toggle lives at *System Settings → Privacy & Security → Automation → ClaudeSwitcher*.
