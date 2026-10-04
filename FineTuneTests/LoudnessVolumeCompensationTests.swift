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
        let productionVolume: DeviceVolumeMonitor?
        let device: AudioDevice
        let app: AudioApp
        let lastTap: () -> RecordingProcessTapController?
    }
    
    private func makeFixture(backend: VolumeControlTier, useRealVolumeMonitor: Bool = false) -> Fixture {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let settings = SettingsManager(directory: tempDir)
        
        let deviceMonitor = MockAudioDeviceMonitor()
        let device = AudioDevice(
            // An absent HAL ID keeps these regressions independent of physical devices.
            id: useRealVolumeMonitor ? AudioDeviceID(0xFFFF_FF00) : AudioDeviceID(99),
            uid: "uid-test-device",
            name: "Test Output Device",
            icon: nil,
            supportsAutoEQ: false
        )
        deviceMonitor.addOutputDevice(device)
        
        let mockVolume = MockDeviceVolumeProviding(deviceMonitor: deviceMonitor)
        mockVolume.volumes[device.id] = 0.5
        mockVolume.overridesByUID[device.uid] = backend
        let productionVolume: DeviceVolumeMonitor?
        let volumeProvider: any DeviceVolumeProviding
        if useRealVolumeMonitor {
            settings.setDeviceVolumeTierOverride(for: device.uid, to: backend)
            settings.setSoftwareDeviceVolume(for: device.uid, to: 0.5)
            let monitor = DeviceVolumeMonitor(deviceMonitor: deviceMonitor, settingsManager: settings)
            monitor.refreshOutputDeviceStates()
            productionVolume = monitor
            volumeProvider = monitor
        } else {
            productionVolume = nil
            volumeProvider = mockVolume
        }
        
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
            deviceVolumeMonitor: volumeProvider,
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
            productionVolume: productionVolume,
            device: device,
            app: app,
            lastTap: { box.last }
        )
    }
    
    @Test("Boost changes refresh the loudness headroom without changing listening volume")
    func boostRefreshesLoudnessHeadroom() throws {
        let fix = makeFixture(backend: .hardware)
        fix.settings.setLoudnessCompensationEnabled(for: fix.device.uid, to: true)
        fix.engine.setDevice(for: fix.app, deviceUID: fix.device.uid)
        let tap = try #require(fix.lastTap())
        tap.clearEvents()
        fix.engine.setBoost(for: fix.app, to: .x2)
        #expect(tap.volume == 2)
        let updates = tap.events.compactMap { event -> Float? in
            if case let .updateLoudnessCompensation(volume, true, _, _, _, _, _, _, _) = event { return volume }
            return nil
        }
        #expect(updates.last == 0.5)
    }

    @Test("Software unmute refreshes headroom after the volume callback restores a muted gain")
    func softwareUnmuteRefreshesHeadroom() throws {
        let fix = makeFixture(backend: .software, useRealVolumeMonitor: true)
        fix.settings.setLoudnessCompensationEnabled(for: fix.device.uid, to: true)
        fix.engine.setDevice(for: fix.app, deviceUID: fix.device.uid)
        let tap = try #require(fix.lastTap())
        let monitor = try #require(fix.productionVolume)
        monitor.setMute(for: fix.device.id, to: true)
        #expect(tap.volume == 0)
        tap.clearEvents()
        monitor.setMute(for: fix.device.id, to: false)

        #expect(tap.volume == 0.5)
        #expect(tap.lastLoudnessDigitalVolume == 0.5)
        let updates = tap.events.compactMap { event -> Float? in
            if case let .updateLoudnessCompensation(volume, true, _, _, _, _, _, _, _) = event { return volume }
            return nil
        }
        #expect(updates.last == 0.5)
    }

    @Test("Backend overrides refresh active tap gain and loudness in both directions")
    func backendOverridesRefreshTapState() throws {
        let fix = makeFixture(backend: .hardware, useRealVolumeMonitor: true)
        fix.settings.setLoudnessCompensationEnabled(for: fix.device.uid, to: true)
        fix.settings.setSoftwareDeviceVolume(for: fix.device.uid, to: 0.25)
        fix.engine.setDevice(for: fix.app, deviceUID: fix.device.uid)
        let tap = try #require(fix.lastTap())
        let monitor = try #require(fix.productionVolume)
        #expect(tap.volume == 1)

        for backend in [VolumeControlTier.software, .hardware] {
            tap.clearEvents()
            // Match the detail sheet's real override entry point.
            fix.settings.setDeviceVolumeTierOverride(for: fix.device.uid, to: backend)
            monitor.applyTierOverrideChange(for: fix.device.id)
            #expect(tap.volume == (backend == .software ? 0.25 : 1))
            #expect(tap.lastLoudnessDigitalVolume == tap.volume)
            #expect(tap.currentDeviceVolume == monitor.volumes[fix.device.id])
            let updates = tap.events.compactMap { event -> Float? in
                if case let .updateLoudnessCompensation(volume, true, _, _, _, _, _, _, _) = event { return volume }
                return nil
            }
            #expect(updates.last == monitor.volumes[fix.device.id])
        }
    }

    @Test("Backend overrides preserve mute while refreshing tap gain and loudness")
    func mutedBackendOverridesRefreshTapState() throws {
        let fix = makeFixture(backend: .software, useRealVolumeMonitor: true)
        fix.settings.setLoudnessCompensationEnabled(for: fix.device.uid, to: true)
        fix.engine.setDevice(for: fix.app, deviceUID: fix.device.uid)
        let tap = try #require(fix.lastTap())
        let monitor = try #require(fix.productionVolume)
        monitor.setMute(for: fix.device.id, to: true)

        for backend in [VolumeControlTier.hardware, .software] {
            tap.clearEvents()
            fix.settings.setDeviceVolumeTierOverride(for: fix.device.uid, to: backend)
            monitor.applyTierOverrideChange(for: fix.device.id)
            #expect(tap.isDeviceMuted)
            #expect(monitor.muteStates[fix.device.id] == true)
            #expect(tap.volume == (backend == .software ? 0 : 1))
            #expect(tap.lastLoudnessDigitalVolume == tap.volume)
            let updates = tap.events.compactMap { event -> Float? in
                if case let .updateLoudnessCompensation(volume, true, _, _, _, _, _, _, _) = event { return volume }
                return nil
            }
            #expect(updates.last == 0)
        }
    }

    @Test("Toggling loudness on hardware device does NOT adjust hardware volume and updates filter gains instantly")
    func togglingLoudnessOnHardwareDeviceDoesNotAdjustHardwareVolume() async throws {
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
        
        // Volume should NOT have increased (remains 0.5)
        let volAfterEnable = fix.deviceVolume.volumes[fix.device.id] ?? 0.5
        #expect(volAfterEnable == 0.5, "volAfterEnable was \(volAfterEnable), expected 0.5")
        
        let enableLoudnessEvents = tap.events.compactMap { event -> (volume: Float, enabled: Bool, gainScale: Float)? in
            if case let .updateLoudnessCompensation(vol, enabled, _, gainScale, _, _, _, _, _) = event {
                return (vol, enabled, gainScale)
            }
            return nil
        }
        #expect(!enableLoudnessEvents.isEmpty)
        // No intermediate states (e.g. 0.0 < gainScale < 1.0)
        let intermediateEnables = enableLoudnessEvents.filter { $0.gainScale > 0.0 && $0.gainScale < 1.0 }
        #expect(intermediateEnables.isEmpty)
        
        // The final event must be fully enabled (gainScale == 1.0, volume == 0.5)
        #expect(enableLoudnessEvents.last?.enabled == true)
        #expect(enableLoudnessEvents.last?.gainScale == 1.0)
        #expect(enableLoudnessEvents.last?.volume == 0.5)
        
        tap.clearEvents()
        
        // 3. Disable loudness
        fix.engine.setLoudnessCompensationEnabled(for: fix.device.uid, enabled: false)
        
        // Allow tasks to run
        try await Task.sleep(nanoseconds: 50_000_000)
        
        // Volume should remain 0.5
        let volAfterDisable = fix.deviceVolume.volumes[fix.device.id] ?? 0.5
        #expect(volAfterDisable == 0.5)
        
        let disableLoudnessEvents = tap.events.compactMap { event -> (volume: Float, enabled: Bool, gainScale: Float)? in
            if case let .updateLoudnessCompensation(vol, enabled, _, gainScale, _, _, _, _, _) = event {
                return (vol, enabled, gainScale)
            }
            return nil
        }
        #expect(!disableLoudnessEvents.isEmpty)
        let intermediateDisables = disableLoudnessEvents.filter { $0.gainScale > 0.0 && $0.gainScale < 1.0 }
        #expect(intermediateDisables.isEmpty)
        
        // The final event must be fully disabled (enabled == false, gainScale == 0.0, volume == 0.5)
        #expect(disableLoudnessEvents.last?.enabled == false)
        #expect(disableLoudnessEvents.last?.gainScale == 0.0)
        #expect(disableLoudnessEvents.last?.volume == 0.5)
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
            if case let .updateLoudnessCompensation(_, true, _, gainScale, _, _, _, _, _) = event {
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
            if case let .updateLoudnessCompensation(_, enabled, _, gainScale, _, _, _, _, _) = event {
                return (enabled, gainScale)
            }
            return nil
        }
        #expect(!disableEvents.isEmpty)
        #expect(!disableEvents.contains { $0.gainScale > 0.0 && $0.gainScale < 1.0 })
        #expect(disableEvents.last?.enabled == false)
        #expect(disableEvents.last?.gainScale == 0.0)
    }


}
