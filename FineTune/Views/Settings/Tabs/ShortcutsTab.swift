// FineTune/Views/Settings/Tabs/ShortcutsTab.swift
import SwiftUI
import KeyboardShortcuts

@MainActor
struct ShortcutsTab: View {
    @Bindable var settings: SettingsManager
    @Bindable var accessibility: AccessibilityPermissionService
    @Bindable var mediaKeyStatus: MediaKeyStatus
    @Bindable var bottomEdgeScrollStatus: EventTapStatus
    let mediaKeyMonitor: MediaKeyMonitor
    let bottomEdgeScrollMonitor: BottomEdgeScrollMonitor
    let shortcutsRegistry: ShortcutsRegistry

    /// Either feature needs Accessibility to install its CGEventTap.
    private var needsAccessibility: Bool {
        (settings.appSettings.mediaKeyControlEnabled
            || settings.appSettings.bottomEdgeScrollEnabled)
            && !accessibility.isTrustedCached
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                volumeSection
                mediaKeysSection
                hotkeysSection
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
        .onChange(of: settings.appSettings.mediaKeyControlEnabled) { _, _ in
            mediaKeyMonitor.reconcile()
        }
        .onChange(of: settings.appSettings.bottomEdgeScrollEnabled) { _, _ in
            bottomEdgeScrollMonitor.reconcile()
        }
    }

    // MARK: - Volume

    private var volumeSection: some View {
        SettingsSection("Volume") {
            SettingsRow(
                "Volume Step",
                description: "How much the volume changes per step. Applies to media keys, configured hotkeys, arrow-key nav in the popup, and bottom-edge scroll."
            ) {
                Picker("", selection: $settings.appSettings.volumeHotkeyStep) {
                    ForEach(VolumeHotkeyStep.allCases) { step in
                        Text(step.description).tag(step)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }
            SettingsRowDivider()
            SettingsRow(
                "Scroll at Bottom Edge",
                description: "Cursor at the bottom of the screen (incl. Dock), then mouse wheel or two-finger trackpad scroll changes volume. Needs Accessibility; grant Input Monitoring if macOS asks (Debug builds must be allowed separately from /Applications)."
            ) {
                Toggle("", isOn: $settings.appSettings.bottomEdgeScrollEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }
            if settings.appSettings.bottomEdgeScrollEnabled && !accessibility.isTrustedCached {
                SettingsRowDivider()
                AccessibilityPromptStrip(accessibility: accessibility)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            }
            if bottomEdgeScrollStatus.isOffline {
                SettingsRowDivider()
                BottomEdgeScrollOfflineCard {
                    bottomEdgeScrollMonitor.reconcile()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
    }

    // MARK: - Media Keys

    private var mediaKeysSection: some View {
        SettingsSection("Media Keys") {
            SettingsRow(
                "Media Keys Control",
                description: "Use F11/F12 (or volume keys) to control FineTune"
            ) {
                Toggle("", isOn: $settings.appSettings.mediaKeyControlEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }

            // Single shared banner when either tap feature needs Accessibility.
            if needsAccessibility {
                SettingsRowDivider()
                AccessibilityPromptStrip(accessibility: accessibility)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            }

            if mediaKeyStatus.isOffline {
                SettingsRowDivider()
                MediaKeyOfflineCard {
                    mediaKeyMonitor.reconcile()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }

            // HUD chrome applies to media keys and bottom-edge scroll alike.
            if (settings.appSettings.mediaKeyControlEnabled
                || settings.appSettings.bottomEdgeScrollEnabled)
                && accessibility.isTrustedCached {
                SettingsRowDivider()
                SettingsRow(
                    "HUD Style",
                    description: "How the volume indicator looks"
                ) {
                    HUDStyleSegmentedControl(selection: $settings.appSettings.hudStyle)
                }
                SettingsRowDivider()
                SettingsRow(
                    "HUD Position",
                    description: "Where the volume indicator appears on screen (media keys, bottom-edge scroll, and hotkeys)."
                ) {
                    Picker("", selection: $settings.appSettings.hudPosition) {
                        ForEach(HUDScreenPosition.allCases) { position in
                            Text(position.displayName).tag(position)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                }
            }
        }
    }

    // MARK: - Hotkeys

    private var hotkeysSection: some View {
        SettingsSection("Hotkeys") {
            ForEach(Array(ShortcutAction.allCases.enumerated()), id: \.element) { index, action in
                if index > 0 { SettingsRowDivider() }
                SettingsRow(
                    action.displayName,
                    description: description(for: action)
                ) {
                    KeyboardShortcuts.Recorder(
                        for: shortcutsRegistry.name(for: action),
                        onChange: shortcutsRegistry.recordCallback(for: action)
                    )
                }
            }
        }
    }

    private func description(for action: ShortcutAction) -> String {
        switch action {
        case .togglePopup: "Show or hide the menu bar popup"
        case .targetAppVolumeUp: "Raise volume for the app playing audio"
        case .targetAppVolumeDown: "Lower volume for the app playing audio"
        case .targetAppMuteToggle: "Mute or unmute the app playing audio"
        }
    }
}
