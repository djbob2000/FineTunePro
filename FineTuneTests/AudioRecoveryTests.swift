import AppKit
import AudioToolbox
import Foundation
import Testing
@testable import FineTune

@Suite("Audio recovery lifecycle")
@MainActor
struct AudioRecoveryTests {
    @Test("Registered paused clients receive saved gain before their first playback")
    func preparesPausedClient() throws {
        let fixture = RecoveryFixture()
        fixture.monitor.capturableApps = [fixture.app]
        fixture.settings.setVolume(for: fixture.app.persistenceIdentifier, to: 0.24)

        fixture.engine.applyPersistedSettings()

        let tap = try #require(fixture.created.first)
        #expect(tap.volumeAtActivation == 0.24)
        #expect(fixture.engine.apps.isEmpty)
        fixture.engine.stop()
    }

    @Test("Process changes during teardown wait for it and the replacement captures the latest clients")
    func processGrowthDuringTeardown() async throws {
        let fixture = RecoveryFixture()
        fixture.monitor.activeApps = [fixture.app]
        fixture.monitor.capturableApps = [fixture.app]
        fixture.engine.applyPersistedSettings()
        let first = try #require(fixture.created.first)
        first.holdTeardown = true

        fixture.monitor.publish(fixture.appWithObjects([101, 102]))
        await first.waitForTeardown()
        fixture.monitor.publish(fixture.appWithObjects([101, 102, 103]))

        #expect(fixture.created.count == 1)
        first.finishTeardown()
        await fixture.waitForCreatedCount(2)
        #expect(fixture.created.last?.app.processObjectIDs == [101, 102, 103])
        #expect(fixture.created.count == 2)
        fixture.engine.stop()
    }

    @Test("Stopping during recovery cannot resurrect a tap after teardown completes")
    func stopCancelsRecovery() async throws {
        let fixture = RecoveryFixture()
        fixture.monitor.activeApps = [fixture.app]
        fixture.monitor.capturableApps = [fixture.app]
        fixture.engine.applyPersistedSettings()
        let first = try #require(fixture.created.first)
        first.holdTeardown = true

        fixture.monitor.publish(fixture.appWithObjects([101, 102]))
        await first.waitForTeardown()
        fixture.engine.stop()
        first.finishTeardown()
        for _ in 0..<20 { await Task.yield() }

        #expect(fixture.created.count == 1)
    }

    @Test("Clients appearing during replacement activation trigger another reconcile pass")
    func growthDuringActivation() async throws {
        let fixture = RecoveryFixture()
        fixture.monitor.activeApps = [fixture.app]
        fixture.monitor.capturableApps = [fixture.app]
        fixture.engine.applyPersistedSettings()
        fixture.onNextActivation = {
            fixture.monitor.publish(fixture.appWithObjects([101, 102, 103]))
        }

        fixture.monitor.publish(fixture.appWithObjects([101, 102]))
        await fixture.waitForCreatedCount(3)

        #expect(fixture.created.last?.app.processObjectIDs == [101, 102, 103])
        #expect(fixture.created.count == 3)
        #expect(fixture.created.dropLast().allSatisfy { $0.invalidated })
        fixture.engine.stop()
    }

    @Test("Shutdown reentered during activation invalidates the unfinished controller")
    func stopDuringActivation() {
        let fixture = RecoveryFixture()
        fixture.monitor.capturableApps = [fixture.app]
        fixture.onNextActivation = { fixture.engine.stop() }
        fixture.engine.applyPersistedSettings()
        #expect(fixture.created.count == 1)
        #expect(fixture.created.first?.invalidated == true)
    }

