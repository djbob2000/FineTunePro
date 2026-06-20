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
    
    @Test("Toggling loudness on hardware device adjusts system volume and updates filter gains instantly")
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
        
        // Allow tasks to run
        try await Task.sleep(nanoseconds: 50_000_000)
        
        // Volume should have increased to compensate for digital headroom drop immediately
        let volAfterEnable = fix.deviceVolume.volumes[fix.device.id] ?? 0.5
        #expect(volAfterEnable > 0.5, "volAfterEnable was \(volAfterEnable), expected > 0.5")
        
        let enableLoudnessEvents = tap.events.compactMap { event -> (enabled: Bool, gainScale: Float)? in
            if case let .updateLoudnessCompensation(_, enabled, _, gainScale) = event {
                return (enabled, gainScale)
            }
            return nil
        }
        #expect(!enableLoudnessEvents.isEmpty, "enableLoudnessEvents is empty. tap.events was \(tap.events)")
        // No intermediate states (e.g. 0.0 < gainScale < 1.0)
        let intermediateEnables = enableLoudnessEvents.filter { $0.gainScale > 0.0 && $0.gainScale < 1.0 }
        #expect(intermediateEnables.isEmpty, "Found intermediate enables: \(intermediateEnables)")
        
        // The final event must be fully enabled (gainScale == 1.0)
        #expect(enableLoudnessEvents.last?.enabled == true, "Last event enabled was \(String(describing: enableLoudnessEvents.last?.enabled)), expected true")
        #expect(enableLoudnessEvents.last?.gainScale == 1.0, "Last event gainScale was \(String(describing: enableLoudnessEvents.last?.gainScale)), expected 1.0")
        
        let offsetBeforeDisable = fix.engine.appliedLoudnessOffsets[fix.device.uid] ?? 0.0
        #expect(offsetBeforeDisable > 0.0, "offsetBeforeDisable was \(offsetBeforeDisable), expected > 0.0")
        
        tap.clearEvents()
        
        // 3. Disable loudness
        fix.engine.setLoudnessCompensationEnabled(for: fix.device.uid, enabled: false)
        
        // Allow tasks to run
        try await Task.sleep(nanoseconds: 50_000_000)
        
        // Volume should return back to original 0.5 immediately
        let volAfterDisable = fix.deviceVolume.volumes[fix.device.id] ?? 0.5
        #expect(abs(volAfterDisable - 0.5) < 0.001, "volAfterDisable was \(volAfterDisable), expected 0.5. tap.events was \(tap.events)")
        
        let disableLoudnessEvents = tap.events.compactMap { event -> (enabled: Bool, gainScale: Float)? in
            if case let .updateLoudnessCompensation(_, enabled, _, gainScale) = event {
                return (enabled, gainScale)
            }
            return nil
        }
        #expect(!disableLoudnessEvents.isEmpty, "disableLoudnessEvents is empty. tap.events was \(tap.events)")
        let intermediateDisables = disableLoudnessEvents.filter { $0.gainScale > 0.0 && $0.gainScale < 1.0 }
        #expect(intermediateDisables.isEmpty, "Found intermediate disables: \(intermediateDisables)")
        
        // The final event must be fully disabled (enabled == false, gainScale == 0.0)
        #expect(disableLoudnessEvents.last?.enabled == false, "Last event enabled was \(String(describing: disableLoudnessEvents.last?.enabled)), expected false")
        #expect(disableLoudnessEvents.last?.gainScale == 0.0, "Last event gainScale was \(String(describing: disableLoudnessEvents.last?.gainScale)), expected 0.0")
    }
    
    @Test("Toggling loudness on software device does NOT adjust system volume and updates filter gains instantly")
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
        
        // Allow tasks to run
        try await Task.sleep(nanoseconds: 50_000_000)
        
        // Volume must remain unchanged since software volume is handled in pipeline
        #expect(fix.deviceVolume.volumes[fix.device.id] == 0.5)
        
        let enableEvents = tap.events.compactMap { event -> Float? in
            if case let .updateLoudnessCompensation(_, true, _, gainScale) = event {
                return gainScale
            }
            return nil
        }
        // Filter scale events should show instant update to 1.0 without intermediate steps
        #expect(!enableEvents.isEmpty)
        #expect(!enableEvents.contains { $0 > 0.0 && $0 < 1.0 })
        #expect(enableEvents.last == 1.0)
        
        tap.clearEvents()
        
        // 3. Disable loudness
        fix.engine.setLoudnessCompensationEnabled(for: fix.device.uid, enabled: false)
        
        // Allow tasks to run
        try await Task.sleep(nanoseconds: 50_000_000)
        
        let disableEvents = tap.events.compactMap { event -> (enabled: Bool, gainScale: Float)? in
            if case let .updateLoudnessCompensation(_, enabled, _, gainScale) = event {
                return (enabled, gainScale)
            }
            return nil
        }
        #expect(!disableEvents.isEmpty)
        #expect(!disableEvents.contains { $0.gainScale > 0.0 && $0.gainScale < 1.0 })
        #expect(disableEvents.last?.enabled == false)
        #expect(disableEvents.last?.gainScale == 0.0)
    }

    @Test("Dynamic loudness offset converges to zero at 100% volume")
    func dynamicOffsetConvergesToZero() async throws {
        let fix = makeFixture(backend: .hardware)
        fix.engine.setDevice(for: fix.app, deviceUID: fix.device.uid)
        
        // 1. Enable loudness at 50% volume (0.5)
        fix.deviceVolume.volumes[fix.device.id] = 0.5
        fix.engine.setLoudnessCompensationEnabled(for: fix.device.uid, enabled: true)
        try await Task.sleep(nanoseconds: 10_000_000)
        
        // Verify that offset was computed and system volume was boosted
        let volAfterEnable = fix.deviceVolume.volumes[fix.device.id] ?? 0.5
        #expect(volAfterEnable > 0.5)
        
        // 2. Set hardware volume to 1.0 (representing dragging the slider to 100%)
        // Trigger the onVolumeChanged callback (mocking OS notification)
        fix.deviceVolume.volumes[fix.device.id] = 1.0
        fix.deviceVolume.onVolumeChanged?(fix.device.id, 1.0)
        try await Task.sleep(nanoseconds: 10_000_000)
        
        // Offset should have updated dynamically to 0.0, and DSP should be bypassed
        let tap = try #require(fix.lastTap())
        let loudnessEvents = tap.events.compactMap { event -> (enabled: Bool, volume: Float)? in
            if case let .updateLoudnessCompensation(vol, enabled, _, _) = event {
                return (enabled, vol)
            }
            return nil
        }
        
        #expect(!loudnessEvents.isEmpty)
        let lastEvent = try #require(loudnessEvents.last)
        #expect(lastEvent.enabled == false) // Bypassed
        #expect(abs(lastEvent.volume - 1.0) < 0.001) // Original volume is 1.0
    }
}
