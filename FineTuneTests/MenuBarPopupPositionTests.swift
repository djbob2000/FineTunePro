import AppKit
import Testing
@testable import FineTune

@Suite("Popup position persistence")
struct MenuBarPopupPositionPersistenceTests {
    @Test("Existing settings default the popup position to follow the icon")
    func missingPositionUsesIcon() throws {
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        let data = try JSONEncoder().encode(decoded)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["popupPosition"] as? String == "followIcon")
    }

    @Test("A chosen popup position survives loading and saving settings", arguments: ["topLeft", "topRight"])
    func positionSurvivesSettingsRoundTrip(position: String) throws {
        let data = Data("{\"popupPosition\":\"\(position)\"}".utf8)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        let encoded = try JSONEncoder().encode(decoded)
        let json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(json["popupPosition"] as? String == position)
    }
}

@Suite("Popup position geometry")
struct MenuBarPopupPositionGeometryTests {
    private let visible = NSRect(x: -1440, y: 100, width: 1440, height: 876)
    private let icon = NSRect(x: -600, y: 976, width: 30, height: 24)

    @Test("Top left uses the menu bar display's visible origin")
    func leftOnSecondaryDisplay() {
        let frame = MenuBarPopupPosition.topLeft.frame(
            size: NSSize(width: 510, height: 600), statusItemFrame: icon, visibleFrame: visible
        )
        #expect(frame == NSRect(x: -1428, y: 364, width: 510, height: 600))
    }

    @Test("Top right keeps its edges anchored after the popup grows")
    func rightResize() {
        let before = MenuBarPopupPosition.topRight.frame(
            size: NSSize(width: 470, height: 400), statusItemFrame: icon, visibleFrame: visible
        )
        let after = MenuBarPopupPosition.topRight.frame(
            size: NSSize(width: 560, height: 760), statusItemFrame: icon, visibleFrame: visible
        )
        #expect(before == NSRect(x: -482, y: 564, width: 470, height: 400))
        #expect(after == NSRect(x: -572, y: 204, width: 560, height: 760))
    }

    @Test("Follow icon retains FluidMenuBarExtra's default left alignment")
    func followsIcon() {
        let frame = MenuBarPopupPosition.followIcon.frame(
            size: NSSize(width: 510, height: 600), statusItemFrame: icon, visibleFrame: visible
        )
        #expect(frame == NSRect(x: -602, y: 376, width: 510, height: 600))
    }

    @Test("Follow icon reverses alignment when the popup would cross the right edge")
    func followIconNearEdge() {
        let frame = MenuBarPopupPosition.followIcon.frame(
            size: NSSize(width: 510, height: 600),
            statusItemFrame: NSRect(x: -100, y: 976, width: 30, height: 24), visibleFrame: visible
        )
        #expect(frame == NSRect(x: -578, y: 376, width: 510, height: 600))
    }

    @Test("An oversized popup keeps its top edge visible without altering content size")
    func oversizedKeepsTopEdge() {
        let frame = MenuBarPopupPosition.topRight.frame(
            size: NSSize(width: 1600, height: 1000), statusItemFrame: icon, visibleFrame: visible
        )
        #expect(frame == NSRect(x: -1440, y: -24, width: 1600, height: 1000))
    }
}

@Suite("Popup position window lifecycle", .serialized)
@MainActor
struct MenuBarPopupPositionerTests {
    @Test("Show and resize notifications keep only the popup in its chosen corner")
    func popupShowAndResize() async {
        let fixture = PopupPositionFixture()
        defer { fixture.stop() }
        fixture.positioner.start()
        fixture.popup.orderFront(nil)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: fixture.popup)
        await fixture.settle()
        #expect(fixture.popup.frame == NSRect(x: 678, y: 478, width: 510, height: 300))

        fixture.popup.setFrame(NSRect(x: 100, y: 100, width: 560, height: 500), display: false)
        await fixture.settle()
        #expect(fixture.popup.frame == NSRect(x: 628, y: 278, width: 560, height: 500))

        let settingsWindow = PopupPositionFixture.panel()
        settingsWindow.orderFront(nil)
        defer { settingsWindow.close() }
        let original = settingsWindow.frame
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: settingsWindow)
        NotificationCenter.default.post(name: NSWindow.didResizeNotification, object: settingsWindow)
        await fixture.settle()
        #expect(settingsWindow.frame == original)
    }

    @Test("Repeated position notifications settle without endless corrective moves")
    func notificationsSettle() async {
        let fixture = PopupPositionFixture()
        defer { fixture.stop() }
        fixture.popup.orderFront(nil)
        var moves = 0
        let token = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: fixture.popup, queue: .main
        ) { _ in moves += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        fixture.positioner.start()
        for _ in 0..<10 {
            NotificationCenter.default.post(name: NSWindow.didMoveNotification, object: fixture.popup)
        }
        await fixture.settle()
        #expect(fixture.popup.frame.origin == NSPoint(x: 678, y: 478))
        #expect(moves <= 12) // Ten inputs and at most two corrective AppKit moves.
        let settledMoves = moves
        await fixture.settle()
        #expect(moves == settledMoves)
    }

    @Test("Changing the preference repositions a visible popup and restoring follow icon restores its anchor")
    func changePosition() async {
        let fixture = PopupPositionFixture()
        defer { fixture.stop() }
        fixture.positioner.start()
        fixture.popup.orderFront(nil)
        fixture.positioner.reposition()
        await fixture.settle()
        fixture.position = .topLeft
        fixture.positioner.reposition()
        await fixture.settle()
        #expect(fixture.popup.frame.origin == NSPoint(x: 12, y: 478))

        fixture.position = .followIcon
        fixture.positioner.reposition()
        await fixture.settle()
        #expect(fixture.popup.frame.origin == NSPoint(x: 598, y: 490))
    }
}

@MainActor
private final class PopupPositionFixture {
    let popup = panel()
    var position: MenuBarPopupPosition = .topRight
    lazy var positioner = MenuBarPopupPositioner(
        position: { [weak self] in self?.position ?? .followIcon },
        popupWindow: { [weak self] in self?.popup },
        statusItemFrame: { NSRect(x: 600, y: 790, width: 30, height: 24) },
        visibleFrame: { NSRect(x: 0, y: 0, width: 1200, height: 790) }
    )

    static func panel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 100, y: 100, width: 510, height: 300),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        panel.isReleasedWhenClosed = false
        return panel
    }

    func stop() {
        positioner.stop()
        popup.close()
    }

    func settle() async {
        try? await Task.sleep(for: .milliseconds(20))
    }
}
