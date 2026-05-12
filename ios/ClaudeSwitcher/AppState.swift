import Foundation
import SwiftUI
import Combine

@MainActor
final class AppState: ObservableObject {
    private enum Keys {
        static let lastLaunched = "lastLaunchedAccount"
        static let hasCompletedSetup = "hasCompletedSetup"
    }

    // Persistent — survives app relaunch.
    @Published var lastLaunched: ClaudeAccount {
        didSet { UserDefaults.standard.set(lastLaunched.rawValue, forKey: Keys.lastLaunched) }
    }
    @Published var hasCompletedSetup: Bool {
        didSet { UserDefaults.standard.set(hasCompletedSetup, forKey: Keys.hasCompletedSetup) }
    }

    // Session-only — see §5. Deliberately NOT persisted.
    @Published var currentlyRunningAccount: ClaudeAccount? = nil
    @Published var launchedProcessIdentifier: pid_t? = nil

    // Re-entrancy guard for §4 launch buttons. The launch flow has multiple
    // suspension points (confirmQuit modal, waitForExit polling, openApplication
    // await) where a second click would race the first and corrupt the
    // session-tracking fields above.
    @Published var isLaunching: Bool = false

    // Seeded from disk so the menu bar icon is correct from the very first
    // frame. Refreshed by MenuBarView.onAppear (§7) on every popover open.
    @Published var personalConfigDirExists: Bool
    @Published var workConfigDirExists: Bool

    init() {
        // Load directly into backing storage. With @Published + didSet, the
        // setter path can fire didSet even during init in some Swift versions
        // (community has gone back and forth on this) — bypassing it via
        // _foo = Published(initialValue:) is safe regardless and avoids
        // re-writing the defaults below back to UserDefaults.
        let defaults = UserDefaults.standard
        let storedRaw = defaults.string(forKey: Keys.lastLaunched)
        self._lastLaunched = Published(
            initialValue: storedRaw.flatMap(ClaudeAccount.init(rawValue:)) ?? .personal
        )
        self._hasCompletedSetup = Published(
            initialValue: defaults.bool(forKey: Keys.hasCompletedSetup)
        )
        // Seed the config-dir flags from disk so menuBarIconName is correct
        // on first paint of the MenuBarExtra label. Without this, the label
        // binds to `false || false → warning` and the warning icon flashes
        // on every fresh launch until the popover opens.
        self._personalConfigDirExists = Published(
            initialValue: ClaudeAccount.personal.configDirExists
        )
        self._workConfigDirExists = Published(
            initialValue: ClaudeAccount.work.configDirExists
        )
    }

    /// SF Symbol name for the menu bar label. Returns the warning symbol
    /// when either config dir is missing (§3, §7).
    var menuBarIconName: String {
        if !personalConfigDirExists || !workConfigDirExists {
            return "exclamationmark.triangle.fill"
        }
        return lastLaunched.menuBarIcon
    }

    /// Called from MenuBarView.onAppear (§7). Two cheap stat calls.
    func refreshConfigDirExistence() {
        personalConfigDirExists = ClaudeAccount.personal.configDirExists
        workConfigDirExists = ClaudeAccount.work.configDirExists
    }
}
