import Testing
import Foundation
import AudioToolbox
import AppKit
@testable import FineTune

@Suite("Loudness Hardware Volume Compensation Tests")
@MainActor
struct LoudnessVolumeCompensationTests {
    
    private final class TapBox {
        var last: RecordingProcessTapController?
    }
    
    private struct Fixture {
        let engine: AudioEngine
        let settings: SettingsManager
        let deviceMonitor: MockAudioDeviceMonitor
        let deviceVolume: MockDeviceVolumeProviding
        let device: AudioDevice
        let app: AudioApp
        let lastTap: () -> RecordingProcessTapController?
    }
    
    private func makeFixture(backend: VolumeControlTier) -> Fixture {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let settings = SettingsManager(directory: tempDir)
        
        let deviceMonitor = MockAudioDeviceMonitor()
        let device = AudioDevice(
            id: AudioDeviceID(99),
            uid: "uid-test-device",
            name: "Test Output Device",
            icon: nil,
            supportsAutoEQ: false
        )
        deviceMonitor.addOutputDevice(device)
        
        let mockVolume = MockDeviceVolumeProviding(deviceMonitor: deviceMonitor)
        mockVolume.volumes[device.id] = 0.5
        mockVolume.overridesByUID[device.uid] = backend
        
        let permission = AudioRecordingPermission()
        permission.status = .authorized
        
        let app = AudioApp(
            id: 12345,
            processObjectIDs: [],
            name: "TestApp",
            icon: NSImage(),
            bundleID: "com.test.loudness"
        )
        
        let processMonitor = StubProcessMonitor()
        processMonitor.activeApps = [app]
        
        let box = TapBox()
        
        let engine = AudioEngine(
            permission: permission,
            settingsManager: settings,
            autoEQProfileManager: AutoEQProfileManager(),
            deviceProvider: deviceMonitor,
            processMonitor: processMonitor,
            deviceVolumeMonitor: mockVolume,
            tapFactory: { app, uids, _ in
                let tap = RecordingProcessTapController(app: app, deviceUIDs: uids)
                box.last = tap
                return tap
            },
            startMonitorsAutomatically: false
        )
        
        return Fixture(
            engine: engine,
            settings: settings,
            deviceMonitor: deviceMonitor,
            deviceVolume: mockVolume,
            device: device,
            app: app,
            lastTap: { box.last }
        )
    }
    
