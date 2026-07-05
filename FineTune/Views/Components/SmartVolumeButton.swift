// FineTune/Views/Components/SmartVolumeButton.swift
import SwiftUI

/// Compact icon button for toggling Smart Volume (Loudness Equalizer & Dynamic Level Normalization).
/// Placed next to volume sliders in application rows and device headers.
struct SmartVolumeButton: View {
    let isEnabled: Bool
    let isDisabled: Bool
    let onTap: () -> Void

    @State private var isHovered = false

    init(
        isEnabled: Bool,
        isDisabled: Bool = false,
        onTap: @escaping () -> Void
    ) {
        self.isEnabled = isEnabled
        self.isDisabled = isDisabled
        self.onTap = onTap
    }

    private func chevronColor(at index: Int) -> Color {
        if isDisabled {
            return DesignTokens.Colors.textTertiary.opacity(0.2)
        } else if isEnabled {
            return DesignTokens.Colors.accentPrimary
        } else {
            return isHovered ? .primary.opacity(0.35) : .primary.opacity(0.15)
        }
    }

    private var helpText: String {
        if isDisabled {
            return "Smart Volume is unavailable for built-in speakers."
        } else if isEnabled {
            return "Smart Volume: On (normalizes volume across content)"
        } else {
            return "Smart Volume: Off (click to normalize volume)"
        }
    }

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: -2) {
                ForEach((0..<3).reversed(), id: \.self) { index in
                    Image(systemName: "chevron.compact.up")
                        .font(.system(size: 12, weight: .heavy))
                        .foregroundStyle(chevronColor(at: index))
                }
            }
            .frame(
                minWidth: DesignTokens.Dimensions.minTouchTarget,
                minHeight: DesignTokens.Dimensions.minTouchTarget
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .onHover { isHovered = $0 }
        .help(helpText)
        .accessibilityLabel(isEnabled ? "Disable Smart Volume" : "Enable Smart Volume")
        .animation(.snappy(duration: 0.15), value: isEnabled)
        .animation(DesignTokens.Animation.hover, value: isHovered)
    }
}
