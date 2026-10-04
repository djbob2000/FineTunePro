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

@Suite("URL popup actions", .serialized)
@MainActor
struct URLPopupActionTests {
    @Test("Toggle and open popup URLs deliver a click to the menu bar item when hidden",
          arguments: ["toggle-popup", "open-popup"])
    func showPopup(action: String) throws {
        let fixture = PopupURLFixture()
        defer { fixture.close() }
        fixture.handler.handleURL(try #require(URL(string: "finetune://\(action)")))

        let event = try #require(fixture.events.first)
        #expect(fixture.events.count == 1)
        #expect(event.windowNumber == fixture.statusItem.button?.window?.windowNumber)
        #expect(event.type == .leftMouseDown)
    }

    @Test("Open popup URL leaves a visible popup open")
    func openIsIdempotent() throws {
        let fixture = PopupURLFixture()
        defer { fixture.close() }
        fixture.popup.orderFront(nil)
        fixture.handler.handleURL(try #require(URL(string: "finetune://open-popup")))

        #expect(fixture.events.isEmpty)
        #expect(fixture.popup.isVisible)
    }

    @Test("Repeated open URLs enqueue one presentation while the first click is pending")
    func pendingOpenIsIdempotent() throws {
        let fixture = PopupURLFixture()
        defer { fixture.close() }
        let handler = fixture.handler
        let url = try #require(URL(string: "finetune://open-popup"))
        handler.handleURL(url)
        handler.handleURL(url)

        #expect(fixture.events.count == 1)
    }

    @Test("Close popup URL delivers a click only while the popup is visible")
    func closeIsIdempotent() throws {
        let fixture = PopupURLFixture()
        defer { fixture.close() }
        fixture.popup.orderFront(nil)
        let handler = fixture.handler
        let url = try #require(URL(string: "finetune://close-popup"))
        handler.handleURL(url)
        let event = try #require(fixture.events.first)
        #expect(event.windowNumber == fixture.statusItem.button?.window?.windowNumber)

        fixture.popup.orderOut(nil)
        fixture.events.removeAll()
        handler.handleURL(url)
        #expect(fixture.events.isEmpty)
    }

    @Test("A cold-launch URL waits for the menu-bar scene without queuing duplicate clicks")
    func coldLaunch() async throws {
        let fixture = PopupURLFixture()
        defer { fixture.close() }
        fixture.statusItemReady = false
        let url = try #require(URL(string: "finetune://open-popup"))
        fixture.handler.handleURL(url)
        fixture.handler.handleURL(url)
        #expect(fixture.events.isEmpty)
        fixture.statusItemReady = true
        try await Task.sleep(for: .milliseconds(180))
        #expect(fixture.events.count == 1)
    }

    @Test("A foreign URL scheme cannot open the popup")
    func foreignScheme() throws {
        let fixture = PopupURLFixture()
        defer { fixture.close() }
        fixture.handler.handleURL(try #require(URL(string: "other://toggle-popup")))
        #expect(fixture.events.isEmpty)
    }
}

/// Capture the OS event boundary while using a real isolated popup and status item.
@MainActor
private final class PopupURLFixture {
    let title = "FineTuneTest-URL-\(UUID().uuidString)"
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let popup = FluidMenuBarExtraURLTestPanel(
        contentRect: NSRect(x: 10, y: 10, width: 100, height: 100),
        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
    )
    var events: [NSEvent] = []
    var statusItemReady = true
    lazy var controller = MenuBarPopupController(
        accessibilityTitle: title,
        postEvent: { [weak self] in self?.events.append($0) },
        windows: { [weak self] in
            guard let self else { return [] }
            return [popup] + (statusItemReady ? [statusItem.button?.window].compactMap { $0 } : [])
        }
    )
    var handler: URLHandler { URLHandler(audioEngine: RecordingURLEngine(), popupController: controller) }

    init() {
        statusItem.button?.setAccessibilityTitle(title)
        _ = statusItem.button?.window?.windowNumber
        popup.title = title
        popup.isReleasedWhenClosed = false
    }

    func close() {
        controller.stop()
        popup.close()
        NSStatusBar.system.removeStatusItem(statusItem)
    }
}

private final class FluidMenuBarExtraURLTestPanel: NSPanel {}
