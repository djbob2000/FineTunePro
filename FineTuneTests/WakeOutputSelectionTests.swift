import AppKit
import AudioToolbox
import Foundation
import Testing
@testable import FineTune

@Suite("Output selection after sleep")
@MainActor
struct WakeOutputSelectionTests {
    @Test("Wake restores the chosen output even when HDMI stays connected and ranks first")
    func unchangedHDMIDevice() async {
        let fixture = WakeOutputFixture()
        fixture.settings.setDevicePriorityOrder([fixture.hdmi.uid, fixture.chosen.uid])
        fixture.engine.handleSystemWillSleep()
        fixture.volume.externalDefault(fixture.hdmi)
        #expect(fixture.volume.writes.isEmpty)
        await fixture.engine.handleSystemDidWake()
        await fixture.settle()
        #expect(fixture.volume.defaultDeviceUID == fixture.chosen.uid)
        #expect(fixture.volume.writes.last == fixture.chosen.id)
        fixture.engine.stop()
    }

    @Test("Delayed HDMI default notifications cannot replace the pre-sleep choice")
    func delayedDefaultChanges() async {
        let fixture = WakeOutputFixture()
        fixture.engine.handleSystemWillSleep()
        await fixture.engine.handleSystemDidWake()
        for _ in 0..<3 {
            fixture.volume.externalDefault(fixture.hdmi)
            await fixture.settle()
            #expect(fixture.volume.defaultDeviceUID == fixture.chosen.uid)
        }
        fixture.engine.stop()
    }

    @Test("HDMI reconnect during wake cannot override the choice through connection priority")
    func reconnectDuringWake() async {
        let fixture = WakeOutputFixture()
        fixture.settings.appSettings.autoSwitchToConnectedOutputDevice = true
        fixture.settings.setDevicePriorityOrder([fixture.hdmi.uid, fixture.chosen.uid])
        fixture.engine.handleSystemWillSleep()
        fixture.devices.onDeviceConnected?(fixture.hdmi.uid, fixture.hdmi.name)
        #expect(fixture.volume.writes.isEmpty)
        await fixture.engine.handleSystemDidWake()
        fixture.devices.onDeviceConnected?(fixture.hdmi.uid, fixture.hdmi.name)
        await fixture.settle()
        #expect(fixture.volume.defaultDeviceUID == fixture.chosen.uid)
        fixture.engine.stop()
    }

    @Test("Unavailable pre-sleep output falls back to the highest-priority live output")
    func unavailableOutputFallback() async {
        let fixture = WakeOutputFixture()
        fixture.settings.setDevicePriorityOrder([fixture.chosen.uid, fixture.fallback.uid, fixture.hdmi.uid])
        fixture.engine.handleSystemWillSleep()
        fixture.devices.outputDevices.removeAll { $0.uid == fixture.chosen.uid }
        fixture.volume.externalDefault(fixture.hdmi)
        await fixture.engine.handleSystemDidWake()
        await fixture.settle()
        #expect(fixture.volume.defaultDeviceUID == fixture.fallback.uid)
        fixture.engine.stop()
    }

    @Test("A preferred output returning during wake is restored by UID with its new HAL ID")
    func lateOutputReturn() async {
        let fixture = WakeOutputFixture()
        fixture.settings.setDevicePriorityOrder([fixture.chosen.uid, fixture.fallback.uid, fixture.hdmi.uid])
        fixture.engine.handleSystemWillSleep()
        fixture.devices.outputDevices.removeAll { $0.uid == fixture.chosen.uid }
        fixture.volume.externalDefault(fixture.hdmi)
        await fixture.engine.handleSystemDidWake()
        await fixture.settle()
        let reconnected = AudioDevice(id: 404, uid: fixture.chosen.uid, name: "USB DAC", icon: nil, supportsAutoEQ: false)
        fixture.devices.outputDevices.append(reconnected)
        fixture.devices.onDeviceConnected?(reconnected.uid, reconnected.name)
        await fixture.settle()
        #expect(fixture.volume.defaultDeviceUID == fixture.chosen.uid)
        #expect(fixture.volume.writes.last == 404)
        fixture.engine.stop()
    }

    @Test("A deliberate choice in FineTune during wake supersedes the saved choice")
    func explicitChoiceWins() async {
        let fixture = WakeOutputFixture()
        fixture.engine.handleSystemWillSleep()
        await fixture.engine.handleSystemDidWake()
        #expect(fixture.engine.setDefaultOutputDevice(fixture.fallback.id))
        await fixture.settle()
        fixture.volume.externalDefault(fixture.hdmi)
        await fixture.settle()
        #expect(fixture.volume.defaultDeviceUID == fixture.fallback.uid)
        fixture.engine.stop()
    }

