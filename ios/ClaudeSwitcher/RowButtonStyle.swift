import AppKit
import SwiftUI

/// Row-shaped button style: system-accent hover highlight, slightly darker pressed
/// state, dimmed when disabled. Used for the account rows and Quit in MainMenuView.
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
                .foregroundStyle(foregroundColor)
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

        // Matches the highlight macOS uses for menu items — follows the user's
        // accent color in System Settings.
        private var fillColor: Color {
            guard isEnabled else { return .clear }
            if configuration.isPressed { return Color.accentColor.opacity(0.85) }
            if isHovered { return Color.accentColor }
            return .clear
        }

        // selectedMenuItemTextColor is the dynamic system color paired with
        // the accent fill — white on the default blue, dark on light accents
        // like Yellow. Avoids hardcoding .white and breaking contrast.
        private var foregroundColor: Color {
            if isEnabled && (isHovered || configuration.isPressed) {
                return Color(nsColor: .selectedMenuItemTextColor)
            }
            return .primary
        }
    }
}
