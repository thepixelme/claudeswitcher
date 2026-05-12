import AppKit
import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Group {
            // §6: SetupView covers both first-run AND post-deletion recovery.
            // A missing dir after initial setup re-enters the setup flow
            // rather than leaving the user staring at a disabled launch button.
            if appState.hasCompletedSetup
                && appState.personalConfigDirExists
                && appState.workConfigDirExists {
                MainMenuView()
            } else {
                SetupView()
            }
        }
        .onAppear { appState.refreshConfigDirExistence() }
        .frame(width: 260)
    }
}

struct MainMenuView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ClaudeSwitcher").font(.headline)
            Divider()
            ForEach(ClaudeAccount.allCases) { account in
                let dirExists = (account == .personal)
                    ? appState.personalConfigDirExists
                    : appState.workConfigDirExists

                Button {
                    openVSCode(as: account)
                } label: {
                    Label(
                        "Open VS Code — \(account.displayName)",
                        systemImage: account.menuBarIcon
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                // §4 contract: re-entrancy guard AND missing-dir gating.
                .disabled(appState.isLaunching || !dirExists)

                if !dirExists {
                    // §7 safety-net branch — SetupView normally takes over
                    // the popover when a dir is missing, but render this
                    // anyway so a user briefly on this view knows what's wrong.
                    Text("\(account.configDir) not found. Re-run setup.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .padding(12)
    }

    @MainActor
    private func openVSCode(as account: ClaudeAccount) {
        // Re-entrancy guard. Flow has multiple suspension points; a
        // second click while a launch is in-flight would race the first.
        // The flag MUST be flipped synchronously here — not inside the
        // Task body — because Task { ... } only enqueues the body, and
        // a rapid second click slips in between the two and re-enters
        // the launch flow before the body has had a chance to flip the
        // flag. .disabled(appState.isLaunching) on the buttons does not
        // save us either: SwiftUI's disabled-state propagation is driven
        // by the same @Published change.
        guard !appState.isLaunching else { return }
        appState.isLaunching = true

        Task { @MainActor in
            defer { appState.isLaunching = false }
            do {
                try await VSCodeLauncher.launch(with: account, appState: appState)
                // §4 contract: only update lastLaunched on successful return,
                // and do it AFTER awaiting — never optimistically before.
                appState.lastLaunched = account
            } catch VSCodeLaunchError.userCancelledQuit {
                // Deliberate user choice. No alert.
            } catch {
                await presentLaunchError(error)
            }
        }
    }

    @MainActor
    private func presentLaunchError(_ error: Error) async {
        // The popover may have closed by the time we get here (the launch
        // flow has multiple suspension points); bring ClaudeSwitcher forward
        // so the alert is owned by an active app and cannot end up hidden
        // behind other windows.
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Could not launch VS Code"
        // VSCodeLaunchError conforms to LocalizedError, so this returns
        // the per-case string directly. userCancelledQuit returns nil from
        // errorDescription as defence-in-depth, but the catch above
        // handles that case explicitly and never reaches here with it.
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        _ = alert.runModal()
    }
}

struct SetupView: View {
    @EnvironmentObject var appState: AppState
    @State private var validationError: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Welcome to ClaudeSwitcher").font(.headline)

            // Three-way branching on what's already present.
            switch (appState.personalConfigDirExists, appState.workConfigDirExists) {
            case (true, true):
                Text("Both accounts detected.").foregroundStyle(.secondary)
            case (true, false), (false, true):
                installAndLoginInstructions
                Text(appState.personalConfigDirExists
                     ? "Personal detected; Work still needed."
                     : "Work detected; Personal still needed.")
                    .font(.caption).foregroundStyle(.secondary)
            case (false, false):
                installAndLoginInstructions
            }

            if let validationError {
                Text(validationError).font(.caption).foregroundStyle(.red)
            }

            Button("I've logged in — Get Started") {
                // Re-validate at click time. The user may have just
                // finished `claude` login in another terminal.
                let personal = ClaudeAccount.personal.configDirExists
                let work = ClaudeAccount.work.configDirExists
                appState.personalConfigDirExists = personal
                appState.workConfigDirExists = work

                guard personal && work else {
                    let missing = !personal ? "~/.claude-personal" : "~/.claude-work"
                    validationError = "\(missing) not found. Run the login command above and try again."
                    return
                }

                // Same-directory / symlink check. If both expanded paths
                // resolve to the same canonical location (symlinked,
                // hardlinked, or both env-var inits pointed at the same
                // dir), the entire premise of the app is broken — both
                // launch buttons would inject identical CLAUDE_CONFIG_DIR
                // and account separation would be silently lost.
                // resolvingSymlinksInPath catches symlinks;
                // standardizedFileURL collapses ./.. and trailing-slash
                // differences.
                let personalCanonical = URL(fileURLWithPath: ClaudeAccount.personal.expandedConfigDir)
                    .resolvingSymlinksInPath().standardizedFileURL
                let workCanonical = URL(fileURLWithPath: ClaudeAccount.work.expandedConfigDir)
                    .resolvingSymlinksInPath().standardizedFileURL
                guard personalCanonical != workCanonical else {
                    validationError = "~/.claude-personal and ~/.claude-work resolve to the same directory. They must be separate so each account has its own config."
                    return
                }

                appState.hasCompletedSetup = true
            }
        }
        .padding(12)
    }

    @ViewBuilder
    private var installAndLoginInstructions: some View {
        Text("Install the Claude Code CLI (if needed):")
            .font(.caption)
            .foregroundStyle(.secondary)
        // .textSelection(.enabled) is load-bearing: without it the user
        // cannot copy the install command and will paste it manually or
        // skip setup entirely.
        Text("curl -fsSL https://claude.ai/install.sh | bash")
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
            .padding(6)
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(4)

        Text("Log into each account once:")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.top, 4)
        ForEach(ClaudeAccount.allCases) { account in
            // account.configDir form (~/.claude-personal) is what we want
            // users to type — the shell expands the tilde, and the
            // unexpanded form is portable across machines.
            Text("CLAUDE_CONFIG_DIR=\(account.configDir) claude")
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding(6)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(4)
        }
    }
}