    @Test("Normal external output selection is respected after the wake settling window")
    func externalSelectionAfterSettling() async {
        let fixture = WakeOutputFixture()
        fixture.engine.handleSystemWillSleep()
        fixture.volume.externalDefault(fixture.hdmi)
        await fixture.engine.handleSystemDidWake()
        await fixture.settle()
        fixture.now = fixture.now.addingTimeInterval(6)
        fixture.volume.externalDefault(fixture.hdmi)
        await fixture.settle()
        #expect(fixture.volume.defaultDeviceUID == fixture.hdmi.uid)
        fixture.engine.stop()
    }

    @Test("Rebuilt default-following app taps use the restored output")
    func defaultAppRouting() async throws {
        let fixture = WakeOutputFixture()
        fixture.processes.activeApps = [fixture.app]
        fixture.engine.applyPersistedSettings()
        fixture.engine.handleSystemWillSleep()
        fixture.volume.externalDefault(fixture.hdmi)
        await fixture.engine.handleSystemDidWake()
        await fixture.settle()
        let tap = try #require(fixture.created.last)
        #expect(fixture.created.count == 2)
        #expect(tap.currentDeviceUIDs == [fixture.chosen.uid])
        #expect(fixture.engine.getDeviceUID(for: fixture.app) == fixture.chosen.uid)
        fixture.engine.stop()
    }

    @Test("An app explicitly routed to HDMI keeps its own route while the default returns to USB")
    func explicitAppRouting() async throws {
        let fixture = WakeOutputFixture()
        fixture.settings.setDeviceRouting(for: fixture.app.persistenceIdentifier, deviceUID: fixture.hdmi.uid)
        fixture.processes.activeApps = [fixture.app]
        fixture.engine.applyPersistedSettings()
        fixture.engine.handleSystemWillSleep()
        fixture.volume.externalDefault(fixture.hdmi)
        await fixture.engine.handleSystemDidWake()
        await fixture.settle()
        #expect(fixture.volume.defaultDeviceUID == fixture.chosen.uid)
        #expect(try #require(fixture.created.last).currentDeviceUIDs == [fixture.hdmi.uid])
        fixture.engine.stop()
    }

    @Test("A device that becomes alive without a reconnect notification is restored")
    func deviceBecomesAlive() async {
        let fixture = WakeOutputFixture()
        fixture.engine.handleSystemWillSleep()
        fixture.notAlive.insert(fixture.chosen.id)
        fixture.volume.externalDefault(fixture.hdmi)
        await fixture.engine.handleSystemDidWake()
        await fixture.settle()
        #expect(fixture.volume.defaultDeviceUID == fixture.fallback.uid)
        fixture.notAlive.remove(fixture.chosen.id)
        await fixture.waitUntilDefault(fixture.chosen.uid)
        #expect(fixture.volume.defaultDeviceUID == fixture.chosen.uid)
        fixture.engine.stop()
    }

    @Test("Transient failures setting the default are retried during wake")
    func failedWriteRetry() async {
        let fixture = WakeOutputFixture()
        fixture.engine.handleSystemWillSleep()
        fixture.volume.externalDefault(fixture.hdmi)
        fixture.volume.failuresRemaining = 2
        await fixture.engine.handleSystemDidWake()
        #expect(fixture.volume.defaultDeviceUID == fixture.hdmi.uid)
        await fixture.waitUntilDefault(fixture.chosen.uid)
        #expect(fixture.volume.defaultDeviceUID == fixture.chosen.uid)
        fixture.engine.stop()
    }

    @Test("Missing wake echoes cannot block a new external choice after the settling window")
    func missingEchoAfterSettling() async throws {
        let fixture = WakeOutputFixture()
        fixture.processes.activeApps = [fixture.app]
        fixture.engine.applyPersistedSettings()
        fixture.engine.handleSystemWillSleep()
        fixture.volume.externalDefault(fixture.hdmi)
        fixture.volume.deliversEchoes = false
        await fixture.engine.handleSystemDidWake()
        await fixture.settle()
        fixture.now = fixture.now.addingTimeInterval(6)
        fixture.volume.externalDefault(fixture.hdmi)
        await fixture.settle()
        #expect(try #require(fixture.created.last).currentDeviceUIDs == [fixture.hdmi.uid])
        fixture.engine.stop()
    }

    @Test("Stopping cancels pending wake restoration and ignores late device callbacks")
    func stopCancelsRestoration() async {
        let fixture = WakeOutputFixture()
        fixture.engine.handleSystemWillSleep()
        fixture.volume.externalDefault(fixture.hdmi)
        await fixture.engine.handleSystemDidWake()
        await fixture.settle()
        fixture.engine.stop()
        let writes = fixture.volume.writes.count
        fixture.volume.externalDefault(fixture.hdmi)
        fixture.devices.onDeviceConnected?(fixture.hdmi.uid, fixture.hdmi.name)
        try? await Task.sleep(for: .milliseconds(300))
        #expect(fixture.volume.writes.count == writes)
        #expect(fixture.volume.defaultDeviceUID == fixture.hdmi.uid)
    }

}