    @Test("A paused prepared tap follows a new system output before playback resumes")
    func pausedDefaultRouting() async {
        let fixture = RecoveryFixture()
        fixture.monitor.capturableApps = [fixture.app]
        fixture.engine.applyPersistedSettings()
        fixture.devices.addOutputDevice(AudioDevice(id: 78, uid: "other-output", name: "Other", icon: nil, supportsAutoEQ: false))
        fixture.volumes.defaultDeviceUID = "other-output"
        fixture.volumes.onDefaultDeviceChanged?("other-output")
        for _ in 0..<30 { await Task.yield() }
        #expect(fixture.created.first?.currentDeviceUIDs == ["other-output"])
        fixture.engine.stop()
    }

    @Test("Three missed callbacks recover a never-rendered tap with a cooldown")
    func healthRecoveryCooldown() async {
        let fixture = RecoveryFixture()
        fixture.monitor.activeApps = [fixture.app]
        fixture.monitor.capturableApps = [fixture.app]
        fixture.engine.applyPersistedSettings()
        await fixture.engine.checkTapHealth()
        await fixture.engine.checkTapHealth()
        #expect(fixture.created.count == 1)
        await fixture.engine.checkTapHealth()
        #expect(fixture.created.count == 2)
        for _ in 0..<5 { await fixture.engine.checkTapHealth() }
        #expect(fixture.created.count == 2)
        fixture.now = fixture.now.addingTimeInterval(21)
        for _ in 0..<3 { await fixture.engine.checkTapHealth() }
        #expect(fixture.created.count == 3)
        fixture.engine.stop()
    }

    @Test("Failed activation retries after its backoff even with an unchanged process snapshot")
    func failedActivationRetry() async {
        let fixture = RecoveryFixture()
        fixture.failNextActivation = true
        fixture.monitor.capturableApps = [fixture.app]
        fixture.engine.applyPersistedSettings()
        await fixture.engine.checkTapHealth()
        #expect(fixture.created.count == 1)
        fixture.now = fixture.now.addingTimeInterval(6)
        await fixture.engine.checkTapHealth()
        #expect(fixture.created.count == 2)
        fixture.engine.stop()
    }

    @Test("Sleep during teardown leaves the client eligible for wake activation")
    func sleepDuringRecovery() async throws {
        let fixture = RecoveryFixture()
        fixture.monitor.capturableApps = [fixture.app]
        fixture.engine.applyPersistedSettings()
        let first = try #require(fixture.created.first)
        first.holdTeardown = true
        fixture.monitor.publish(fixture.appWithObjects([101, 102]))
        await first.waitForTeardown()
        fixture.engine.handleSystemWillSleep()
        first.finishTeardown()
        for _ in 0..<30 { await Task.yield() }
        await fixture.engine.handleSystemDidWake()
        #expect(fixture.created.count == 2)
        #expect(fixture.created.last?.app.processObjectIDs == [101, 102])
        fixture.engine.stop()
    }

    @Test("Wake rebuilds paused clients and refreshes the process snapshot")
    func wakeRecovery() async {
        let fixture = RecoveryFixture()
        fixture.monitor.capturableApps = [fixture.app]
        fixture.engine.applyPersistedSettings()
        fixture.engine.handleSystemWillSleep()
        await fixture.engine.checkTapHealth()
        #expect(fixture.created.count == 1)
        await fixture.engine.handleSystemDidWake()
        #expect(fixture.created.count == 2)
        #expect(fixture.created.first?.invalidated == true)
        #expect(fixture.monitor.refreshCount == 1)
        fixture.engine.stop()
    }

    @Test("Settings reset clears correction on every mirrored output")
    func resetMirroredCorrection() throws {
        let fixture = RecoveryFixture()
        fixture.devices.addOutputDevice(AudioDevice(id: 78, uid: "other-output", name: "Other", icon: nil, supportsAutoEQ: false))
        fixture.settings.setDeviceSelectionMode(for: fixture.app.persistenceIdentifier, to: .multi)
        fixture.settings.setSelectedDeviceUIDs(for: fixture.app.persistenceIdentifier, to: ["test-output", "other-output"])
        fixture.monitor.capturableApps = [fixture.app]
        fixture.engine.applyPersistedSettings()
        let tap = try #require(fixture.created.first)
        tap.clearedProfileUIDs.removeAll()
        fixture.engine.handleSettingsReset()
        #expect(tap.clearedProfileUIDs == ["test-output", "other-output"])
        fixture.engine.stop()
    }

