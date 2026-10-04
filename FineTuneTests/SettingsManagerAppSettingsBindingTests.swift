// FineTuneTests/SettingsManagerAppSettingsBindingTests.swift
import Testing
import Foundation
@testable import FineTune

@MainActor
@Suite("SettingsManager.appSettings — direct binding setter")
struct SettingsManagerAppSettingsBindingTests {
    private func makeManager(service: FakeLaunchAtLoginService = FakeLaunchAtLoginService()) -> SettingsManager {
        SettingsManager(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), launchAtLoginService: service)
    }

    @Test("Direct assignment to appSettings persists the new value")
    func directAssignmentPersists() async {
        let manager = makeManager()
        var newSettings = manager.appSettings
        newSettings.defaultNewAppVolume = 0.42
        newSettings.lockInputDevice = true

        manager.appSettings = newSettings

        #expect(manager.appSettings.defaultNewAppVolume == 0.42)
        #expect(manager.appSettings.lockInputDevice == true)
    }

    @Test("Direct assignment forwards launch-at-login change to LaunchAtLoginService")
    func directAssignmentForwardsLaunchAtLogin() async {
        let service = FakeLaunchAtLoginService()
        let manager = makeManager(service: service)
        var newSettings = manager.appSettings
        let original = newSettings.launchAtLogin
        newSettings.launchAtLogin = !original

        manager.appSettings = newSettings

        #expect(manager.appSettings.launchAtLogin == !original)
        #expect(service.registerCount == 1)
        #expect(manager.isLaunchAtLoginEnabled)
    }

    @Test("Direct assignment is equivalent to updateAppSettings for the same input")
    func directAssignmentEquivalentToUpdate() async {
        let managerA = makeManager()
        let managerB = makeManager()

        var modified = managerA.appSettings
        modified.defaultNewAppVolume = 0.7
        modified.mediaKeyControlEnabled = true
        modified.showDeviceDisconnectAlerts = false

        managerA.appSettings = modified
        managerB.updateAppSettings(modified)

        #expect(managerA.appSettings == managerB.appSettings)
    }
}
