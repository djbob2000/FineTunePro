// FineTune/Views/Settings/EventTapOfflineCard.swift
import SwiftUI

/// Inline card shown when an event-tap feature is offline (kernel-stall / double-disable path).
/// Accessibility revocation surfaces via the permission card instead.
@MainActor
struct EventTapOfflineCard: View {
    let title: String
    let message: String
    let accessibilityLabel: String
    let accessibilityHint: String
    let onRetry: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 18, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color(nsColor: .systemOrange))
                .frame(width: DesignTokens.Dimensions.settingsIconWidth, alignment: .center)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.xs) {
                    Text(title)
                        .font(DesignTokens.Typography.rowNameBold)
                        .foregroundStyle(DesignTokens.Colors.textPrimary)
                    Spacer(minLength: DesignTokens.Spacing.xs)
                }

                Text(message)
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                Button(action: onRetry) {
                    HStack(spacing: DesignTokens.Spacing.xs) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10, weight: .medium))
                        Text("Retry")
                    }
                    .font(DesignTokens.Typography.pickerText)
                    .foregroundStyle(DesignTokens.Colors.textPrimary)
                }
                .buttonStyle(.plain)
                .glassButtonStyle()
                .padding(.top, 2)
                .accessibilityHint(L10n.string(accessibilityHint))
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .padding(.vertical, DesignTokens.Spacing.xs)
        .background {
            RoundedRectangle(cornerRadius: DesignTokens.Dimensions.buttonRadius)
                .fill(.ultraThinMaterial)
        }
        .overlay {
            RoundedRectangle(cornerRadius: DesignTokens.Dimensions.buttonRadius)
                .strokeBorder(Color(nsColor: .systemOrange).opacity(0.35), lineWidth: 0.5)
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.string(accessibilityLabel))
    }
}

/// Media-keys specialization of `EventTapOfflineCard`.
@MainActor
struct MediaKeyOfflineCard: View {
    let onRetry: () -> Void

    var body: some View {
        EventTapOfflineCard(
            title: "Media keys offline",
            message: "The system disabled FineTune's event tap — usually after a sleep/wake cycle or a main-thread stall. Retry to reinstall it.",
            accessibilityLabel: "Media keys offline. Retry to reinstall the event tap.",
            accessibilityHint: "Reinstalls the media-key event tap.",
            onRetry: onRetry
        )
    }
}

/// Bottom-edge scroll specialization of `EventTapOfflineCard`.
@MainActor
struct BottomEdgeScrollOfflineCard: View {
    let onRetry: () -> Void

    var body: some View {
        EventTapOfflineCard(
            title: "Bottom-edge scroll offline",
            message: "The system disabled FineTune's scroll event tap — usually after a sleep/wake cycle or a main-thread stall. Retry to reinstall it.",
            accessibilityLabel: "Bottom-edge scroll offline. Retry to reinstall the event tap.",
            accessibilityHint: "Reinstalls the bottom-edge scroll event tap.",
            onRetry: onRetry
        )
    }
}

// MARK: - Previews

#Preview("Media Keys Offline Card") {
    PreviewContainer {
        MediaKeyOfflineCard(onRetry: {})
            .frame(width: 420)
            .padding()
    }
}

#Preview("Bottom-Edge Offline Card") {
    PreviewContainer {
        BottomEdgeScrollOfflineCard(onRetry: {})
            .frame(width: 420)
            .padding()
    }
}
