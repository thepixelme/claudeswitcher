import SwiftUI

/// Row-shaped button style: subtle hover highlight, slightly darker pressed state,
/// dimmed when disabled. Used for the account rows and Quit in MainMenuView.
/// Setup view's prominent Log In CTAs use the system `.buttonStyle(.glass)` instead.
struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RowButton(configuration: configuration)
    }

    private struct RowButton: View {
        let configuration: ButtonStyle.Configuration
        @State private var isHovered = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(fillColor)
                )
                .opacity(isEnabled ? 1.0 : 0.45)
                // Separate animations on hover vs. press so toggling .disabled()
                // (which flips isEnabled, not these values) doesn't trigger a fade.
                .animation(.easeOut(duration: 0.12), value: isHovered)
                .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
                .onHover { hovering in
                    guard isEnabled else { isHovered = false; return }
                    isHovered = hovering
                }
        }

        // Color.primary adapts to light/dark mode automatically — white-tint on
        // dark, black-tint on light. Same trick AppKit menus use.
        private var fillColor: Color {
            guard isEnabled else { return .clear }
            if configuration.isPressed { return Color.primary.opacity(0.18) }
            if isHovered { return Color.primary.opacity(0.10) }
            return .clear
        }
    }
}
