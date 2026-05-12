import AppKit

enum VSCodeLaunchError: Error {
    case vsCodeNotInstalled
    case userCancelledQuit
    case quitRequestFailed
    case quitTimedOut
    case launchFailed(underlying: Error)
}

// errorDescription is what error.localizedDescription returns, so the
// catch-all in §4's presentLaunchError produces a useful message instead
// of "The operation couldn't be completed. (VSCodeLaunchError error N.)".
// Returning nil for userCancelledQuit is intentional: §4 catches that
// case explicitly and shows nothing.
extension VSCodeLaunchError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .vsCodeNotInstalled:
            return "Visual Studio Code is not installed. Install it from https://code.visualstudio.com and try again."
        case .userCancelledQuit:
            return nil
        case .quitRequestFailed:
            return "ClaudeSwitcher could not ask VS Code to quit. macOS may have denied the Apple Events (Automation) permission — check System Settings → Privacy & Security → Automation, allow ClaudeSwitcher to control Visual Studio Code, and try again."
        case .quitTimedOut:
            return "VS Code did not quit — likely waiting for you to handle unsaved changes. Try again."
        case .launchFailed(let underlying):
            return "VS Code failed to launch: \(underlying.localizedDescription)"
        }
    }
}

struct VSCodeLauncher {
    static let vsCodeBundleID = "com.microsoft.VSCode"