@MainActor
private final class WakeOutputFixture {
    let chosen = AudioDevice(id: 401, uid: "usb-dac", name: "USB DAC", icon: nil, supportsAutoEQ: false)
    let hdmi = AudioDevice(id: 402, uid: "hdmi-monitor", name: "HDMI Monitor", icon: nil, supportsAutoEQ: false)
    let fallback = AudioDevice(id: 403, uid: "built-in-speakers", name: "Speakers", icon: nil, supportsAutoEQ: false)
    let settings = SettingsManager(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    let devices = WakeDeviceProvider()
    let volume = WakeVolumeProvider()
    let processes = StubProcessMonitor()
    let app = AudioApp(id: 87654, processObjectIDs: [301], name: "Player", icon: NSImage(), bundleID: "test.wake-route")
    var created: [RecordingProcessTapController] = []
    var notAlive: Set<AudioDeviceID> = []
    var now = Date(timeIntervalSince1970: 100)
    private(set) var engine: AudioEngine!

    init() {
        devices.outputDevices = [chosen, hdmi, fallback]
        volume.devices = devices
        volume.defaultDeviceID = chosen.id
        volume.defaultDeviceUID = chosen.uid
        settings.appSettings.showDeviceDisconnectAlerts = false
        settings.setDevicePriorityOrder([chosen.uid, fallback.uid, hdmi.uid])
        let permission = AudioRecordingPermission()
        permission.status = .authorized
        engine = AudioEngine(permission: permission, settingsManager: settings,
            autoEQProfileManager: AutoEQProfileManager(), deviceProvider: devices,
            processMonitor: processes, deviceVolumeMonitor: volume,
            tapFactory: { [weak self] app, uids, _ in
                let tap = RecordingProcessTapController(app: app, deviceUIDs: uids)
                self?.created.append(tap)
                return tap
            },
            isAlive: { [weak self] in self?.notAlive.contains($0) == false }, recoveryClock: { [weak self] in self?.now ?? Date() },
            startMonitorsAutomatically: false)
    }

    func waitUntilDefault(_ uid: String) async {
        for _ in 0..<100 {
            if volume.defaultDeviceUID == uid { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func settle() async {
        for _ in 0..<30 { await Task.yield() }
    }
}

@MainActor
private final class WakeDeviceProvider: AudioDeviceProviding {
    var outputDevices: [AudioDevice] = []
    var inputDevices: [AudioDevice] = []
    var onDeviceDisconnected: ((String, String) -> Void)?
    var onDeviceConnected: ((String, String) -> Void)?
    var onInputDeviceDisconnected: ((String, String) -> Void)?
    var onInputDeviceConnected: ((String, String) -> Void)?
    func device(for uid: String) -> AudioDevice? { outputDevices.first { $0.uid == uid } }
    func inputDevice(for uid: String) -> AudioDevice? { nil }
    func start() {}
    func stop() {}
}

@MainActor
private final class WakeVolumeProvider: DeviceVolumeProviding {
    weak var devices: WakeDeviceProvider?
    var defaultDeviceID: AudioDeviceID = 0
    var defaultDeviceUID: String?
    var defaultInputDeviceUID: String?
    var volumes: [AudioDeviceID: Float] = [:]
    var muteStates: [AudioDeviceID: Bool] = [:]
    var onVolumeChanged: ((AudioDeviceID, Float) -> Void)?
    var onMuteChanged: ((AudioDeviceID, Bool) -> Void)?
    var onDefaultDeviceChanged: ((String) -> Void)?
    var onDefaultInputDeviceChanged: ((String) -> Void)?
    var writes: [AudioDeviceID] = []
    var failuresRemaining = 0
    var deliversEchoes = true

    func externalDefault(_ device: AudioDevice) {
        defaultDeviceID = device.id
        defaultDeviceUID = device.uid
        onDefaultDeviceChanged?(device.uid)
    }

    func setDefaultDevice(_ deviceID: AudioDeviceID) -> Bool {
        guard let device = devices?.outputDevices.first(where: { $0.id == deviceID }) else { return false }
        writes.append(deviceID)
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            return false
        }
        defaultDeviceID = device.id
        defaultDeviceUID = device.uid
        // HAL delivers the notification after the setter, so echo registration comes first.
        if deliversEchoes {
            Task { @MainActor [weak self] in self?.onDefaultDeviceChanged?(device.uid) }
        }
        return true
    }
    func setDefaultInputDevice(_ deviceID: AudioDeviceID) -> Bool { false }
    func setVolume(for deviceID: AudioDeviceID, to volume: Float) {}
    func setMute(for deviceID: AudioDeviceID, to muted: Bool) {}
    func outputVolumeBackend(for deviceID: AudioDeviceID) -> VolumeControlTier { .hardware }
    func autoDetectedOutputVolumeBackend(for deviceID: AudioDeviceID) -> VolumeControlTier { .hardware }
    func start() {}
    func stop() {}
}
