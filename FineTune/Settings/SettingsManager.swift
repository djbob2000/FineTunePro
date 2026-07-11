// FineTune/Settings/SettingsManager.swift
import Foundation
import os
import ServiceManagement
import AppKit

// MARK: - Pinned App Info

struct PinnedAppInfo: Codable, Equatable {
    let persistenceIdentifier: String
    let displayName: String
    let bundleID: String?
}

// MARK: - Ignored App Info

struct IgnoredAppInfo: Codable, Equatable {
    let persistenceIdentifier: String
    let displayName: String
    let bundleID: String?
}

// MARK: - App-Wide Settings Model

nonisolated struct AppSettings: Codable, Equatable {
    // General
    var launchAtLogin: Bool = false
    var menuBarIconStyle: MenuBarIconStyle = .default

    // Audio
    var defaultNewAppVolume: Float = 1.0      // 100% (unity gain)
    var autoSwitchToConnectedOutputDevice: Bool = false  // Prefer newly connected outputs over current default
    var maxVolumeBoost: Float = 2.0           // 200% max
    var useLogScale: Bool = false             // Measure volume in dB
        
    // Whether to show all devices (including combined/virtual) in device lists
    var showAllDevices: Bool = false

    // Input Device Lock
    var lockInputDevice: Bool = true          // Prevent auto-switching input device

    // Notifications
    var showDeviceDisconnectAlerts: Bool = true

    // Audio Processing
    var loudnessCompensationEnabled: Bool = false  // ISO 226:2023 equal-loudness contour compensation
    
    // Legacy Migration
    private var unifiedLoudnessEnabled: Bool? = nil

    // Monitor (DDC/CI) volume control
    // When enabled, FineTune probes external displays over I2C (DDC/CI) so monitor
    // speakers appear as volume-controllable outputs. Probing writes to the display's
    // DDC bus; some USB-C→HDMI / DisplayPort adapters mishandle this and drop the
    // video link (monitor goes dark). Disable to skip all DDC probing/writes.
    var ddcVolumeControlEnabled: Bool = true

    // Media Keys & HUD
    var hudStyle: HUDStyle = .tahoe                // Visual style of the volume HUD
    var hudPosition: HUDScreenPosition = .topTrailing  // Corner / edge where the volume HUD appears
    var mediaKeyControlEnabled: Bool = true        // Intercept F10/F11/F12 to drive the default output device
    var volumeHotkeyStep: VolumeHotkeyStep = .normal  // Slider-domain step per keypress; user-configurable

    // Global Hotkeys
    // Keyed by ShortcutAction.rawValue. Values mirror what KeyboardShortcuts persists in
    // its UserDefaults; settings.json is the source of truth.
    var customShortcuts: [String: ShortcutCodable] = [:]

    // Appearance
    var appearance: AppearancePreference = .system  // Follow system appearance, or lock light/dark
    var languagePreference: AppLanguagePreference = .system  // Follow system language, or override per app

    // Popup
    var popupSize: MenuBarPopupSize = .comfortable  // Overall menu bar popup size and density

    // Bottom Edge Scroll — uses volumeHotkeyStep for step size (same as media keys / hotkeys)
    var bottomEdgeScrollEnabled: Bool = false

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        menuBarIconStyle = try c.decodeIfPresent(MenuBarIconStyle.self, forKey: .menuBarIconStyle) ?? .default
        defaultNewAppVolume = try c.decodeIfPresent(Float.self, forKey: .defaultNewAppVolume) ?? 1.0
        autoSwitchToConnectedOutputDevice = try c.decodeIfPresent(Bool.self, forKey: .autoSwitchToConnectedOutputDevice) ?? false
        lockInputDevice = try c.decodeIfPresent(Bool.self, forKey: .lockInputDevice) ?? true
        showDeviceDisconnectAlerts = try c.decodeIfPresent(Bool.self, forKey: .showDeviceDisconnectAlerts) ?? true
        loudnessCompensationEnabled = try c.decodeIfPresent(Bool.self, forKey: .loudnessCompensationEnabled) ?? false
        ddcVolumeControlEnabled = try c.decodeIfPresent(Bool.self, forKey: .ddcVolumeControlEnabled) ?? true
        hudStyle = try c.decodeIfPresent(HUDStyle.self, forKey: .hudStyle) ?? .tahoe
        hudPosition = try c.decodeIfPresent(HUDScreenPosition.self, forKey: .hudPosition) ?? .topTrailing
        mediaKeyControlEnabled = try c.decodeIfPresent(Bool.self, forKey: .mediaKeyControlEnabled) ?? true
        volumeHotkeyStep = try c.decodeIfPresent(VolumeHotkeyStep.self, forKey: .volumeHotkeyStep) ?? .normal
        customShortcuts = try c.decodeIfPresent([String: ShortcutCodable].self, forKey: .customShortcuts) ?? [:]
        appearance = try c.decodeIfPresent(AppearancePreference.self, forKey: .appearance) ?? .system
        languagePreference = try c.decodeIfPresent(AppLanguagePreference.self, forKey: .languagePreference) ?? .system
        popupSize = try c.decodeIfPresent(MenuBarPopupSize.self, forKey: .popupSize) ?? .comfortable
        bottomEdgeScrollEnabled = try c.decodeIfPresent(Bool.self, forKey: .bottomEdgeScrollEnabled) ?? false
        // Legacy bottomEdgeScrollStep (Float) is intentionally ignored; step is volumeHotkeyStep.

        // Migrate legacy unified loudness
        if let legacyUnified = try c.decodeIfPresent(Bool.self, forKey: .unifiedLoudnessEnabled) {
            if legacyUnified {
                loudnessCompensationEnabled = true
            }
        }
    }
}

// MARK: - Settings Manager