    @Test("A global Airwave processor bypasses capture to avoid retapping its own mix")
    func airwaveBypass() {
        let fixture = RecoveryFixture()
        let processor = AudioApp(id: 98766, processObjectIDs: [202], name: "Airwave", icon: NSImage(),
            bundleID: "com.southneuhof.Airwave")
        fixture.monitor.capturableApps = [fixture.app, processor]
        fixture.engine.applyPersistedSettings()
        fixture.engine.setVolume(for: processor, to: 0.5)
        #expect(fixture.created.map(\.app.id) == [fixture.app.id])
        fixture.engine.stop()
    }

    @Test("Output rate changes rebuild only affected taps and failures fall back to replacement")
    func outputRateRecovery() async {
        let fixture = RecoveryFixture()
        fixture.monitor.capturableApps = [fixture.app]
        fixture.engine.applyPersistedSettings()
        await fixture.engine.handleOutputDeviceSampleRateChanged(uid: "unrelated", newRate: 44100)
        #expect(fixture.created.first?.rateRebuilds == 0)
        await fixture.engine.handleOutputDeviceSampleRateChanged(uid: "test-output", newRate: 44100)
        #expect(fixture.created.first?.rateRebuilds == 1)
        fixture.created.first?.failRateRebuild = true
        await fixture.engine.handleOutputDeviceSampleRateChanged(uid: "test-output", newRate: 48000)
        #expect(fixture.created.count == 2)
        #expect(fixture.created.first?.invalidated == true)
        fixture.engine.stop()
    }

}

@MainActor
private final class RecoveryProcessMonitor: AudioProcessMonitoring {
    var activeApps: [AudioApp] = []
    var capturableApps: [AudioApp] = []
    var onAppsChanged: (([AudioApp]) -> Void)?
    var onCapturableAppsChanged: (([AudioApp]) -> Void)?
    func start() {}
    func stop() {}
    var refreshCount = 0
    func refreshNow() { refreshCount += 1 }

    func publish(_ app: AudioApp) {
        activeApps = [app]
        capturableApps = [app]
        onCapturableAppsChanged?(capturableApps)
        onAppsChanged?(activeApps)
    }
}

@MainActor
private final class RecoveryFixture {
    let settings: SettingsManager
    let monitor = RecoveryProcessMonitor()
    let app = AudioApp(id: 98765, processObjectIDs: [101], name: "Player", icon: NSImage(), bundleID: "test.recovery")
    var created: [RecoveryTap] = []
    let devices = MockAudioDeviceMonitor()
    var volumes: MockDeviceVolumeProviding!
    var now = Date(timeIntervalSince1970: 100)
    var failNextActivation = false
    var onNextActivation: (() -> Void)?
    private(set) var engine: AudioEngine!