    /// Resolves the installed VS Code via LaunchServices, falling back to
    /// the standard `/Applications` location if LaunchServices has no
    /// record for the bundle ID. Returns nil only if VS Code is genuinely
    /// not installed.
    static func vsCodeURL() -> URL? {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: vsCodeBundleID) {
            return url
        }
        let fallback = URL(fileURLWithPath: "/Applications/Visual Studio Code.app")
        return FileManager.default.fileExists(atPath: fallback.path) ? fallback : nil
    }

    /// Called by MenuBarView. `appState` carries the session-only
    /// currentlyRunningAccount and launchedProcessIdentifier fields.
    /// @MainActor because we mutate @Published state on AppState and
    /// present an NSAlert.
    @MainActor
    static func launch(
        with account: ClaudeAccount,
        appState: AppState
    ) async throws {
        guard let vsCodeURL = vsCodeURL() else {
            throw VSCodeLaunchError.vsCodeNotInstalled
        }

        // Filter by bundle ID FIRST. Load-bearing for safety: the fast path
        // below matches on PID, and the kernel can reuse a dead PID for an
        // unrelated process. Filtering by bundle ID first means a reused
        // PID belonging to something that isn't VS Code is implicitly
        // excluded. Do not move this filter below the PID check.
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.bundleIdentifier == vsCodeBundleID }

        // 0. Same-account fast path — PID-gated.
        //    Fires only if (a) the requested account matches what we last
        //    launched, AND (b) the *exact* PID we tracked is still alive.
        //    If the user Cmd-Q'd VS Code and reopened it from the Dock,
        //    launchedProcessIdentifier won't match any running PID — we
        //    fall through to the prompt path, because that externally
        //    spawned process has no CLAUDE_CONFIG_DIR.
        if appState.currentlyRunningAccount == account,
           let launchedPID = appState.launchedProcessIdentifier,
           let ours = running.first(where: { $0.processIdentifier == launchedPID }) {
            ours.activate()
            return
        }

        // 1. If VS Code is running (different account, externally launched,
        //    or our tracked PID is gone), prompt for quit-and-relaunch.
        if !running.isEmpty {
            let confirmed = await Self.confirmQuit(for: account)
            guard confirmed else { throw VSCodeLaunchError.userCancelledQuit }

            // terminate() returns false if macOS rejected the Apple Event
            // (most likely cause: TCC Automation permission denied). Fail
            // fast with a specific error rather than waiting 8s for an
            // empty timeout — `quitTimedOut`'s "unsaved changes" message
            // would be misleading in the TCC-denial case.
            var anyRequestSent = false
            for app in running {
                if app.terminate() { anyRequestSent = true }
            }
            if !anyRequestSent {
                throw VSCodeLaunchError.quitRequestFailed
            }

            try await Self.waitForExit(running, timeoutSeconds: 8)

            // Re-check the world. If anything matching the bundle ID is
            // still alive, VS Code is most likely blocked on an unsaved-
            // changes dialog. Do NOT fall through — openApplication would
            // attach to the surviving instance and the env override would
            // be silently ignored.
            let stillAlive = NSWorkspace.shared.runningApplications
                .contains { $0.bundleIdentifier == vsCodeBundleID }
            if stillAlive {
                throw VSCodeLaunchError.quitTimedOut
            }
        }

        // 2. Fresh launch with env var injected.
        let config = NSWorkspace.OpenConfiguration()
        var env = ProcessInfo.processInfo.environment
        env.merge(await ShellEnvironment.shared.loginPath()) { _, new in new }
        env["CLAUDE_CONFIG_DIR"] = account.expandedConfigDir
        config.environment = env
        config.activates = true
        // Defensive: force a fresh process even if something has spawned
        // a VS Code instance between our stillAlive re-check above and
        // this call (e.g. user double-clicked VS Code in Finder during
        // the race window). Without this, openApplication would attach
        // to that surviving instance and silently drop config.environment.
        config.createsNewApplicationInstance = true

        do {
            let launched = try await NSWorkspace.shared.openApplication(
                at: vsCodeURL,
                configuration: config
            )
            appState.currentlyRunningAccount = account
            appState.launchedProcessIdentifier = launched.processIdentifier

            // Defensive: detect the createsNewApplicationInstance race where
            // the user manually opened VS Code (e.g. from Finder or the Dock)
            // in the microsecond window between our stillAlive re-check
            // above and this call. If we see >1 VS Code alive, surface it
            // loudly — running two instances corrupts VS Code's workspace
            // state files in ~/Library/Application Support/Code.
            // !$0.isTerminated matters: runningApplications can briefly
            // include a process whose isTerminated is already true (the
            // entry has not yet been pruned). Without this filter the
            // just-terminated old VS Code can be counted alongside the
            // freshly launched one and trigger a spurious duplicate alert.
            let alive = NSWorkspace.shared.runningApplications
                .filter { $0.bundleIdentifier == vsCodeBundleID && !$0.isTerminated }
            if alive.count > 1 {
                await Self.warnDuplicateInstance(
                    launchedPID: launched.processIdentifier
                )
            }
        } catch {
            throw VSCodeLaunchError.launchFailed(underlying: error)
        }
    }

    @MainActor
    private static func confirmQuit(for account: ClaudeAccount) async -> Bool {
        // Bring ClaudeSwitcher forward so the alert is owned by an active
        // app and cannot end up hidden behind other windows. The menu bar
        // popover has no key window, so without this the alert can float
        // detached.
        NSApp.activate()

        let alert = NSAlert()
        alert.messageText = "Quit VS Code to switch accounts?"
        alert.informativeText = """
            VS Code is already running. To launch it under the \
            \(account.displayName) Claude account, it must be quit and relaunched. \
            Any unsaved changes will be prompted to save by VS Code itself.
            """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Quit & Relaunch")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    // Surfaced when post-launch we observe more than one VS Code process
    // alive — the createsNewApplicationInstance race. We name the PID we
    // just launched so the user can quit the *other* one and not the
    // freshly-correctly-configured one.
    @MainActor
    private static func warnDuplicateInstance(launchedPID: pid_t) async {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Two VS Code instances are running."
        alert.informativeText = """
            Another VS Code process started during the relaunch. Running two \
            instances can corrupt VS Code's workspace state. Quit the other \
            instance from the Dock to recover; the instance ClaudeSwitcher \
            just launched (PID \(launchedPID)) is the one configured for the \
            requested Claude account.
            """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        _ = alert.runModal()
    }

    // Polls runningApplications until the given PIDs are gone or timeout.
    // The caller re-checks runningApplications after this returns — do not
    // assume success just because waitForExit did not throw.
    private static func waitForExit(
        _ apps: [NSRunningApplication],
        timeoutSeconds: Double
    ) async throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if apps.allSatisfy({ $0.isTerminated }) { return }
            try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }
    }
}