    @Test("Toggling loudness on hardware device adjusts system volume and scales filter gains smoothly")
    func togglingLoudnessAdjustsHardwareVolume() async throws {
        let fix = makeFixture(backend: .hardware)
        
        // Setup tap for the app
        fix.engine.setDevice(for: fix.app, deviceUID: fix.device.uid)
        let tap = try #require(fix.lastTap())
        tap.clearEvents()
        
        // 1. Initial state
        #expect(fix.deviceVolume.volumes[fix.device.id] == 0.5)
        
        // 2. Enable loudness
        fix.engine.setLoudnessCompensationEnabled(for: fix.device.uid, enabled: true)
        
        // Wait for the 150ms volume ramp task to complete dynamically (up to 10 seconds)
        let enableStart = Date()
        var enableLoudnessEvents: [(enabled: Bool, gainScale: Float)] = []
        while Date().timeIntervalSince(enableStart) < 10.0 {
            enableLoudnessEvents = tap.events.compactMap { event -> (enabled: Bool, gainScale: Float)? in
                if case let .updateLoudnessCompensation(_, enabled, _, gainScale) = event {
                    return (enabled, gainScale)
                }
                return nil
            }
            if enableLoudnessEvents.last?.gainScale == 1.0 {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        
        // Volume should have increased to compensate for digital headroom drop
        let volAfterEnable = fix.deviceVolume.volumes[fix.device.id] ?? 0.5
        #expect(volAfterEnable > 0.5)
        
        #expect(!enableLoudnessEvents.isEmpty)
        // First updates should have intermediate gain scales (e.g. > 0.0 and < 1.0)
        let intermediateEnables = enableLoudnessEvents.filter { $0.gainScale > 0.0 && $0.gainScale < 1.0 }
        #expect(!intermediateEnables.isEmpty)
        
        // The final event must be fully enabled (gainScale == 1.0)
        #expect(enableLoudnessEvents.last?.enabled == true)
        #expect(enableLoudnessEvents.last?.gainScale == 1.0)
        
        tap.clearEvents()
        
        // 3. Disable loudness
        fix.engine.setLoudnessCompensationEnabled(for: fix.device.uid, enabled: false)
        
        // Wait for the 150ms volume ramp task to complete dynamically
        let disableStart = Date()
        var disableLoudnessEvents: [(enabled: Bool, gainScale: Float)] = []
        while Date().timeIntervalSince(disableStart) < 10.0 {
            disableLoudnessEvents = tap.events.compactMap { event -> (enabled: Bool, gainScale: Float)? in
                if case let .updateLoudnessCompensation(_, enabled, _, gainScale) = event {
                    return (enabled, gainScale)
                }
                return nil
            }
            if disableLoudnessEvents.last?.enabled == false && disableLoudnessEvents.last?.gainScale == 0.0 {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        
        // Volume should return back to original 0.5
        let volAfterDisable = fix.deviceVolume.volumes[fix.device.id] ?? 0.5
        #expect(abs(volAfterDisable - 0.5) < 0.001)
        
        #expect(!disableLoudnessEvents.isEmpty)
        let intermediateDisables = disableLoudnessEvents.filter { $0.gainScale > 0.0 && $0.gainScale < 1.0 }
        #expect(!intermediateDisables.isEmpty)
        
        // The final event must be fully disabled (enabled == false, gainScale == 0.0)
        #expect(disableLoudnessEvents.last?.enabled == false)
        #expect(disableLoudnessEvents.last?.gainScale == 0.0)
    }
    
    @Test("Toggling loudness on software device does NOT adjust system volume but still ramps filter gains smoothly")
    func togglingLoudnessDoesNotAdjustSoftwareVolume() async throws {
        let fix = makeFixture(backend: .software)
        
        // Setup tap for the app
        fix.engine.setDevice(for: fix.app, deviceUID: fix.device.uid)
        let tap = try #require(fix.lastTap())
        tap.clearEvents()
        
        // 1. Initial state
        #expect(fix.deviceVolume.volumes[fix.device.id] == 0.5)
        
        // 2. Enable loudness
        fix.engine.setLoudnessCompensationEnabled(for: fix.device.uid, enabled: true)
        
        // Wait for the 150ms transition to complete dynamically (up to 10 seconds)
        let enableStart = Date()
        var enableEvents: [Float] = []
        while Date().timeIntervalSince(enableStart) < 10.0 {
            enableEvents = tap.events.compactMap { event -> Float? in
                if case let .updateLoudnessCompensation(_, true, _, gainScale) = event {
                    return gainScale
                }
                return nil
            }
            if enableEvents.last == 1.0 {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        
        // Volume must remain unchanged since software volume is handled in pipeline
        #expect(fix.deviceVolume.volumes[fix.device.id] == 0.5)
        
        // Filter scale events should show linear transition from 0.0 to 1.0
        #expect(!enableEvents.isEmpty)
        #expect(enableEvents.contains { $0 > 0.0 && $0 < 1.0 })
        #expect(enableEvents.last == 1.0)
        
        tap.clearEvents()
        
        // 3. Disable loudness
        fix.engine.setLoudnessCompensationEnabled(for: fix.device.uid, enabled: false)
        
        // Wait for transition to complete dynamically
        let disableStart = Date()
        var disableEvents: [(enabled: Bool, gainScale: Float)] = []
        while Date().timeIntervalSince(disableStart) < 10.0 {
            disableEvents = tap.events.compactMap { event -> (enabled: Bool, gainScale: Float)? in
                if case let .updateLoudnessCompensation(_, enabled, _, gainScale) = event {
                    return (enabled, gainScale)
                }
                return nil
            }
            if disableEvents.last?.enabled == false && disableEvents.last?.gainScale == 0.0 {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        
        #expect(fix.deviceVolume.volumes[fix.device.id] == 0.5)
        
        #expect(!disableEvents.isEmpty)
        #expect(disableEvents.contains { $0.enabled && $0.gainScale > 0.0 && $0.gainScale < 1.0 })
        #expect(disableEvents.last?.enabled == false)
        #expect(disableEvents.last?.gainScale == 0.0)
    }
}
