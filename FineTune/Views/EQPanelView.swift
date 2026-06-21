// FineTune/Views/EQPanelView.swift
import SwiftUI
import Combine

struct EQPanelView: View {
    @Binding var settings: EQSettings
    let userPresets: [UserEQPreset]
    let onPresetSelected: (EQPreset) -> Void
    let onUserPresetSelected: (UserEQPreset) -> Void
    let onSettingsChanged: (EQSettings) -> Void
    let onSavePreset: (String, EQSettings) -> Void
    let onDeleteUserPreset: (UUID) -> Void
    let onRenameUserPreset: (UUID, String) -> Void

    @State private var isSaving = false
    @State private var savePresetName = ""
    @FocusState private var isSaveFieldFocused: Bool

    @State private var isRenaming = false
    @State private var renamePresetName = ""
    @State private var renamingPresetID: UUID?
    @FocusState private var isRenameFieldFocused: Bool

    @State private var liveGains: [Float] = [0, 0, 0, 0, 0]
    @State private var liveGainsTimer: Timer?

    private let frequencyLabels = ["32", "64", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]

    private func frequencyLabel5Band(_ index: Int) -> String {
        let labels = ["68Hz", "350Hz", "1.4kHz", "4.5kHz", "9.5kHz"]
        guard index >= 0 && index < labels.count else { return "" }
        return labels[index]
    }

    // MARK: - Preset Matching

    /// Finds the matching built-in preset for the current band gains, if any.
    private var currentBuiltInPreset: EQPreset? {
        EQPreset.allCases.first { preset in
            if preset == .auto {
                return settings.isAutoEQEnabled
            } else {
                return !settings.isAutoEQEnabled && preset.settings.bandGains == settings.bandGains
            }
        }
    }

    /// Finds the matching user preset for the current band gains, if any.
    private var currentUserPreset: UserEQPreset? {
        guard !settings.isAutoEQEnabled else { return nil }
        return userPresets.first { $0.settings.bandGains == settings.bandGains }
    }

    /// The currently selected picker item (built-in, user, or nil for "Custom").
    private var selectedPickerItem: EQPickerItem? {
        if let builtIn = currentBuiltInPreset {
            return EQPickerItem(builtIn: builtIn)
        } else if let user = currentUserPreset {
            return EQPickerItem(user: user)
        }
        return nil
    }

    /// Whether the current curve is custom (doesn't match any preset).
    private var isCustomCurve: Bool { selectedPickerItem == nil }

