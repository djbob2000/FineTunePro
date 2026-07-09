// FineTune/Views/Components/DeviceEnhancementPicker.swift
import SwiftUI

/// Icon-only button that opens a popover for selecting AutoEQ headphone correction profiles.
/// Follows the same pattern as the EQ toggle button in `AppRowControls`.
struct DeviceEnhancementPicker: View {
    let profileManager: AutoEQProfileManager
    let profileName: String?
    let selection: AutoEQSelection?
    let favoriteIDs: Set<String>
    let onSelect: (AutoEQProfile?) -> Void
    let onImport: () -> Void
    let onToggleFavorite: (String) -> Void
    let importError: String?
    var isCorrectionEnabled: Bool = false
    var onCorrectionToggle: ((Bool) -> Void)?
    var preampEnabled: Bool = true
    var onPreampToggle: (() -> Void)?

    // Loudness Compensation Integration
    var isLoudnessEnabled: Bool = false
    var onLoudnessToggle: ((Bool) -> Void)? = nil
    var loudnessMaxDB: Double = -30.0
    var onLoudnessMaxDBChange: ((Double) -> Void)? = nil
    var supportsLoudness: Bool = false
    var supportsAutoEQ: Bool = true

    @State private var isExpanded = false
    @State private var isButtonHovered = false

    @Environment(\.appearancePreference) private var appearancePreference

    // MARK: - Layout Constants

    private let popoverWidth: CGFloat = 260

    // MARK: - Computed

    private var iconColor: Color {
        if isExpanded {
            return DesignTokens.Colors.accentPrimary
        } else if (isCorrectionEnabled && selection != nil) || isLoudnessEnabled {
            return DesignTokens.Colors.accentPrimary
        } else if selection != nil || profileName != nil {
            // Dim when profile assigned but correction and loudness disabled
            return DesignTokens.Colors.interactiveDefault
        } else if isButtonHovered {
            return DesignTokens.Colors.interactiveHover
        }
        return DesignTokens.Colors.interactiveDefault
    }

    // MARK: - Body

    var body: some View {
        triggerButton
            .background(
                PopoverHost(
                    isPresented: $isExpanded,
                    preferredColorScheme: appearancePreference.swiftUIColorScheme,
                    nsAppearance: appearancePreference.nsAppearance
                ) {
                    popoverContent
                }
            )
    }

    // MARK: - Trigger Button

    private var triggerButton: some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) {
                isExpanded.toggle()
            }
        } label: {
            Image(systemName: "wand.and.sparkles")
                .font(.system(size: 16))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(iconColor)
                .frame(
                    minWidth: DesignTokens.Dimensions.minTouchTarget,
                    minHeight: DesignTokens.Dimensions.minTouchTarget
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isButtonHovered = $0 }
        .help(L10n.string(isExpanded ? "Close AutoEQ" : "AutoEQ correction"))
        .animation(DesignTokens.Animation.hover, value: isButtonHovered)
    }

    // MARK: - Popover Content

    private var popoverContent: some View {
        VStack(spacing: 0) {
            DeviceEnhancementPanel(
                profileManager: profileManager,
                favoriteIDs: favoriteIDs,
                selectedProfileID: selection?.profileID,
                onSelect: { profile in
                    onSelect(profile)
                    withAnimation(.easeOut(duration: 0.15)) {
                        isExpanded = false
                    }
                },
                onDismiss: {
                    withAnimation(.easeOut(duration: 0.15)) {
                        isExpanded = false
                    }
                },
                onImport: {
                    isExpanded = false
                    onImport()
                },
                onToggleFavorite: onToggleFavorite,
                importErrorMessage: importError,
                isCorrectionEnabled: isCorrectionEnabled,
                onCorrectionToggle: onCorrectionToggle,
                preampEnabled: preampEnabled,
                onPreampToggle: onPreampToggle,
                supportsLoudness: supportsLoudness,
                isLoudnessEnabled: isLoudnessEnabled,
                onLoudnessToggle: onLoudnessToggle,
                loudnessMaxDB: loudnessMaxDB,
                onLoudnessMaxDBChange: onLoudnessMaxDBChange,
                supportsAutoEQ: supportsAutoEQ
            )
        }
        .frame(width: popoverWidth)
        .menuGlassStyle(cornerRadius: 8)
    }
}
