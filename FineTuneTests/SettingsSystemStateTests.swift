import Foundation
import Testing
import ServiceManagement
@testable import FineTune

@MainActor
final class FakeLaunchAtLoginService: LaunchAtLoginProviding {
    var status: SMAppService.Status = .notRegistered
    var registrationStatus: SMAppService.Status = .enabled
    var registrationError: Error?
    var unregistrationError: Error?
    var registerCount = 0
    var unregisterCount = 0
    var openCount = 0
    func register() throws {
        registerCount += 1
        if let registrationError { throw registrationError }
        status = registrationStatus
    }
    func unregister() throws {
        unregisterCount += 1
        if let unregistrationError { throw unregistrationError }
        status = .notRegistered
    }
    func openLoginItems() { openCount += 1 }
}

@Suite("Settings system state and migration")
@MainActor
struct SettingsSystemStateTests {
    @Test("Initialization reconciles a stale saved login preference without changing the service")
    func staleLoginPreferenceIsReconciled() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = FakeLaunchAtLoginService()
        service.status = .enabled
        let actual = true
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: ["appSettings": ["launchAtLogin": !actual]])
        try data.write(to: directory.appendingPathComponent("settings.json"))

        let manager = SettingsManager(directory: directory, launchAtLoginService: service)

        #expect(manager.appSettings.launchAtLogin == actual)
        manager.flushSync()
        let persisted = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("settings.json"))) as! [String: Any]
        let appSettings = persisted["appSettings"] as! [String: Any]
        #expect(appSettings["launchAtLogin"] as? Bool == actual)
        #expect(service.registerCount == 0)
        #expect(service.unregisterCount == 0)
    }

    @Test("New and missing input-lock preferences leave macOS input selection available")
    func inputLockDefaultsOff() throws {
        #expect(AppSettings().lockInputDevice == false)
        #expect(try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8)).lockInputDevice == false)
        #expect(try JSONDecoder().decode(AppSettings.self, from: Data("{\"lockInputDevice\":true}".utf8)).lockInputDevice == true)
    }

    @Test("Linked device UIDs survive encoding including disconnected devices")
    func linkedDeviceUIDsPersist() throws {
        let original = Data("{\"linkedVolumeDeviceUIDs\":[\"connected\",\"disconnected\"]}".utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: original)
        let persisted = try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as! [String: Any]
        #expect(Set(persisted["linkedVolumeDeviceUIDs"] as? [String] ?? []) == ["connected", "disconnected"])
    }

    @Test("Login registration failure restores actual state and exposes the system error")
    func registrationFailureRollsBack() {
        let service = FakeLaunchAtLoginService()
        service.registrationError = NSError(domain: "Login", code: 1, userInfo: [NSLocalizedDescriptionKey: "Registration denied"])
        let manager = SettingsManager(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), launchAtLoginService: service)
        manager.appSettings.launchAtLogin = true
        #expect(manager.appSettings.launchAtLogin == false)
        #expect(manager.launchAtLoginError == "Registration denied")
        #expect(service.registerCount == 1)
    }

    @Test("Unregister failure retains the active login item even during reset")
    func unregisterFailureRetainsEnabledState() {
        let service = FakeLaunchAtLoginService()
        service.status = .enabled
        service.unregistrationError = NSError(domain: "Login", code: 2, userInfo: [NSLocalizedDescriptionKey: "Removal denied"])
        let manager = SettingsManager(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), launchAtLoginService: service)
        manager.appSettings.launchAtLogin = false
        #expect(manager.appSettings.launchAtLogin == true)
        #expect(manager.launchAtLoginError == "Removal denied")
        manager.resetAllSettings()
        #expect(manager.appSettings.launchAtLogin == true)
    }

    @Test("Pending approval is visible and rechecks after opening Login Items")
    func approvalAndExternalStatusChanges() {
        let service = FakeLaunchAtLoginService()
        service.registrationStatus = .requiresApproval
        let manager = SettingsManager(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), launchAtLoginService: service)
        manager.appSettings.launchAtLogin = true
        #expect(manager.appSettings.launchAtLogin == false)
        #expect(manager.launchAtLoginRequiresApproval)
        #expect(manager.launchAtLoginError == nil)
        manager.openLoginItems()
        #expect(service.openCount == 1)
        service.status = .enabled
        manager.reconcileLaunchAtLogin()
        #expect(manager.appSettings.launchAtLogin == true)
        #expect(manager.launchAtLoginRequiresApproval == false)
        service.status = .notRegistered
        manager.reconcileLaunchAtLogin()
        #expect(manager.appSettings.launchAtLogin == false)
        #expect(service.registerCount == 1)
        #expect(service.unregisterCount == 0)
    }
}
