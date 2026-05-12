# Documentation

Reference docs for ClaudeSwitcher — a macOS menu-bar app that launches VS Code under one of two `CLAUDE_CONFIG_DIR` accounts. For day-to-day usage and installation, see the top-level [`../README.md`](../README.md). For agents working on this codebase, see [`../AGENTS.md`](../AGENTS.md).

## Contents

- **[architecture.md](architecture.md)** — Why the design looks the way it does. The silent-IPC trap, the "no active account" mental model, session-only vs persistent state, the PID-gated fast path, the login-shell PATH dance.
- **[code.md](code.md)** — File-by-file walkthrough of all five Swift sources with line-anchored references and "what not to simplify" notes.
- **[features.md](features.md)** — User-visible behaviors organized as feature → mechanism. The eight functional surfaces (launch, switch, fast path, setup, recovery, PATH inheritance, re-entrancy guard, duplicate-instance warning).
- **[verification.md](verification.md)** — The 16 manual test scenarios. **The cross-cutting check is the first thing here** — run `echo $CLAUDE_CONFIG_DIR` inside every launched VS Code.

## The original design spec

[`../claude-switcher-prompt.md`](../claude-switcher-prompt.md) is the historical 1122-line build prompt that the implementation was generated from. It contains the deepest "why" for every design decision, plus more edge-case reasoning than the docs above. Reach for it when the docs feel thin.

One deliberate deviation from the spec is captured in [code.md → VSCodeLaunchError](code.md#vscodelauncherror) and [verification.md scenario 7a](verification.md#7a-tcc-denied-terminate-new--covers-spec-deviation-finding-2): the `quitRequestFailed` error case, added because `NSRunningApplication.terminate()` can return `false` when macOS denies the Apple Event (typically TCC). Everything else in the spec is authoritative.