@Observable
@MainActor
final class SettingsManager {
    private var settings: Settings
    private var saveTask: Task<Void, Never>?
    private let settingsURL: URL
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "FineTune", category: "SettingsManager")

    private var isSettingUp = false
    var appSettings: AppSettings {
        didSet {
            guard !isSettingUp else { return }
            if appSettings.launchAtLogin != settings.appSettings.launchAtLogin {
                setLaunchAtLogin(appSettings.launchAtLogin)
            }
            if appSettings.languagePreference != settings.appSettings.languagePreference {
                appSettings.languagePreference.apply()
            }
            settings.appSettings = appSettings
            scheduleSave()
        }
    }

    struct Settings: Codable {
        var version: Int = 12
        var appVolumes: [String: Float] = [:]
        var appDeviceRouting: [String: String] = [:]  // bundleID → deviceUID
        var appMutes: [String: Bool] = [:]  // bundleID → isMuted
        var appBoosts: [String: Float] = [:]  // bundleID → boost rawValue (1.0, 2.0, 3.0, 4.0)
        var appEQSettings: [String: EQSettings] = [:]  // bundleID → EQ settings
        var appAUEffectChains: [String: [AUEffectChainEntry]] = [:]  // persistenceIdentifier → AU chain
        var deviceAUEffectChains: [String: [AUEffectChainEntry]] = [:]  // deviceUID → AU chain
        var favoriteAUPlugins: Set<String> = []  // plugin descriptor IDs
        var auPluginCrashHistory: Set<String> = []  // plugin IDs active during a crash
        var appAUBypassed: [String: Bool] = [:]  // persistenceIdentifier → bypassed
        var deviceAUBypassed: [String: Bool] = [:]  // deviceUID → bypassed
        var appSettings: AppSettings = AppSettings()  // App-wide settings
        var systemSoundsFollowsDefault: Bool = true  // Whether system sounds follows macOS default
        var appDeviceSelectionMode: [String: DeviceSelectionMode] = [:]  // bundleID → selection mode
        var appSelectedDeviceUIDs: [String: [String]] = [:]  // bundleID → array of device UIDs for multi mode
        var lockedInputDeviceUID: String? = nil  // Current locked input device (updated on fallback)
        var preferredInputDeviceUID: String? = nil  // User's intended input device (survives disconnect)
        var pinnedApps: Set<String> = []  // Persistence identifiers of pinned apps
        var pinnedAppInfo: [String: PinnedAppInfo] = [:]  // Persistence identifier → app metadata
        var ignoredApps: Set<String> = []  // Persistence identifiers of hidden apps
        var ignoredAppInfo: [String: IgnoredAppInfo] = [:]  // Persistence identifier → app metadata

        // DDC monitor speaker volumes (keyed by CoreAudio device UID for stability across reboots)
        var ddcVolumes: [String: Int] = [:]       // device UID → volume (0-100)
        var ddcMuteStates: [String: Bool] = [:]   // device UID → software mute state
        var ddcSavedVolumes: [String: Int] = [:]  // device UID → volume before mute

        // Software-backed output volumes for devices without native volume control
        var softwareDeviceVolumes: [String: Float] = [:]      // device UID → visible volume (0.0-1.0)
        var softwareDeviceMuteStates: [String: Bool] = [:]    // device UID → software mute state
        var softwareDeviceSavedVolumes: [String: Float] = [:] // device UID → volume before mute

        // Per-device volume control tier override (overrides auto-detection).
        // nil/missing → auto-detect (hardware/ddc/software). Populated only by
        // the user via the device detail sheet's manual override toggle.
        var deviceVolumeTierOverride: [String: VolumeControlTier] = [:]
        var deviceIconOverrides: [String: String] = [:]  // device UID → SF Symbol name

        // Device priority (ordered device UIDs, highest priority first)
        var outputDevicePriority: [String] = []
        var inputDevicePriority: [String] = []

        // Hidden devices (UIDs of devices suppressed from the main view)
        var hiddenOutputDeviceUIDs: Set<String> = []
        var hiddenInputDeviceUIDs: Set<String> = []

        // Per-device AutoEQ headphone correction
        var deviceAutoEQ: [String: AutoEQSelection] = [:]  // deviceUID → selection
        var favoriteAutoEQProfiles: Set<String> = []  // profile IDs
        var autoEQPreampEnabled: Bool = true  // Use profile preamp vs bypass (rely on limiter)

        // Per-device loudness settings
        var appSmartVolumeEnabled: [String: Bool] = [:] // bundleID/identifier -> enabled
        var deviceSmartVolumeEnabled: [String: Bool] = [:] // deviceUID -> enabled
        var deviceLoudnessCompensationEnabled: [String: Bool] = [:] // deviceUID -> enabled
        var deviceLoudnessReferencePhon: [String: Double] = [:] // deviceUID -> startDB (default: 0.0)
        var deviceLoudnessMaxDB: [String: Double] = [:] // deviceUID -> maxDB (default: -20.0)
        var deviceLoudnessBassCrossover: [String: Double] = [:] // deviceUID -> crossover frequency
        var deviceLoudnessGainScale: [String: Double] = [:] // deviceUID -> gain scale (amount)
        var deviceLoudnessBassExciterWet: [String: Double] = [:] // deviceUID -> bass exciter wet (0.0 to 1.0)
        var deviceLoudnessBassLinearWet: [String: Double] = [:] // deviceUID -> bass linear wet (0.0 to 1.0)
        var deviceLoudnessTrebleCrossover: [String: Double] = [:] // deviceUID -> treble crossover frequency
        var deviceLoudnessTrebleGainScale: [String: Double] = [:] // deviceUID -> treble gain scale (amount)

        // User-created EQ presets (named EQ curves)
        var userEQPresets: [UserEQPreset] = []

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 9
            appVolumes = (try c.decodeIfPresent([String: Float].self, forKey: .appVolumes) ?? [:])
                .filter { $0.value.isFinite && $0.value >= 0 }
                .mapValues { min($0, 1.0) }  // Clamp old volumes > 1.0 (boost is now per-app)
            appDeviceRouting = try c.decodeIfPresent([String: String].self, forKey: .appDeviceRouting) ?? [:]
            appMutes = try c.decodeIfPresent([String: Bool].self, forKey: .appMutes) ?? [:]
            appBoosts = try c.decodeIfPresent([String: Float].self, forKey: .appBoosts) ?? [:]
            appEQSettings = try c.decodeIfPresent([String: EQSettings].self, forKey: .appEQSettings) ?? [:]
            appAUEffectChains = try c.decodeIfPresent([String: [AUEffectChainEntry]].self, forKey: .appAUEffectChains) ?? [:]
            deviceAUEffectChains = try c.decodeIfPresent([String: [AUEffectChainEntry]].self, forKey: .deviceAUEffectChains) ?? [:]
            favoriteAUPlugins = try c.decodeIfPresent(Set<String>.self, forKey: .favoriteAUPlugins) ?? []
            auPluginCrashHistory = try c.decodeIfPresent(Set<String>.self, forKey: .auPluginCrashHistory) ?? []
            appAUBypassed = try c.decodeIfPresent([String: Bool].self, forKey: .appAUBypassed) ?? [:]
            deviceAUBypassed = try c.decodeIfPresent([String: Bool].self, forKey: .deviceAUBypassed) ?? [:]
            var decodedAppSettings = try c.decodeIfPresent(AppSettings.self, forKey: .appSettings) ?? AppSettings()
            if !decodedAppSettings.defaultNewAppVolume.isFinite || decodedAppSettings.defaultNewAppVolume < 0 {
                decodedAppSettings.defaultNewAppVolume = 1.0
            }

            appSettings = decodedAppSettings
            systemSoundsFollowsDefault = try c.decodeIfPresent(Bool.self, forKey: .systemSoundsFollowsDefault) ?? true
            appDeviceSelectionMode = try c.decodeIfPresent([String: DeviceSelectionMode].self, forKey: .appDeviceSelectionMode) ?? [:]
            appSelectedDeviceUIDs = try c.decodeIfPresent([String: [String]].self, forKey: .appSelectedDeviceUIDs) ?? [:]
            lockedInputDeviceUID = try c.decodeIfPresent(String.self, forKey: .lockedInputDeviceUID)
            preferredInputDeviceUID = try c.decodeIfPresent(String.self, forKey: .preferredInputDeviceUID)
            pinnedApps = try c.decodeIfPresent(Set<String>.self, forKey: .pinnedApps) ?? []
            pinnedAppInfo = try c.decodeIfPresent([String: PinnedAppInfo].self, forKey: .pinnedAppInfo) ?? [:]
            ignoredApps = try c.decodeIfPresent(Set<String>.self, forKey: .ignoredApps) ?? []
            ignoredAppInfo = try c.decodeIfPresent([String: IgnoredAppInfo].self, forKey: .ignoredAppInfo) ?? [:]
            ddcVolumes = try c.decodeIfPresent([String: Int].self, forKey: .ddcVolumes) ?? [:]
            ddcMuteStates = try c.decodeIfPresent([String: Bool].self, forKey: .ddcMuteStates) ?? [:]
            ddcSavedVolumes = try c.decodeIfPresent([String: Int].self, forKey: .ddcSavedVolumes) ?? [:]
            softwareDeviceVolumes = (try c.decodeIfPresent([String: Float].self, forKey: .softwareDeviceVolumes) ?? [:])
                .filter { $0.value.isFinite && $0.value >= 0 }
                .mapValues { min($0, 1.0) }
            softwareDeviceMuteStates = try c.decodeIfPresent([String: Bool].self, forKey: .softwareDeviceMuteStates) ?? [:]
            softwareDeviceSavedVolumes = (try c.decodeIfPresent([String: Float].self, forKey: .softwareDeviceSavedVolumes) ?? [:])
                .filter { $0.value.isFinite && $0.value >= 0 }
                .mapValues { min($0, 1.0) }
            deviceVolumeTierOverride = try c.decodeIfPresent([String: VolumeControlTier].self, forKey: .deviceVolumeTierOverride) ?? [:]
            deviceIconOverrides = try c.decodeIfPresent([String: String].self, forKey: .deviceIconOverrides) ?? [:]
            outputDevicePriority = try c.decodeIfPresent([String].self, forKey: .outputDevicePriority) ?? []
            inputDevicePriority = try c.decodeIfPresent([String].self, forKey: .inputDevicePriority) ?? []
            hiddenOutputDeviceUIDs = try c.decodeIfPresent(Set<String>.self, forKey: .hiddenOutputDeviceUIDs) ?? []
            hiddenInputDeviceUIDs = try c.decodeIfPresent(Set<String>.self, forKey: .hiddenInputDeviceUIDs) ?? []
            deviceAutoEQ = try c.decodeIfPresent([String: AutoEQSelection].self, forKey: .deviceAutoEQ) ?? [:]
            favoriteAutoEQProfiles = try c.decodeIfPresent(Set<String>.self, forKey: .favoriteAutoEQProfiles) ?? []
            autoEQPreampEnabled = try c.decodeIfPresent(Bool.self, forKey: .autoEQPreampEnabled) ?? true
            appSmartVolumeEnabled = try c.decodeIfPresent([String: Bool].self, forKey: .appSmartVolumeEnabled) ?? [:]
            deviceSmartVolumeEnabled = try c.decodeIfPresent([String: Bool].self, forKey: .deviceSmartVolumeEnabled) ?? [:]
            deviceLoudnessCompensationEnabled = try c.decodeIfPresent([String: Bool].self, forKey: .deviceLoudnessCompensationEnabled) ?? [:]
            deviceLoudnessReferencePhon = try c.decodeIfPresent([String: Double].self, forKey: .deviceLoudnessReferencePhon) ?? [:]
            deviceLoudnessBassCrossover = try c.decodeIfPresent([String: Double].self, forKey: .deviceLoudnessBassCrossover) ?? [:]
            deviceLoudnessGainScale = try c.decodeIfPresent([String: Double].self, forKey: .deviceLoudnessGainScale) ?? [:]
            deviceLoudnessBassExciterWet = try c.decodeIfPresent([String: Double].self, forKey: .deviceLoudnessBassExciterWet) ?? [:]
            deviceLoudnessBassLinearWet = try c.decodeIfPresent([String: Double].self, forKey: .deviceLoudnessBassLinearWet) ?? [:]
            deviceLoudnessTrebleCrossover = try c.decodeIfPresent([String: Double].self, forKey: .deviceLoudnessTrebleCrossover) ?? [:]
            deviceLoudnessTrebleGainScale = try c.decodeIfPresent([String: Double].self, forKey: .deviceLoudnessTrebleGainScale) ?? [:]
            userEQPresets = try c.decodeIfPresent([UserEQPreset].self, forKey: .userEQPresets) ?? []
        }
    }

    init(directory: URL? = nil) {
        let baseDir = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("FineTune")
        self.settingsURL = baseDir.appendingPathComponent("settings.json")
        self.settings = Settings()
        self.appSettings = AppSettings()
        self.isSettingUp = true
        loadFromDisk()
        self.appSettings = settings.appSettings
        self.isSettingUp = false
    }

    func getVolume(for identifier: String) -> Float? {
        settings.appVolumes[identifier]
    }

    func setVolume(for identifier: String, to volume: Float) {
        settings.appVolumes[identifier] = volume
        scheduleSave()
    }

    // MARK: - Per-App Boost

    func getBoost(for identifier: String) -> BoostLevel? {
        guard let raw = settings.appBoosts[identifier] else { return nil }
        return BoostLevel(rawValue: raw)
    }

    func setBoost(for identifier: String, to boost: BoostLevel) {
        settings.appBoosts[identifier] = boost.rawValue
        scheduleSave()
    }

    func getDeviceRouting(for identifier: String) -> String? {
        settings.appDeviceRouting[identifier]
    }

    func setDeviceRouting(for identifier: String, deviceUID: String) {
        settings.appDeviceRouting[identifier] = deviceUID
        scheduleSave()
    }

    /// Returns true if the app follows system default (no explicit device routing saved)
    func isFollowingDefault(for identifier: String) -> Bool {
        settings.appDeviceRouting[identifier] == nil
    }

    /// Clears device routing for an app, making it follow system default
    func setFollowDefault(for identifier: String) {
        settings.appDeviceRouting.removeValue(forKey: identifier)
        scheduleSave()
    }

    // MARK: - System Sounds Settings

    /// Returns whether system sounds should follow the macOS default output device
    var isSystemSoundsFollowingDefault: Bool {
        settings.systemSoundsFollowsDefault
    }

    /// Sets whether system sounds should follow the macOS default output device
    func setSystemSoundsFollowDefault(_ follows: Bool) {
        settings.systemSoundsFollowsDefault = follows
        scheduleSave()
    }

    func getMute(for identifier: String) -> Bool? {
        settings.appMutes[identifier]
    }

    func setMute(for identifier: String, to muted: Bool) {
        settings.appMutes[identifier] = muted
        scheduleSave()
    }

    func getEQSettings(for appIdentifier: String) -> EQSettings {
        return settings.appEQSettings[appIdentifier] ?? EQSettings.flat
    }

    func setEQSettings(_ eqSettings: EQSettings, for appIdentifier: String) {
        settings.appEQSettings[appIdentifier] = eqSettings
        scheduleSave()
    }

    // MARK: - AU Effect Chains

    func getAUEffectChain(for appIdentifier: String) -> [AUEffectChainEntry] {
        settings.appAUEffectChains[appIdentifier] ?? []
    }

    func setAUEffectChain(_ chain: [AUEffectChainEntry], for appIdentifier: String) {
        if chain.isEmpty {
            settings.appAUEffectChains.removeValue(forKey: appIdentifier)
        } else {
            settings.appAUEffectChains[appIdentifier] = chain
        }
        scheduleSave()
    }

    func getDeviceAUEffectChain(for deviceUID: String) -> [AUEffectChainEntry] {
        settings.deviceAUEffectChains[deviceUID] ?? []
    }

    func setDeviceAUEffectChain(_ chain: [AUEffectChainEntry], for deviceUID: String) {
        if chain.isEmpty {
            settings.deviceAUEffectChains.removeValue(forKey: deviceUID)
        } else {
            settings.deviceAUEffectChains[deviceUID] = chain
        }
        scheduleSave()
    }

    // MARK: - AU Plugin Favorites

    func isAUPluginFavorite(_ pluginID: String) -> Bool {
        settings.favoriteAUPlugins.contains(pluginID)
    }

    func toggleAUPluginFavorite(_ pluginID: String) {
        if settings.favoriteAUPlugins.contains(pluginID) {
            settings.favoriteAUPlugins.remove(pluginID)
        } else {
            settings.favoriteAUPlugins.insert(pluginID)
        }
        scheduleSave()
    }

    var favoriteAUPlugins: Set<String> {
        settings.favoriteAUPlugins
    }

    // MARK: - AU Plugin Crash History

    func markAUPluginsActiveAtCrash(_ pluginIDs: Set<String>) {
        settings.auPluginCrashHistory.formUnion(pluginIDs)
        scheduleSave()
    }

    func clearAUPluginCrashHistory() {
        settings.auPluginCrashHistory.removeAll()
        scheduleSave()
    }

    func wasAUPluginInvolvedInCrash(_ pluginID: String) -> Bool {
        settings.auPluginCrashHistory.contains(pluginID)
    }

    var auPluginCrashHistory: Set<String> {
        settings.auPluginCrashHistory
    }

    func disableCrashedAUPlugins(_ crashedIDs: Set<String>) {
        for (appID, chain) in settings.appAUEffectChains {
            var updated = chain
            var changed = false
            for i in updated.indices where crashedIDs.contains(updated[i].pluginDescriptor.id) {
                updated[i].isEnabled = false
                changed = true
            }
            if changed { settings.appAUEffectChains[appID] = updated }
        }
        for (deviceUID, chain) in settings.deviceAUEffectChains {
            var updated = chain
            var changed = false
            for i in updated.indices where crashedIDs.contains(updated[i].pluginDescriptor.id) {
                updated[i].isEnabled = false
                changed = true
            }
            if changed { settings.deviceAUEffectChains[deviceUID] = updated }
        }
        scheduleSave()
    }

    // MARK: - AU Bypass Persistence

    func setAppAUBypassed(_ bypassed: Bool, for appIdentifier: String) {
        if bypassed {
            settings.appAUBypassed[appIdentifier] = true
        } else {
            settings.appAUBypassed.removeValue(forKey: appIdentifier)
        }
        scheduleSave()
    }

    func getAppAUBypassed(for appIdentifier: String) -> Bool {
        settings.appAUBypassed[appIdentifier] ?? false
    }

    func setDeviceAUBypassed(_ bypassed: Bool, for deviceUID: String) {
        if bypassed {
            settings.deviceAUBypassed[deviceUID] = true
        } else {
            settings.deviceAUBypassed.removeValue(forKey: deviceUID)
        }
        scheduleSave()
    }

    func getDeviceAUBypassed(for deviceUID: String) -> Bool {
        settings.deviceAUBypassed[deviceUID] ?? false
    }

    // MARK: - Device Selection Mode

    func getDeviceSelectionMode(for identifier: String) -> DeviceSelectionMode? {
        settings.appDeviceSelectionMode[identifier]
    }

    func setDeviceSelectionMode(for identifier: String, to mode: DeviceSelectionMode) {
        settings.appDeviceSelectionMode[identifier] = mode
        scheduleSave()
    }

    // MARK: - Selected Device UIDs (Multi Mode)

    func getSelectedDeviceUIDs(for identifier: String) -> Set<String>? {
        guard let uids = settings.appSelectedDeviceUIDs[identifier] else { return nil }
        return Set(uids)
    }

    func setSelectedDeviceUIDs(for identifier: String, to uids: Set<String>) {
        settings.appSelectedDeviceUIDs[identifier] = Array(uids)
        scheduleSave()
    }

    // MARK: - Input Device Lock

    var lockedInputDeviceUID: String? {
        settings.lockedInputDeviceUID
    }

    func setLockedInputDeviceUID(_ uid: String?) {
        settings.lockedInputDeviceUID = uid
        scheduleSave()
    }

    var preferredInputDeviceUID: String? {
        settings.preferredInputDeviceUID
    }

    func setPreferredInputDeviceUID(_ uid: String?) {
        settings.preferredInputDeviceUID = uid
        scheduleSave()
    }

    // MARK: - Pinned Apps

    func pinApp(_ identifier: String, info: PinnedAppInfo) {
        settings.pinnedApps.insert(identifier)
        settings.pinnedAppInfo[identifier] = info
        scheduleSave()
    }

    func unpinApp(_ identifier: String) {
        settings.pinnedApps.remove(identifier)
        settings.pinnedAppInfo.removeValue(forKey: identifier)
        scheduleSave()
    }

    func isPinned(_ identifier: String) -> Bool {
        settings.pinnedApps.contains(identifier)
    }

    /// Returns metadata for all pinned apps
    func getPinnedAppInfo() -> [PinnedAppInfo] {
        settings.pinnedApps.compactMap { settings.pinnedAppInfo[$0] }
    }

    // MARK: - Ignored Apps

    func ignoreApp(_ identifier: String, info: IgnoredAppInfo) {
        settings.ignoredApps.insert(identifier)
        settings.ignoredAppInfo[identifier] = info
        // Hiding is mutually exclusive with pinning
        settings.pinnedApps.remove(identifier)
        settings.pinnedAppInfo.removeValue(forKey: identifier)
        // Clear per-app settings — FineTune won't interact with this app
        settings.appVolumes.removeValue(forKey: identifier)
        settings.appBoosts.removeValue(forKey: identifier)
        settings.appMutes.removeValue(forKey: identifier)
        settings.appDeviceRouting.removeValue(forKey: identifier)
        settings.appEQSettings.removeValue(forKey: identifier)
        settings.appAUEffectChains.removeValue(forKey: identifier)
        settings.appDeviceSelectionMode.removeValue(forKey: identifier)
        settings.appSelectedDeviceUIDs.removeValue(forKey: identifier)
        scheduleSave()
    }

    func unignoreApp(_ identifier: String) {
        settings.ignoredApps.remove(identifier)
        settings.ignoredAppInfo.removeValue(forKey: identifier)
        scheduleSave()
    }

    func isIgnored(_ identifier: String) -> Bool {
        settings.ignoredApps.contains(identifier)
    }

    func getIgnoredAppInfo() -> [IgnoredAppInfo] {
        settings.ignoredApps.compactMap { settings.ignoredAppInfo[$0] }
    }

    // MARK: - DDC Monitor Volume

    func getDDCVolume(for deviceUID: String) -> Int? {
        settings.ddcVolumes[deviceUID]
    }

    func setDDCVolume(for deviceUID: String, to volume: Int) {
        settings.ddcVolumes[deviceUID] = volume
        scheduleSave()
    }

    func getDDCMuteState(for deviceUID: String) -> Bool {
        settings.ddcMuteStates[deviceUID] ?? false
    }

    func setDDCMuteState(for deviceUID: String, to muted: Bool) {
        settings.ddcMuteStates[deviceUID] = muted
        scheduleSave()
    }

    func getDDCSavedVolume(for deviceUID: String) -> Int? {
        settings.ddcSavedVolumes[deviceUID]
    }

    func setDDCSavedVolume(for deviceUID: String, to volume: Int) {
        settings.ddcSavedVolumes[deviceUID] = volume
        scheduleSave()
    }

    // MARK: - Software Output Device Volume

    func getSoftwareDeviceVolume(for deviceUID: String) -> Float? {
        settings.softwareDeviceVolumes[deviceUID]
    }

    func setSoftwareDeviceVolume(for deviceUID: String, to volume: Float) {
        settings.softwareDeviceVolumes[deviceUID] = normalizedDeviceVolume(volume)
        scheduleSave()
    }

    func getSoftwareDeviceMuteState(for deviceUID: String) -> Bool {
        settings.softwareDeviceMuteStates[deviceUID] ?? false
    }

    func setSoftwareDeviceMuteState(for deviceUID: String, to muted: Bool) {
        settings.softwareDeviceMuteStates[deviceUID] = muted
        scheduleSave()
    }

    func getSoftwareDeviceSavedVolume(for deviceUID: String) -> Float? {
        settings.softwareDeviceSavedVolumes[deviceUID]
    }

    func setSoftwareDeviceSavedVolume(for deviceUID: String, to volume: Float) {
        settings.softwareDeviceSavedVolumes[deviceUID] = normalizedDeviceVolume(volume)
        scheduleSave()
    }

    // MARK: - Per-Device Volume Tier Override

    /// Returns the user-set override tier for a device, or nil when
    /// auto-detection should take effect.
    func getDeviceVolumeTierOverride(for deviceUID: String) -> VolumeControlTier? {
        settings.deviceVolumeTierOverride[deviceUID]
    }

    /// Sets or clears the volume tier override for a device. Passing `nil` removes
    /// the override, returning the device to auto-detection.
    func setDeviceVolumeTierOverride(for deviceUID: String, to tier: VolumeControlTier?) {
        if let tier {
            settings.deviceVolumeTierOverride[deviceUID] = tier
        } else {
            settings.deviceVolumeTierOverride.removeValue(forKey: deviceUID)
        }
        scheduleSave()
    }

    // MARK: - Per-Device Icon Override

    /// Returns the user-chosen SF Symbol override for a device, or nil when
    /// the automatic icon should take effect.
    func getDeviceIconOverride(for deviceUID: String) -> String? {
        settings.deviceIconOverrides[deviceUID]
    }

    /// All UID → symbol overrides, for views that render many devices.
    var deviceIconOverrides: [String: String] {
        settings.deviceIconOverrides
    }

    /// Sets or clears the icon override for a device. Passing `nil` removes
    /// the override, returning the device to its automatic icon.
    func setDeviceIconOverride(for deviceUID: String, to symbol: String?) {
        if let symbol {
            settings.deviceIconOverrides[deviceUID] = symbol
        } else {
            settings.deviceIconOverrides.removeValue(forKey: deviceUID)
        }
        scheduleSave()
    }

    // MARK: - Device Priority

    var devicePriorityOrder: [String] {
        settings.outputDevicePriority
    }

    func setDevicePriorityOrder(_ uids: [String]) {
        settings.outputDevicePriority = uids
        scheduleSave()
    }

    func ensureDeviceInPriority(_ uid: String, isBuiltInSpeaker: Bool = false) {
        guard !settings.outputDevicePriority.contains(uid) else { return }
        if isBuiltInSpeaker {
            settings.outputDevicePriority.append(uid)
        } else {
            if let speakerIndex = settings.outputDevicePriority.firstIndex(where: {
                $0.lowercased().contains("speaker") || $0.lowercased().contains("builtin")
            }) {
                settings.outputDevicePriority.insert(uid, at: speakerIndex)
            } else {
                settings.outputDevicePriority.append(uid)
            }
        }
        scheduleSave()
    }

    var inputDevicePriorityOrder: [String] {
        settings.inputDevicePriority
    }

    func setInputDevicePriorityOrder(_ uids: [String]) {
        settings.inputDevicePriority = uids
        scheduleSave()
    }

    func ensureInputDeviceInPriority(_ uid: String) {
        guard !settings.inputDevicePriority.contains(uid) else { return }
        settings.inputDevicePriority.append(uid)
        scheduleSave()
    }

    // MARK: - Hidden Devices

    /// Hides an output device from the main view. Has no effect when the device is the current default.
    func hideOutputDevice(uid: String) {
        settings.hiddenOutputDeviceUIDs.insert(uid)
        scheduleSave()
    }

    /// Reveals a previously hidden output device in the main view.
    func unhideOutputDevice(uid: String) {
        settings.hiddenOutputDeviceUIDs.remove(uid)
        scheduleSave()
    }

    /// Returns true if the output device is hidden from the main view.
    func isOutputDeviceHidden(_ uid: String) -> Bool {
        settings.hiddenOutputDeviceUIDs.contains(uid)
    }

    /// All UIDs of hidden output devices.
    var hiddenOutputDeviceUIDs: Set<String> {
        settings.hiddenOutputDeviceUIDs
    }

    /// Flips the hidden state of an output device based on the persisted set.
    /// Prefer this over read-then-hide/unhide from the view layer, which can
    /// desync under rapid taps that re-read stale captured state.
    func toggleOutputDeviceHidden(uid: String) {
        if settings.hiddenOutputDeviceUIDs.contains(uid) {
            settings.hiddenOutputDeviceUIDs.remove(uid)
        } else {
            settings.hiddenOutputDeviceUIDs.insert(uid)
        }
        scheduleSave()
    }

    /// Hides an input device from the main view. Has no effect when the device is the current default.
    func hideInputDevice(uid: String) {
        settings.hiddenInputDeviceUIDs.insert(uid)
        scheduleSave()
    }

    /// Reveals a previously hidden input device in the main view.
    func unhideInputDevice(uid: String) {
        settings.hiddenInputDeviceUIDs.remove(uid)
        scheduleSave()
    }

    /// Returns true if the input device is hidden from the main view.
    func isInputDeviceHidden(_ uid: String) -> Bool {
        settings.hiddenInputDeviceUIDs.contains(uid)
    }

    /// All UIDs of hidden input devices.
    var hiddenInputDeviceUIDs: Set<String> {
        settings.hiddenInputDeviceUIDs
    }

    /// Flips the hidden state of an input device based on the persisted set.
    func toggleInputDeviceHidden(uid: String) {
        if settings.hiddenInputDeviceUIDs.contains(uid) {
            settings.hiddenInputDeviceUIDs.remove(uid)
        } else {
            settings.hiddenInputDeviceUIDs.insert(uid)
        }
        scheduleSave()
    }

    /// Merges reordered connected devices into the full priority list, preserving
    /// disconnected device positions via an anchor algorithm.
    ///
    /// Each disconnected UID is anchored to the last connected UID that preceded it
    /// in `oldPriority`. When rebuilding, disconnected UIDs are inserted after their
    /// anchor (or at the start if no anchor exists).
    ///
    /// - Parameters:
    ///   - oldPriority: The full saved priority list (connected + disconnected UIDs).
    ///   - connectedOrder: The user's reordered list of currently-connected UIDs.
    /// - Returns: Merged priority list preserving disconnected positions relative to connected anchors.
    func mergeDevicePriorityOrder(oldPriority: [String], connectedOrder: [String]) {
        settings.outputDevicePriority = Self.mergePriorityOrder(oldPriority: oldPriority, connectedOrder: connectedOrder)
        scheduleSave()
    }

    /// Input device variant of `mergeDevicePriorityOrder`.
    func mergeInputDevicePriorityOrder(oldPriority: [String], connectedOrder: [String]) {
        settings.inputDevicePriority = Self.mergePriorityOrder(oldPriority: oldPriority, connectedOrder: connectedOrder)
        scheduleSave()
    }

    /// Pure function: merges reordered connected UIDs back into the full priority list.
    ///
    /// Algorithm:
    /// 1. Walk `oldPriority` and assign each disconnected UID an "anchor" — the last
    ///    connected UID that preceded it.  UIDs with no preceding connected UID use
    ///    `nil` anchor (inserted at the front).
    /// 2. Build result from `connectedOrder`, inserting disconnected groups after
    ///    their anchor.
    /// 3. Append any connected UIDs not in `oldPriority` at the end (brand new devices).
    static func mergePriorityOrder(oldPriority: [String], connectedOrder: [String]) -> [String] {
        let connectedSet = Set(connectedOrder)

        // Step 1: Build anchor map — disconnected UID → last connected UID before it (or nil)
        // Also collect ordering of disconnected UIDs per anchor to preserve relative order
        var anchoredGroups: [String?: [String]] = [:]  // anchor → [disconnected UIDs]
        var currentAnchor: String? = nil

        for uid in oldPriority {
            if connectedSet.contains(uid) {
                currentAnchor = uid
            } else {
                anchoredGroups[currentAnchor, default: []].append(uid)
            }
        }

        // Step 2: Build result — insert disconnected groups after their anchors
        var result: [String] = []

        // First, insert any disconnected UIDs anchored to nil (they were before all connected devices)
        if let prefixGroup = anchoredGroups[nil] {
            result.append(contentsOf: prefixGroup)
        }

        for uid in connectedOrder {
            result.append(uid)
            if let group = anchoredGroups[uid] {
                result.append(contentsOf: group)
            }
        }

        return result
    }

    /// Removes per-app settings for apps that are no longer active, not pinned,
    /// and have only default values. Preserves device routing (explicit user intent).
    ///
    /// - Parameter activeIdentifiers: Persistence identifiers of currently active apps.
    func pruneStaleSettings(keeping activeIdentifiers: Set<String>) {
        let allIdentifiers = Set(settings.appVolumes.keys)
            .union(settings.appBoosts.keys)
            .union(settings.appMutes.keys)
            .union(settings.appEQSettings.keys)
            .union(settings.appDeviceSelectionMode.keys)
            .union(settings.appSelectedDeviceUIDs.keys)

        var pruned = 0
        for identifier in allIdentifiers {
            // Keep active apps
            if activeIdentifiers.contains(identifier) { continue }
            // Keep pinned apps
            if settings.pinnedApps.contains(identifier) { continue }
            // Keep apps with explicit device routing (user intent)
            if settings.appDeviceRouting[identifier] != nil { continue }

            // Check if all remaining settings are default values
            let volume = settings.appVolumes[identifier]
            let mute = settings.appMutes[identifier]
            let eq = settings.appEQSettings[identifier]
            let selectionMode = settings.appDeviceSelectionMode[identifier]
            let selectedUIDs = settings.appSelectedDeviceUIDs[identifier]

            let boost = settings.appBoosts[identifier]

            let isDefaultVolume = volume == nil || volume == 1.0
            let isDefaultBoost = boost == nil || boost == BoostLevel.x1.rawValue
            let isDefaultMute = mute == nil || mute == false
            let isDefaultEQ = eq == nil || eq == .flat
            let isDefaultSelectionMode = selectionMode == nil
            let isDefaultSelectedUIDs = selectedUIDs == nil || selectedUIDs?.isEmpty == true

            guard isDefaultVolume && isDefaultBoost && isDefaultMute && isDefaultEQ
                    && isDefaultSelectionMode && isDefaultSelectedUIDs else {
                continue
            }

            // All values are defaults — safe to prune
            settings.appVolumes.removeValue(forKey: identifier)
            settings.appBoosts.removeValue(forKey: identifier)
            settings.appMutes.removeValue(forKey: identifier)
            settings.appEQSettings.removeValue(forKey: identifier)
            settings.appAUEffectChains.removeValue(forKey: identifier)
            settings.appDeviceSelectionMode.removeValue(forKey: identifier)
            settings.appSelectedDeviceUIDs.removeValue(forKey: identifier)
            pruned += 1
        }

        if pruned > 0 {
            logger.info("Pruned \(pruned) stale app settings entries")
            scheduleSave()
        }
    }

    // MARK: - Per-Device AutoEQ

    func getAutoEQSelection(for deviceUID: String) -> AutoEQSelection? {
        settings.deviceAutoEQ[deviceUID]
    }

    func setAutoEQSelection(for deviceUID: String, to selection: AutoEQSelection?) {
        settings.deviceAutoEQ[deviceUID] = selection
        scheduleSave()
    }

    func favoriteAutoEQProfile(id: String) {
        settings.favoriteAutoEQProfiles.insert(id)
        scheduleSave()
    }

    func unfavoriteAutoEQProfile(id: String) {
        settings.favoriteAutoEQProfiles.remove(id)
        scheduleSave()
    }

    func isAutoEQFavorite(id: String) -> Bool {
        settings.favoriteAutoEQProfiles.contains(id)
    }

    var favoriteAutoEQProfileIDs: Set<String> {
        settings.favoriteAutoEQProfiles
    }

    var autoEQPreampEnabled: Bool {
        get { settings.autoEQPreampEnabled }
        set {
            settings.autoEQPreampEnabled = newValue
            scheduleSave()
        }
    }

    // MARK: - User EQ Presets

    /// Returns all user-created EQ presets, ordered by creation date (newest first).
    func getUserPresets() -> [UserEQPreset] {
        settings.userEQPresets.sorted { $0.createdAt > $1.createdAt }
    }

    /// Creates a new user EQ preset with the given name and band gains.
    /// Trims whitespace, falls back to "Untitled" for empty names,
    /// and auto-suffixes duplicates Finder-style: "Name (2)", "Name (3)", etc.
    /// Returns the created preset.
    @discardableResult
    func createUserPreset(name: String, settings eqSettings: EQSettings) -> UserEQPreset {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseName = trimmed.isEmpty ? "Untitled" : trimmed
        let finalName = uniquePresetName(baseName)
        let preset = UserEQPreset(name: finalName, settings: eqSettings)
        settings.userEQPresets.append(preset)
        scheduleSave()
        return preset
    }

    /// Renames an existing user preset. Trims whitespace; rejects empty names (no-op).
    /// Auto-suffixes if the new name collides with another preset.
    /// No-op if the preset ID is not found.
    func updateUserPreset(id: UUID, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let index = settings.userEQPresets.firstIndex(where: { $0.id == id }) else { return }
        let finalName = uniquePresetName(trimmed, excluding: id)
        settings.userEQPresets[index].name = finalName
        scheduleSave()
    }

    /// Generates a unique preset name by appending (2), (3), etc. if the name
    /// already exists among user presets. Follows Finder duplicate naming convention.
    /// - Parameters:
    ///   - name: The desired base name.
    ///   - excludeID: A preset ID to exclude from collision checks (used during rename).
    /// - Returns: A unique name, either the original or with a numeric suffix.
    private func uniquePresetName(_ name: String, excluding excludeID: UUID? = nil) -> String {
        let existingNames = Set(
            settings.userEQPresets
                .filter { $0.id != excludeID }
                .map { $0.name }
        )
        guard existingNames.contains(name) else { return name }

        var counter = 2
        while true {
            let candidate = "\(name) (\(counter))"
            if !existingNames.contains(candidate) { return candidate }
            counter += 1
        }
    }

    /// Deletes a user preset by ID. No-op if the preset ID is not found.
    func deleteUserPreset(id: UUID) {
        settings.userEQPresets.removeAll { $0.id == id }
        scheduleSave()
    }

    // MARK: - App-Wide Settings

    // (Stored appSettings property is declared at the top of the class)

    // MARK: - Per-App & Per-Device Smart Volume

    func getAppSmartVolumeEnabled(for identifier: String) -> Bool {
        settings.appSmartVolumeEnabled[identifier] ?? false
    }

    func setAppSmartVolumeEnabled(for identifier: String, to enabled: Bool) {
        settings.appSmartVolumeEnabled[identifier] = enabled
        scheduleSave()
    }

    func getSmartVolumeEnabled(for deviceUID: String) -> Bool {
        settings.deviceSmartVolumeEnabled[deviceUID] ?? false
    }

    func setSmartVolumeEnabled(for deviceUID: String, to enabled: Bool) {
        settings.deviceSmartVolumeEnabled[deviceUID] = enabled
        scheduleSave()
    }

    func disableAppSmartVolumeForDevice(deviceUID: String, defaultDeviceUID: String) {
        for (identifier, enabled) in settings.appSmartVolumeEnabled {
            guard enabled else { continue }
            let appDeviceUID = settings.appDeviceRouting[identifier] ?? defaultDeviceUID
            if appDeviceUID == deviceUID {
                settings.appSmartVolumeEnabled[identifier] = false
            }
        }
        scheduleSave()
    }

    // MARK: - Per-Device Loudness & Equalization

    func getLoudnessCompensationEnabled(for deviceUID: String) -> Bool {
        settings.deviceLoudnessCompensationEnabled[deviceUID] ?? false
    }

    func setLoudnessCompensationEnabled(for deviceUID: String, to enabled: Bool) {
        settings.deviceLoudnessCompensationEnabled[deviceUID] = enabled
        scheduleSave()
    }

    func getLoudnessReferencePhon(for deviceUID: String) -> Double {
        let val = settings.deviceLoudnessReferencePhon[deviceUID] ?? 0.0
        return (val >= -12.0 && val <= 0.0) ? val : 0.0
    }

    func setLoudnessReferencePhon(for deviceUID: String, to referencePhon: Double) {
        settings.deviceLoudnessReferencePhon[deviceUID] = min(0.0, max(-12.0, referencePhon))
        scheduleSave()
    }

    func getLoudnessMaxDB(for deviceUID: String) -> Double {
        let val = settings.deviceLoudnessMaxDB[deviceUID] ?? -30.0
        return (val >= -40.0 && val <= -20.0) ? val : -30.0
    }

    func setLoudnessMaxDB(for deviceUID: String, to maxDB: Double) {
        settings.deviceLoudnessMaxDB[deviceUID] = min(-20.0, max(-40.0, maxDB))
        scheduleSave()
    }


    func getLoudnessBassCrossover(for deviceUID: String) -> Double {
        settings.deviceLoudnessBassCrossover[deviceUID] ?? 70.0
    }

    func setLoudnessBassCrossover(for deviceUID: String, to frequency: Double) {
        settings.deviceLoudnessBassCrossover[deviceUID] = frequency
        scheduleSave()
    }

    func getLoudnessGainScale(for deviceUID: String) -> Double {
        settings.deviceLoudnessGainScale[deviceUID] ?? 1.0
    }

    func setLoudnessGainScale(for deviceUID: String, to scale: Double) {
        settings.deviceLoudnessGainScale[deviceUID] = scale
        scheduleSave()
    }

    func getLoudnessBassExciterWet(for deviceUID: String) -> Double {
        let val = settings.deviceLoudnessBassExciterWet[deviceUID] ?? 0.20
        return min(1.0, max(0.0, val))
    }

    func setLoudnessBassExciterWet(for deviceUID: String, to amount: Double) {
        settings.deviceLoudnessBassExciterWet[deviceUID] = min(1.0, max(0.0, amount))
        scheduleSave()
    }

    func getLoudnessBassLinearWet(for deviceUID: String) -> Double {
        let val = settings.deviceLoudnessBassLinearWet[deviceUID] ?? 1.0
        return min(1.0, max(0.0, val))
    }

    func setLoudnessBassLinearWet(for deviceUID: String, to amount: Double) {
        settings.deviceLoudnessBassLinearWet[deviceUID] = min(1.0, max(0.0, amount))
        scheduleSave()
    }

    func getLoudnessTrebleCrossover(for deviceUID: String) -> Double {
        settings.deviceLoudnessTrebleCrossover[deviceUID] ?? 3000.0
    }

    func setLoudnessTrebleCrossover(for deviceUID: String, to frequency: Double) {
        settings.deviceLoudnessTrebleCrossover[deviceUID] = frequency
        scheduleSave()
    }

    func getLoudnessTrebleGainScale(for deviceUID: String) -> Double {
        settings.deviceLoudnessTrebleGainScale[deviceUID] ?? 1.0
    }

    func setLoudnessTrebleGainScale(for deviceUID: String, to scale: Double) {
        settings.deviceLoudnessTrebleGainScale[deviceUID] = scale
        scheduleSave()
    }

    func updateAppSettings(_ newSettings: AppSettings) {
        appSettings = newSettings
    }

    // MARK: - All Devices
    
    var showAllDevices: Bool {
        appSettings.showAllDevices
    }

    func setShowAllDevices(_ show: Bool) {
        appSettings.showAllDevices = show
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
                logger.info("Registered for launch at login")
            } else {
                try SMAppService.mainApp.unregister()
                logger.info("Unregistered from launch at login")
            }
        } catch {
            logger.error("Failed to set launch at login: \(error.localizedDescription)")
        }
    }

    /// Returns the actual launch at login status from the system
    var isLaunchAtLoginEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    // MARK: - Reset All Settings

    /// Resets all per-app settings and app-wide settings to defaults
    func resetAllSettings() {
        isSettingUp = true
        settings.appVolumes.removeAll()
        settings.appBoosts.removeAll()
        settings.appDeviceRouting.removeAll()
        settings.appMutes.removeAll()
        settings.appEQSettings.removeAll()
        settings.appAUEffectChains.removeAll()
        settings.deviceAUEffectChains.removeAll()
        settings.favoriteAUPlugins.removeAll()
        settings.auPluginCrashHistory.removeAll()
        settings.appAUBypassed.removeAll()
        settings.deviceAUBypassed.removeAll()
        settings.pinnedApps.removeAll()
        settings.pinnedAppInfo.removeAll()
        settings.ignoredApps.removeAll()
        settings.ignoredAppInfo.removeAll()
        let oldLanguagePreference = settings.appSettings.languagePreference
        settings.appSettings = AppSettings()
        appSettings = AppSettings()
        if oldLanguagePreference != .system {
            appSettings.languagePreference.apply()
        }
        isSettingUp = false
        settings.systemSoundsFollowsDefault = true
        settings.lockedInputDeviceUID = nil
        settings.preferredInputDeviceUID = nil
        settings.ddcVolumes.removeAll()
        settings.ddcMuteStates.removeAll()
        settings.ddcSavedVolumes.removeAll()
        settings.softwareDeviceVolumes.removeAll()
        settings.softwareDeviceMuteStates.removeAll()
        settings.softwareDeviceSavedVolumes.removeAll()
        settings.deviceVolumeTierOverride.removeAll()
        settings.deviceIconOverrides.removeAll()
        settings.outputDevicePriority.removeAll()
        settings.inputDevicePriority.removeAll()
        settings.hiddenOutputDeviceUIDs.removeAll()
        settings.hiddenInputDeviceUIDs.removeAll()
        settings.autoEQPreampEnabled = true
        settings.deviceLoudnessCompensationEnabled.removeAll()
        settings.deviceLoudnessReferencePhon.removeAll()
        settings.deviceLoudnessBassCrossover.removeAll()
        settings.deviceLoudnessGainScale.removeAll()
        settings.deviceLoudnessTrebleCrossover.removeAll()
        settings.deviceLoudnessTrebleGainScale.removeAll()
        settings.deviceAutoEQ.removeAll()
        settings.favoriteAutoEQProfiles.removeAll()
        settings.appDeviceSelectionMode.removeAll()
        settings.appSelectedDeviceUIDs.removeAll()
        settings.userEQPresets.removeAll()

        // Also unregister from launch at login
        try? SMAppService.mainApp.unregister()

        scheduleSave()
        logger.info("Reset all settings to defaults")
    }

    private func loadFromDisk() {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return }

        do {
            let data = try Data(contentsOf: settingsURL)
            settings = try JSONDecoder().decode(Settings.self, from: data)
            logger.debug("Loaded settings with \(self.settings.appVolumes.count) volumes, \(self.settings.appDeviceRouting.count) device routings, \(self.settings.appMutes.count) mutes, \(self.settings.appEQSettings.count) EQ settings")
        } catch {
            logger.error("Failed to load settings: \(error.localizedDescription)")
            // Backup corrupted file before resetting
            let backupURL = settingsURL.deletingPathExtension().appendingPathExtension("backup.json")
            try? FileManager.default.removeItem(at: backupURL)  // Remove old backup if exists
            try? FileManager.default.copyItem(at: settingsURL, to: backupURL)
            logger.warning("Backed up corrupted settings to \(backupURL.lastPathComponent)")
            settings = Settings()
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            let snapshot = settings
            let url = settingsURL
            let data = try? JSONEncoder().encode(snapshot)
            guard let data else { return }
            Task.detached(priority: .utility) {
                do {
                    try Self.writeData(data, to: url)
                } catch {
                    // Avoid actor hops/logging on audio-critical paths; failures are
                    // non-fatal and will retry on the next settings mutation.
                }
            }
        }
    }

    /// Immediately writes pending changes to disk.
    /// Call this on app termination to prevent data loss.
    func flushSync() {
        saveTask?.cancel()
        saveTask = nil
        writeToDisk()
    }

    private func writeToDisk() {
        do {
            let data = try JSONEncoder().encode(settings)
            try Self.writeData(data, to: settingsURL)

            logger.debug("Saved settings")
        } catch {
            logger.error("Failed to save settings: \(error.localizedDescription)")
        }
    }

    private nonisolated static func writeData(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    private func normalizedDeviceVolume(_ volume: Float) -> Float {
        guard volume.isFinite else { return 1.0 }
        return max(0.0, min(1.0, volume))
    }
}