    var body: some View {
        let isEQSectionEnabled = Binding<Bool>(
            get: { settings.isEnabled },
            set: { newValue in
                settings.isEnabled = newValue
                onSettingsChanged(settings)
            }
        )

        // Entire EQ panel content inside recessed background
        VStack(spacing: 12) {
            // Header: Toggle left, save field or spacer in middle, Preset right
            HStack {
                // EQ toggle on left
                HStack(spacing: 6) {
                    Toggle("", isOn: isEQSectionEnabled)
                        .toggleStyle(.switch)
                        .scaleEffect(0.7)
                        .labelsHidden()
                    Text("EQ")
                        .font(DesignTokens.Typography.pickerText)
                        .foregroundStyle(.primary)
                }

                if isRenaming {
                    renamePresetField
                        .transition(.blurReplace.combined(with: .opacity))
                } else if isSaving {
                    savePresetField
                        .transition(.blurReplace.combined(with: .opacity))
                } else {
                    Spacer()

                    if currentUserPreset != nil {
                        renameButton
                            .transition(.blurReplace.combined(with: .opacity))
                            .disabled(!isEQSectionEnabled.wrappedValue)
                    } else if isCustomCurve {
                        saveButton
                            .transition(.blurReplace.combined(with: .opacity))
                            .disabled(!isEQSectionEnabled.wrappedValue)
                    }
                }

                // Preset picker on right (always visible)
                HStack(spacing: DesignTokens.Spacing.sm) {
                    Text("Preset")
                        .font(DesignTokens.Typography.pickerText)
                        .foregroundStyle(DesignTokens.Colors.textSecondary)

                    EQPresetPicker(
                        selectedItem: selectedPickerItem,
                        userPresets: userPresets,
                        onBuiltInSelected: onPresetSelected,
                        onUserPresetSelected: onUserPresetSelected,
                        onDeleteUserPreset: onDeleteUserPreset,
                        onRenameUserPreset: onRenameUserPreset
                    )
                    .disabled(!isEQSectionEnabled.wrappedValue)
                }
            }
            .zIndex(1)  // Ensure dropdown renders above sliders

            if settings.isAutoEQEnabled {
                HStack(spacing: 0) {
                    ForEach(0..<5, id: \.self) { index in
                        let labels = ["68", "350", "1.4k", "4.5k", "9.5k"]
                        EQSliderView(
                            frequency: labels[index],
                            gain: Binding(
                                get: { liveGains[index] },
                                set: { _ in }
                            ),
                            isAutoEQ: true
                        )
                        .frame(width: 44, height: 100)
                        .frame(maxWidth: .infinity)
                        .allowsHitTesting(false)
                    }
                }
                .opacity(1.0)
                .transition(.opacity)
            } else {
                HStack(spacing: 0) {
                    ForEach(0..<10, id: \.self) { index in
                        EQSliderView(
                            frequency: frequencyLabels[index],
                            gain: Binding(
                                get: { settings.bandGains[index] },
                                set: { newValue in
                                    settings.bandGains[index] = newValue
                                    onSettingsChanged(settings)
                                }
                            ),
                            isAutoEQ: false
                        )
                        .frame(width: 26, height: 100)
                        .frame(maxWidth: .infinity)
                    }
                }
                .opacity(settings.isEnabled ? 1.0 : 0.3)
                .allowsHitTesting(settings.isEnabled)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background {
            RoundedRectangle(cornerRadius: 10)
                .fill(DesignTokens.Colors.recessedBackground)
        }
        .padding(.horizontal, 2)
        .padding(.top, DesignTokens.Spacing.xs)
        .padding(.bottom, DesignTokens.Spacing.xs)
        .animation(DesignTokens.Animation.quick, value: isSaving)
        .animation(DesignTokens.Animation.quick, value: isRenaming)
        .onAppear {
            startLiveGainsTimer()
        }
        .onDisappear {
            stopLiveGainsTimer()
        }
        .onChange(of: settings.isAutoEQEnabled) { _, isEnabled in
            if isEnabled {
                startLiveGainsTimer()
            } else {
                stopLiveGainsTimer()
            }
        }
    }

    // MARK: - Save Button

    private var saveButton: some View {
        Button {
            savePresetName = ""
            isSaving = true
            Task { @MainActor in
                isSaveFieldFocused = true
            }
        } label: {
            Image(systemName: "plus.circle")
                .font(.system(size: 13))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(DesignTokens.Colors.interactiveDefault)
        }
        .buttonStyle(.plain)
        .help("Save current EQ as preset")
        .accessibilityLabel("Save current EQ curve as a new preset")
    }

    // MARK: - Save Preset Field

    private var savePresetField: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            TextField("Preset name", text: $savePresetName)
                .textFieldStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .focused($isSaveFieldFocused)
                .onSubmit { commitSave() }
                .onExitCommand { cancelSave() }

            Button {
                commitSave()
            } label: {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(
                        savePresetName.trimmingCharacters(in: .whitespaces).isEmpty
                            ? DesignTokens.Colors.textTertiary
                            : DesignTokens.Colors.accentPrimary
                    )
            }
            .buttonStyle(.plain)
            .disabled(savePresetName.trimmingCharacters(in: .whitespaces).isEmpty)
            .help("Save preset")
            .accessibilityLabel("Confirm save preset")

            Button {
                cancelSave()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(DesignTokens.Colors.textTertiary)
            }
            .buttonStyle(.plain)
            .help("Cancel")
            .accessibilityLabel("Cancel saving preset")
        }
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .padding(.vertical, 4)
        .background {
            RoundedRectangle(cornerRadius: DesignTokens.Dimensions.buttonRadius)
                .fill(.regularMaterial)
        }
        .overlay {
            RoundedRectangle(cornerRadius: DesignTokens.Dimensions.buttonRadius)
                .strokeBorder(DesignTokens.Colors.menuBorderHover, lineWidth: 0.5)
        }
    }

    // MARK: - Save Actions

    private func commitSave() {
        let trimmed = savePresetName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        // Store with isEnabled = true — isEnabled is per-app state, not preset state
        var presetSettings = settings
        presetSettings.isEnabled = true
        onSavePreset(trimmed, presetSettings)
        isSaving = false
        savePresetName = ""
    }

