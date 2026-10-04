// FineTune/Views/Settings/Tabs/GeneralTab.swift
import SwiftUI
import AppKit

@MainActor
struct GeneralTab: View {
    @Bindable var settings: SettingsManager
    let onResetAll: () -> Void

    @State private var showResetConfirmation = false
    @State private var showLanguageRestartPrompt = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                generalSection
                menuBarSection
                dataSection
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
        .onAppear { settings.reconcileLaunchAtLogin() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { settings.reconcileLaunchAtLogin() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            settings.reconcileLaunchAtLogin()
        }
        .confirmationDialog(
            "Reset all settings?",
            isPresented: $showResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reset", role: .destructive) { onResetAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone.")
        }
        .alert("Restart required", isPresented: $showLanguageRestartPrompt) {
            Button("Later", role: .cancel) {}
            Button("Restart") {
                relaunchFineTune()
            }
        } message: {
            Text("Restart FineTune to apply the selected language.")
        }
    }

    // MARK: - General

    private var generalSection: some View {
        SettingsSection("General") {
            SettingsRow(
                "Launch at Login",
                description: settings.launchAtLoginRequiresApproval
                    ? "Allow FineTune in macOS Login Items to start when you log in"
                    : "Start FineTune when you log in"
            ) {
                Toggle("", isOn: $settings.appSettings.launchAtLogin)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }
            if settings.launchAtLoginRequiresApproval {
                SettingsRowDivider()
                SettingsRow("Approval Required", description: "macOS has not approved launch at login") {
                    Button("Open Login Items") { settings.openLoginItems() }
                }
            }
            if let error = settings.launchAtLoginError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .accessibilityLabel("Launch at login failed: \(error)")
            }
            SettingsRowDivider()
            SettingsRow(
                "Theme",
                description: "Match macOS, or lock to Light or Dark"
            ) {
                ThemeTilePicker(selection: $settings.appSettings.appearance)
            }
            SettingsRowDivider()
            SettingsRow(
                "Language",
                description: "Choose the app language"
            ) {
                Picker("", selection: $settings.appSettings.languagePreference) {
                    ForEach(AppLanguagePreference.allCases) { preference in
                        Text(preference.description).tag(preference)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: DesignTokens.Dimensions.settingsPickerWidth)
                .onChange(of: settings.appSettings.languagePreference) { _, _ in
                    showLanguageRestartPrompt = true
                }
            }
            SettingsRowDivider()
            SettingsRow(
                "Device Disconnect Alerts",
                description: "Show notification when an audio device disconnects"
            ) {
                Toggle("", isOn: $settings.appSettings.showDeviceDisconnectAlerts)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }
        }
    }

    // MARK: - Menu Bar

    private var menuBarSection: some View {
        SettingsSection("Menu Bar") {
            SettingsRow(
                "Icon Style",
                description: "How FineTune appears in your menu bar"
            ) {
                IconStyleSegmentedControl(selection: $settings.appSettings.menuBarIconStyle)
            }
            SettingsRowDivider()
            SettingsRow(
                "Popup Size",
                description: "Smaller fits more on screen; larger leaves more breathing room."
            ) {
                PopupSizeTilePicker(selection: $settings.appSettings.popupSize)
            }
            SettingsRowDivider()
            SettingsRow(
                "Popup Position",
                description: "Follow the menu bar icon or keep the mixer in a screen corner"
            ) {
                Picker("", selection: $settings.appSettings.popupPosition) {
                    ForEach(MenuBarPopupPosition.allCases) { position in
                        Text(position.description).tag(position)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: DesignTokens.Dimensions.settingsPickerWidth)
            }
        }
    }

    // MARK: - Data

    private var dataSection: some View {
        SettingsSection("Data") {
            SettingsRow(
                "Reset All Settings",
                description: "Clear all volumes, EQ, and device routings"
            ) {
                Button(role: .destructive) {
                    showResetConfirmation = true
                } label: {
                    Text("Reset")
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .controlSize(.small)
            }
        }
    }

    private func relaunchFineTune() {
        settings.flushSync()

        let bundlePath = Bundle.main.bundlePath
        let quotedBundlePath = bundlePath.replacingOccurrences(of: "'", with: "'\\''")
        let script = "sleep 0.4; /usr/bin/open -n '\(quotedBundlePath)'"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        try? process.run()

        NSApp.terminate(nil)
    }
}