    init() {
        settings = SettingsManager(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        devices.addOutputDevice(AudioDevice(id: 77, uid: "test-output", name: "Output", icon: nil, supportsAutoEQ: false))
        volumes = MockDeviceVolumeProviding(deviceMonitor: devices)
        volumes.defaultDeviceUID = "test-output"
        let permission = AudioRecordingPermission()
        permission.status = .authorized
        engine = AudioEngine(
            permission: permission,
            settingsManager: settings,
            autoEQProfileManager: AutoEQProfileManager(),
            deviceProvider: devices,
            processMonitor: monitor,
            deviceVolumeMonitor: volumes,
            tapFactory: { [weak self] app, uids, _ in
                let tap = RecoveryTap(app: app, deviceUIDs: uids)
                tap.onActivate = self?.onNextActivation
                tap.failActivation = self?.failNextActivation ?? false
                self?.failNextActivation = false
                self?.onNextActivation = nil
                self?.created.append(tap)
                return tap
            },
            isAlive: { _ in true },
            recoveryClock: { [weak self] in self?.now ?? Date() },
            startMonitorsAutomatically: false
        )
    }

    func appWithObjects(_ objects: [AudioObjectID]) -> AudioApp {
        AudioApp(id: app.id, processObjectIDs: objects, name: app.name, icon: app.icon, bundleID: app.bundleID)
    }

    func waitForCreatedCount(_ count: Int) async {
        for _ in 0..<100 where created.count < count { await Task.yield() }
    }
}

@MainActor
private final class RecoveryTap: ProcessTapControlling {
    let app: AudioApp
    var volume: Float = 1
    var isMuted = false
    var currentDeviceVolume: Float = 1
    var isDeviceMuted = false
    var audioLevel: Float = 0
    var outputAudioLevel: Float = 0
    var outputChannelLevels: [Float] = [0]
    var limiterIntensity: Float = 0
    var currentDeviceUIDs: [String]
    var currentDeviceUID: String? { currentDeviceUIDs.first }
    var tapSourceDeviceUID: String?
    var volumeAtActivation: Float?
    var clearedProfileUIDs: Set<String> = []
    var invalidated = false
    var failActivation = false
    var failRateRebuild = false
    var rateRebuilds = 0
    var holdTeardown = false
    var onActivate: (() -> Void)?
    private var teardownStarted = false
    private var teardownContinuation: CheckedContinuation<Void, Never>?

    init(app: AudioApp, deviceUIDs: [String]) {
        self.app = app
        currentDeviceUIDs = deviceUIDs
    }

    func activate(initial: TapInitialState) throws {
        volumeAtActivation = volume
        onActivate?()
        if failActivation { throw RecoveryTestError.unavailable }
    }
    func invalidate() { invalidated = true }
    func invalidateAsync() async {
        invalidated = true
        teardownStarted = true
        if holdTeardown { await withCheckedContinuation { teardownContinuation = $0 } }
    }
    func waitForTeardown() async {
        for _ in 0..<100 where !teardownStarted { await Task.yield() }
        #expect(teardownStarted)
    }
    func finishTeardown() { teardownContinuation?.resume(); teardownContinuation = nil }
    func updateEQSettings(_ settings: EQSettings) {}
    func updateAutoEQProfile(_ profile: AutoEQProfile?) {}
    func updateAutoEQProfile(_ profile: AutoEQProfile?, for deviceUID: String) {
        if profile == nil { clearedProfileUIDs.insert(deviceUID) }
    }
    func setAutoEQPreampEnabled(_ enabled: Bool) {}
    func updateLoudnessCompensation(volume: Float, enabled: Bool, referencePhon: Double, maxDB: Double, gainScale: Float, bassCrossover: Double, trebleCrossover: Double, trebleGainScale: Float, bassExciterWet: Float, bassLinearWet: Float) {}
    func updateLoudnessEqualization(_ settings: LoudnessEqualizerSettings) {}
    func switchDevice(to newDeviceUID: String, preferredTapSourceDeviceUID: String?, sourceDeviceDead: Bool) async throws { currentDeviceUIDs = [newDeviceUID] }
    func updateDevices(to newDeviceUIDs: [String], preferredTapSourceDeviceUID: String?, sourceDeviceDead: Bool) async throws { currentDeviceUIDs = newDeviceUIDs }
    func hasRecentAudioCallback(within seconds: Double) -> Bool { false }
    func isHealthCheckEligible(minActiveSeconds: Double) -> Bool { true }
    func recreateForOutputRateChange() async throws {
        rateRebuilds += 1
        if failRateRebuild { throw RecoveryTestError.unavailable }
    }
    func updateAggregateBufferFrameSize(targetUIDs: [String]?) {}
}

private enum RecoveryTestError: Error { case unavailable }