    private func cancelSave() {
        isSaving = false
        savePresetName = ""
    }

    // MARK: - Rename Button

    private var renameButton: some View {
        Button {
            if let preset = currentUserPreset {
                renamingPresetID = preset.id
                renamePresetName = preset.name
                isRenaming = true
                Task { @MainActor in
                    isRenameFieldFocused = true
                }
            }
        } label: {
            Image(systemName: "pencil")
                .font(.system(size: 12))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(DesignTokens.Colors.interactiveDefault)
        }
        .buttonStyle(.plain)
        .help("Rename preset")
        .accessibilityLabel("Rename current preset")
    }

    // MARK: - Rename Preset Field

    private var renamePresetField: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            TextField("Preset name", text: $renamePresetName)
                .textFieldStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .focused($isRenameFieldFocused)
                .onSubmit { commitRename() }
                .onExitCommand { cancelRename() }

            Button {
                commitRename()
            } label: {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(
                        renamePresetName.trimmingCharacters(in: .whitespaces).isEmpty
                            ? DesignTokens.Colors.textTertiary
                            : DesignTokens.Colors.accentPrimary
                    )
            }
            .buttonStyle(.plain)
            .disabled(renamePresetName.trimmingCharacters(in: .whitespaces).isEmpty)
            .help("Confirm rename")
            .accessibilityLabel("Confirm rename preset")

            Button {
                cancelRename()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(DesignTokens.Colors.textTertiary)
            }
            .buttonStyle(.plain)
            .help("Cancel")
            .accessibilityLabel("Cancel renaming preset")
        }
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .padding(.vertical, 4)
        .background {
            RoundedRectangle(cornerRadius: DesignTokens.Dimensions.buttonRadius)
                .fill(.regularMaterial)
        }
        .overlay {
            RoundedRectangle(cornerRadius: DesignTokens.Dimensions.buttonRadius)
                .strokeBorder(DesignTokens.Colors.menuBorderHover, lineWidth: 0.5)
        }
    }

    // MARK: - Rename Actions

    private func commitRename() {
        let trimmed = renamePresetName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let id = renamingPresetID else { return }
        onRenameUserPreset(id, trimmed)
        isRenaming = false
        renamePresetName = ""
        renamingPresetID = nil
    }

    private func cancelRename() {
        isRenaming = false
        renamePresetName = ""
        renamingPresetID = nil
    }

    private func startLiveGainsTimer() {
        guard liveGainsTimer == nil else { return }
        liveGainsTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            MainActor.assumeIsolated {
                if settings.isAutoEQEnabled {
                    self.liveGains = DynamicEqualizer.debugGains
                }
            }
        }
    }

    private func stopLiveGainsTimer() {
        liveGainsTimer?.invalidate()
        liveGainsTimer = nil
    }
}

// MARK: - Previews

#Preview {
    // Simulating how it appears inside ExpandableGlassRow
    VStack {
        EQPanelView(
            settings: .constant(EQSettings()),
            userPresets: [
                UserEQPreset(name: "My Bass", settings: EQSettings(bandGains: [6, 5, 4, 0, 0, 0, 0, 0, 0, 0]))
            ],
            onPresetSelected: { _ in },
            onUserPresetSelected: { _ in },
            onSettingsChanged: { _ in },
            onSavePreset: { _, _ in },
            onDeleteUserPreset: { _ in },
            onRenameUserPreset: { _, _ in }
        )
    }
    .padding(.horizontal, DesignTokens.Spacing.sm)
    .padding(.vertical, DesignTokens.Spacing.xs)
    .frame(width: 550)
    .padding()
    .background(Color.black.opacity(0.4))
}

#Preview("Custom Curve - Save Visible") {
    VStack {
        EQPanelView(
            settings: .constant(EQSettings(bandGains: [3, 2, 1, 0, -1, 0, 2, 3, 1, 0])),
            userPresets: [],
            onPresetSelected: { _ in },
            onUserPresetSelected: { _ in },
            onSettingsChanged: { _ in },
            onSavePreset: { _, _ in },
            onDeleteUserPreset: { _ in },
            onRenameUserPreset: { _, _ in }
        )
    }
    .padding(.horizontal, DesignTokens.Spacing.sm)
    .padding(.vertical, DesignTokens.Spacing.xs)
    .frame(width: 550)
    .padding()
    .background(Color.black)
}
