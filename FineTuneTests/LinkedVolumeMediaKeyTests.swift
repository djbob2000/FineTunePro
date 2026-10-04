import AppKit
import AudioToolbox
import Foundation
import Testing
@testable import FineTune

@MainActor
private final class RecordingMediaKeyHUD: MediaKeyHUDPresenting {
    var presentations: [(slider: Double, mute: Bool, name: String)] = []
    var swallowed = 0
    func show(sliderFraction: Double, mute: Bool, deviceName: String) {
        presentations.append((sliderFraction, mute, deviceName))
    }
    func swallowObserved() { swallowed += 1 }
}

@Suite("Linked output media keys")
@MainActor
struct LinkedVolumeMediaKeyTests {
    private func makeMonitor(linkedUIDs: [String]? = ["hardware", "software", "ddc", "disconnected"]) throws -> (
        MediaKeyMonitor, MockDeviceVolumeProviding, RecordingMediaKeyHUD, SettingsManager
    ) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let linkedUIDs {
            let data = try JSONSerialization.data(withJSONObject: ["appSettings": ["linkedVolumeDeviceUIDs": linkedUIDs]])
            try data.write(to: directory.appendingPathComponent("settings.json"))
        }
        let settings = SettingsManager(directory: directory)
        let devices = MockAudioDeviceMonitor()
        for (id, uid) in [(UInt32(1), "hardware"), (2, "software"), (3, "ddc"), (4, "other")] {
            devices.addOutputDevice(AudioDevice(id: id, uid: uid, name: uid, icon: nil, supportsAutoEQ: false, transportType: .unknown))
        }
        let volume = MockDeviceVolumeProviding(deviceMonitor: devices)
        volume.defaultDeviceID = 1
        volume.defaultDeviceUID = "hardware"
        volume.volumes = [1: 0.5, 2: 0.25, 3: 0.75, 4: 0.8]
        volume.muteStates = [1: false, 2: false, 3: false, 4: false]
        volume.autoDetectedTiersByID = [1: .hardware, 2: .software, 3: .ddc, 4: .hardware]
        let engine = AudioEngine(
            permission: AudioRecordingPermission(), settingsManager: settings,
            autoEQProfileManager: AutoEQProfileManager(), deviceProvider: devices,
            deviceVolumeMonitor: volume, startMonitorsAutomatically: false
        )
        let hud = RecordingMediaKeyHUD()
        let monitor = MediaKeyMonitor(
            decoder: IOKitMediaKeyDecoder(), audioEngine: engine, settingsManager: settings,
            accessibility: MockAccessibilityTrustProviding(), hudController: hud,
            popupVisibility: PopupVisibilityService(), mediaKeyStatus: MediaKeyStatus()
        )
        return (monitor, volume, hud, settings)
    }

    @Test("A linked keypress steps each selected connected output in its own slider domain")
    func independentVolumeSteps() throws {
        let (monitor, volume, hud, _) = try makeMonitor()
        monitor.handle(.volumeUp(isRepeat: false))
        #expect(volume.volumes[1] == 0.5625)
        #expect(volume.volumes[2] == 0.31640625)
        #expect(volume.volumes[3] == 0.8125)
        #expect(volume.volumes[4] == 0.8)
        #expect(hud.presentations.count == 1)
        #expect(hud.presentations.first?.slider == 0.5625)
        #expect(hud.presentations.first?.name == "hardware")
    }

    @Test("An unmuted group member makes mute silence the entire linked group")
    func mixedGroupMutesTogether() throws {
        let (monitor, volume, hud, _) = try makeMonitor()
        volume.muteStates = [1: true, 2: false, 3: true, 4: false]
        monitor.handle(.muteToggle)
        #expect(volume.muteStates[1] == true)
        #expect(volume.muteStates[2] == true)
        #expect(volume.muteStates[3] == true)
        #expect(volume.muteStates[4] == false)
        #expect(hud.presentations.count == 1)
        #expect(hud.presentations.first?.mute == true)
        monitor.handle(.muteToggle)
        #expect(volume.muteStates[1] == false)
        #expect(volume.muteStates[2] == false)
        #expect(volume.muteStates[3] == false)
    }

    @Test("Disabled linking preserves default-output-only behavior")
    func disabledLinkingUsesDefaultOnly() throws {
        let (monitor, volume, hud, _) = try makeMonitor(linkedUIDs: nil)
        monitor.handle(.volumeDown(isRepeat: false))
        #expect(volume.volumes[1] == 0.4375)
        #expect(volume.volumes[2] == 0.25)
        #expect(volume.volumes[3] == 0.75)
        #expect(hud.presentations.count == 1)
    }

    @Test("A decoded key with no usable default output passes through without HUD")
    func unavailableDefaultPassesThrough() throws {
        let (monitor, volume, hud, _) = try makeMonitor()
        volume.defaultDeviceID = 0
        let event = try #require(NSEvent.otherEvent(
            with: .systemDefined, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, subtype: 8, data1: 0x0A00, data2: 0
        )?.cgEvent)
        #expect(monitor.processSystemDefined(event) == false)
        #expect(hud.swallowed == 0)
        #expect(hud.presentations.isEmpty)
        #expect(volume.volumes[2] == 0.25)
    }

    @Test("A valid output ID without an observed volume passes through rather than stepping from zero")
    func missingVolumePassesThrough() throws {
        let (monitor, volume, hud, _) = try makeMonitor()
        volume.volumes.removeValue(forKey: 1)
        let event = try #require(NSEvent.otherEvent(
            with: .systemDefined, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, subtype: 8, data1: 0x0A00, data2: 0
        )?.cgEvent)
        #expect(monitor.processSystemDefined(event) == false)
        #expect(hud.swallowed == 0)
        #expect(volume.volumes[1] == nil)
    }

    @Test("Extra-Fine repeats accumulate below ten percent without a stale software-volume floor")
    func extraFineRepeatsAccumulate() throws {
        let (monitor, volume, hud, settings) = try makeMonitor()
        settings.appSettings.volumeHotkeyStep = .extraFine
        volume.volumes = [1: 0, 2: 0, 3: 0, 4: 0.8]
        for _ in 0..<4 {
            // Admit the DDC repeat; hardware/software are never throttled.
            monitor.lastDDCRepeatTime = nil
            monitor.handle(.volumeUp(isRepeat: true))
        }
        #expect(volume.volumes[1] == 0.0625)
        #expect(volume.volumes[2] == 0.00390625)
        #expect(volume.volumes[3] == 0.0625)
        #expect(hud.presentations.count == 4)
        for _ in 0..<4 {
            monitor.lastDDCRepeatTime = nil
            monitor.handle(.volumeDown(isRepeat: true))
        }
        #expect(volume.volumes[1] == 0)
        #expect(volume.volumes[2] == 0)
        #expect(volume.volumes[3] == 0)
        #expect(volume.muteStates[1] == true)
        #expect(volume.muteStates[2] == true)
        #expect(volume.muteStates[3] == true)
    }

    @Test("Rapid linked repeats throttle DDC while hardware and software continue")
    func ddcDoesNotThrottleOtherBackends() throws {
        let (monitor, volume, _, _) = try makeMonitor()
        monitor.handle(.volumeUp(isRepeat: true))
        monitor.handle(.volumeUp(isRepeat: true))
        #expect(volume.volumes[1] == 0.625)
        #expect(volume.volumes[2] == 0.390625)
        #expect(volume.volumes[3] == 0.8125)
    }
}
