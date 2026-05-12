import SwiftUI

@main
struct ClaudeSwitcherApp: App {
    @StateObject private var state = AppState()

    // Pre-warm the login-shell PATH lookup on app start so the spawn is
    // already in flight by the time the user clicks a launch button.
    // Wiring this into VSCodeLauncher's first-call path instead defeats
    // the whole point of pre-warming. This MUST run from App.init(), not
    // lazily from the launcher.
    init() {
        ShellEnvironment.shared.prewarm()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView().environmentObject(state)
        } label: {
            // The label is wrapped in MenuBarLabel (an EnvironmentObject-
            // observing child view) rather than reading `state` directly
            // here. Routing the binding through a child View that explicitly
            // observes AppState makes the label re-render reliably when
            // @Published properties change.
            MenuBarLabel().environmentObject(state)
        }
        .menuBarExtraStyle(.window)
    }
}

private struct MenuBarLabel: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        Image(systemName: state.menuBarIconName)
    }
}