/// Resolves the user's login-shell PATH once and caches the result.
/// Without this, VS Code launched from a menu bar app inherits the
/// launchd env, which often lacks Homebrew / nvm / asdf PATH entries
/// that Claude Code or its tools need.
///
/// Only PATH is captured. If you later need LANG, HOMEBREW_PREFIX, etc.,
/// extend the shell command and parse them out.
///
/// Concurrency model: the shell spawn runs inside a single Task shared
/// by all callers. The lock here only guards creation of that Task; it
/// is **never** held across the spawn. So even if the launcher calls
/// loginPath() before the pre-warm finishes, the main thread suspends
/// (via await) rather than blocking on a lock.
final class ShellEnvironment {
    static let shared = ShellEnvironment()
    private let lock = NSLock()
    private var resolveTask: Task<[String: String], Never>?

    /// Kick off resolution without awaiting it. Call this from
    /// ClaudeSwitcherApp.init() so the shell spawn is already in flight
    /// by the time the user clicks a launch button. Idempotent.
    func prewarm() {
        _ = ensureTask()
    }

    /// Returns the resolved PATH dict. If prewarm() was called earlier,
    /// this awaits the same Task. If not, it starts one. Concurrent
    /// callers always share a single shell spawn.
    func loginPath() async -> [String: String] {
        await ensureTask().value
    }

    private func ensureTask() -> Task<[String: String], Never> {
        lock.lock(); defer { lock.unlock() }
        if let resolveTask { return resolveTask }
        let task = Task.detached(priority: .userInitiated) {
            Self.resolve()
        }
        resolveTask = task
        return task
    }

    /// Spawns the login shell with a 3-second hard timeout. A misconfigured
    /// rc file (slow nvm init, asdf hooks reading stdin, prompts hung on a
    /// remote check) must not freeze the menu bar app. On timeout or any
    /// error, return an empty dict and proceed without a PATH override —
    /// the launch still works, the user just may not see Homebrew on PATH
    /// inside VS Code. Fail loud (NSLog), not silent.
    private static func resolve() -> [String: String] {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        // -i (interactive) so rc files like ~/.zshrc are sourced;
        // -l (login) so login-only files are sourced too;
        // -c runs the command and exits.
        //
        // Wrap $PATH in sentinel markers and extract between them. Rc
        // files routinely print things during init (oh-my-zsh banners, nvm
        // / asdf progress) which would otherwise contaminate the captured
        // PATH — a plain `echo $PATH` followed by a whitespace trim is
        // not enough.
        let marker = "__CLAUDESWITCHER_PATH__"
        process.arguments = ["-ilc", "printf '\(marker)%s\(marker)' \"$PATH\""]

        let outPipe = Pipe()
        process.standardOutput = outPipe
        // stdin must be /dev/null — an interactive shell may attempt to
        // read from stdin during rc-file execution (fzf init, anything
        // that pipes through `read`), which would deadlock the wait.
        process.standardInput = FileHandle.nullDevice
        // Discard stderr. Leaving an unread Pipe() here risks a full
        // pipe buffer blocking the child before it exits.
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            NSLog("ShellEnvironment: could not launch shell (\(error)); using launchd PATH")
            return [:]
        }

        // Hard timeout via a background wait + DispatchGroup.
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            process.waitUntilExit()
            group.leave()
        }
        if group.wait(timeout: .now() + .seconds(3)) == .timedOut {
            process.terminate()
            NSLog("ShellEnvironment: login shell timed out after 3s; using launchd PATH")
            return [:]
        }

        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        let raw = String(data: data, encoding: .utf8) ?? ""
        // Extract the PATH value between the two sentinel markers. Anything
        // outside the markers — banners, prompts, version-manager noise —
        // is ignored.
        let parts = raw.components(separatedBy: marker)
        guard parts.count >= 3 else {
            NSLog("ShellEnvironment: marker not found in shell output; using launchd PATH")
            return [:]
        }
        let path = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? [:] : ["PATH": path]
    }
}
