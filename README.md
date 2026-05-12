# ClaudeSwitcher

A lightweight macOS menu bar app that launches VS Code under one of two separate Claude Code accounts (personal / work) by injecting `CLAUDE_CONFIG_DIR` into the launched process. One click, no terminal.

## Requirements

- macOS 14 (Sonoma) or later
- Xcode 15 or later (to build)
- [Visual Studio Code](https://code.visualstudio.com) installed (stock build; VS Code Insiders / Cursor / VSCodium not supported in v1)
- [Claude Code CLI](https://claude.ai) — install with:
  ```
  curl -fsSL https://claude.ai/install.sh | bash
  ```

## Build & run

1. Open `ClaudeSwitcher.xcodeproj` in Xcode.
2. Select the `ClaudeSwitcher` scheme and press ⌘R.

The app appears in the menu bar (no Dock icon).

### Build settings (set on the app target)

- `PRODUCT_BUNDLE_IDENTIFIER = com.thepixelme.ClaudeSwitcher`
- `MACOSX_DEPLOYMENT_TARGET = 14.0`
- `INFOPLIST_KEY_LSUIElement = YES`
- `INFOPLIST_KEY_NSAppleEventsUsageDescription = "ClaudeSwitcher quits Visual Studio Code so it can be relaunched under a different Claude account."`
- `INFOPLIST_KEY_NSPrincipalClass = NSApplication`
- App Sandbox: **disabled**
- Code signing: ad-hoc (`Sign to Run Locally`) for personal use; switch to a Developer ID certificate to ship.

## Initial setup (one time per account)

Open the menu bar popover. The first-run screen offers a **Log In — Personal** and a **Log In — Work** button. Each one writes a tiny `.command` script and hands it to Launch Services, which opens a new Terminal window running:

```
CLAUDE_CONFIG_DIR=~/.claude-personal claude
CLAUDE_CONFIG_DIR=~/.claude-work     claude
```

Complete the browser OAuth flow for each, then exit the REPL. The commands stay visible above the buttons as a copy-paste fallback for users on iTerm, Ghostty, or any non-Terminal workflow. (If you've changed the default app for `.command` files, the Log In buttons will respect that — Launch Services routes the document to whichever terminal you've registered.)

The setup screen polls every 2 s for the two `~/.claude-*` directories and advances to the main menu automatically once both exist. No "I've logged in" click required. The two directories must be present and distinct (not the same path via symlink) before the main UI activates — if they collide, the setup screen surfaces an inline error and refuses to advance.

## Day-to-day usage

Click the menu bar icon and pick one of:

- **Open VS Code — Personal**
- **Open VS Code — Work**

If VS Code is already running under a different account, ClaudeSwitcher shows a "Quit & Relaunch" confirmation and relaunches it with the right environment. Same-account clicks within one ClaudeSwitcher session **do not** trigger the quit prompt — they just bring the existing window forward.

The menu bar icon reflects the **last-launched** account (`person.circle` for Personal, `building.2.crop.circle` for Work). If either config dir is missing, the icon swaps to `exclamationmark.triangle.fill` and the popover re-enters the setup flow.

## One-time macOS permission prompt

The first time you switch accounts, macOS shows:

> "ClaudeSwitcher" would like to control "Visual Studio Code"

Approve it. ClaudeSwitcher uses `NSRunningApplication.terminate()` to ask VS Code to quit, which sends an Apple Event — that's the permission being requested. **Not malware.** This grant lives under *System Settings → Privacy & Security → Automation* if you ever need to revoke it.

If you deny the prompt, the launcher reports `quitRequestFailed` with instructions for re-enabling. You won't be stuck.

(The Log In buttons on the setup screen do **not** need this permission — they open `.command` files via Launch Services rather than scripting Terminal, so no Automation TCC class applies.)

## Known quirks

### Ad-hoc builds re-prompt for TCC on every rebuild

The macOS Automation (Apple Events) grant is keyed on the binary's code-signature hash. Every ad-hoc rebuild produces a fresh hash, so macOS treats it as a different app and re-asks. This goes away once the app is signed with a stable Developer ID certificate.

### Config-dir validation is shallow

ClaudeSwitcher only checks that `~/.claude-personal` and `~/.claude-work` exist *as directories*. An empty directory passes. A logged-out account surfaces its problem only when you actually try to use Claude inside VS Code.

### `claude` CLI on PATH inside VS Code

ClaudeSwitcher does **not** probe whether `claude` is on PATH at any point — that decision is intentional (see the build prompt §6). If the Claude Code extension inside VS Code complains that `claude` is missing, re-run the install command from the setup screen, then quit and relaunch VS Code via ClaudeSwitcher (so the new PATH is picked up).

### Hostile shell rc files

If `~/.zshrc` (or your `$SHELL`'s rc file) hangs — e.g. waits on stdin, hits a slow network probe — ClaudeSwitcher bounds the PATH lookup at 3 seconds and falls back to the launchd environment. VS Code will still launch, but its integrated terminal may not see Homebrew / nvm / asdf paths. Look for a `ShellEnvironment: ...` line in Console.app if you suspect this.

## What's NOT supported

- VS Code Insiders, Cursor, VSCodium (different bundle IDs)
- More than two accounts
- Switching accounts without quitting VS Code (not a limitation of this app — VS Code's environment is fixed at process start)
- Preferences window / auto-update / Mac App Store distribution
