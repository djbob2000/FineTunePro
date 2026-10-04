import AppKit
import Foundation
import Testing
@testable import FineTune

@Suite("System input selection")
@MainActor
struct InputSelectionTests {
    @Test("A settled System Settings input selection becomes the new locked preference")
    func manualInputSelection() async {
        let settings = SettingsManager(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        settings.appSettings.lockInputDevice = true
        settings.setLockedInputDeviceUID("old-mic")
        settings.setPreferredInputDeviceUID("old-mic")
        let devices = MockAudioDeviceMonitor()
        let microphone = AudioDevice(id: 102, uid: "new-mic", name: "USB Mic", icon: nil, supportsAutoEQ: false)
        devices.inputDevices = [microphone]
        devices.addOutputDevice(microphone)
        let volumes = MockDeviceVolumeProviding(deviceMonitor: devices)
        volumes.defaultInputDeviceUID = "new-mic"
        let engine = AudioEngine(permission: AudioRecordingPermission(), settingsManager: settings,
            autoEQProfileManager: AutoEQProfileManager(), deviceProvider: devices,
            deviceVolumeMonitor: volumes, startMonitorsAutomatically: false)
        volumes.onDefaultInputDeviceChanged?("new-mic")
        for _ in 0..<20 { await Task.yield() }
        #expect(settings.lockedInputDeviceUID == "new-mic")
        #expect(settings.preferredInputDeviceUID == "new-mic")
        engine.stop()
    }
}
