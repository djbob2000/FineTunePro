import AppKit
import Testing
@testable import FineTune

@Suite("URL volume percentages")
@MainActor
struct URLHandlerTests {
    @Test("URL percentages use the normal percentage scale for active and inactive apps",
          arguments: [(0, Float(0)), (10, 0.01), (20, 0.04), (30, 0.09), (50, 0.25), (100, 1)],
          [false, true])
    func percentageGain(percentAndGain: (Int, Float), useLogScale: Bool) throws {
        let (percent, expectedGain) = percentAndGain
        let engine = RecordingURLEngine()
        engine.settingsManager.appSettings.useLogScale = useLogScale
        let handler = URLHandler(audioEngine: engine)
        handler.handleURL(try #require(URL(string:
            "finetune://set-volumes?app=com.test.active&volume=\(percent)&app=com.test.inactive&volume=\(percent)"
        )))

        #expect(engine.activeVolumes.count == 1)
        #expect(engine.inactiveVolumes.count == 1)
        let activeGain = try #require(engine.activeVolumes["com.test.active"])
        let inactiveGain = try #require(engine.inactiveVolumes["com.test.inactive"])
        #expect(abs(activeGain - expectedGain) < 0.000001)
        #expect(abs(inactiveGain - expectedGain) < 0.000001)
    }

    @Test("Invalid percentages are skipped without losing subsequent valid pairs")
    func invalidPercentages() throws {
        let engine = RecordingURLEngine()
        URLHandler(audioEngine: engine).handleURL(try #require(URL(string:
            "finetune://set-volumes?app=negative&volume=-1&app=over&volume=101&app=text&volume=bad&app=com.test.active&volume=50"
        )))
        #expect(engine.inactiveVolumes.isEmpty)
        #expect(engine.activeVolumes == ["com.test.active": 0.25])
    }

    @Test("Set then step volume moves five normal percentage points even in dB mode",
          arguments: [("up", Float(0.3025)), ("down", 0.2025)], [false, true])
    func setThenStep(directionAndGain: (String, Float), useLogScale: Bool) throws {
        let (direction, expectedGain) = directionAndGain
        let engine = RecordingURLEngine()
        engine.settingsManager.appSettings.useLogScale = useLogScale
        let handler = URLHandler(audioEngine: engine)
        handler.handleURL(try #require(URL(string:
            "finetune://set-volumes?app=com.test.active&volume=50"
        )))
        handler.handleURL(try #require(URL(string:
            "finetune://step-volume?app=com.test.active&direction=\(direction)"
        )))
        let gain = try #require(engine.activeVolumes["com.test.active"])
        #expect(abs(gain - expectedGain) < 0.000001)
    }
}

/// CoreAudio is external to the URL contract; record the gains handed to its engine boundary.
@MainActor
private final class RecordingURLEngine: URLHandlerEngine {
    let settingsManager = SettingsManager(
        directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    )
    let apps = [AudioApp(id: 42424, processObjectIDs: [], name: "Test App", icon: NSImage(), bundleID: "com.test.active")]
    var activeVolumes: [String: Float] = [:]
    var inactiveVolumes: [String: Float] = [:]

    func setVolume(for app: AudioApp, to volume: Float) { activeVolumes[app.persistenceIdentifier] = volume }
    func getVolume(for app: AudioApp) -> Float { activeVolumes[app.persistenceIdentifier] ?? 1 }
    func setVolumeForInactive(identifier: String, to volume: Float) { inactiveVolumes[identifier] = volume }
    func setMute(for app: AudioApp, to muted: Bool) { Issue.record("Unexpected mute write") }
    func getMute(for app: AudioApp) -> Bool { false }
    func setDevice(for app: AudioApp, deviceUID: String?) { Issue.record("Unexpected routing write") }
    func setMuteForInactive(identifier: String, to muted: Bool) { Issue.record("Unexpected mute write") }
    func getMuteForInactive(identifier: String) -> Bool { false }
}
