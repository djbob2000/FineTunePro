// FineTuneTests/PopoverHostTests.swift
import Testing
import Foundation
import AppKit
import SwiftUI
@testable import FineTune

@Suite("PopoverPositioner — computePosition()")
struct PopoverPositionerTests {
    private let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)

    @Test("Normal placement below and left-aligned")
    func normalBelowLeftAligned() {
        let panelSize = NSSize(width: 210, height: 100)
        let triggerFrame = NSRect(x: 100, y: 500, width: 50, height: 30)
        let pos = PopoverPositioner.computePosition(
            panelSize: panelSize,
            triggerFrame: triggerFrame,
            visibleFrame: screen
        )
        // Default targetX = triggerFrame.origin.x = 100
        // Default targetY = triggerFrame.origin.y - panelSize.height - 4 = 500 - 100 - 4 = 396
        #expect(pos.x == 100)
        #expect(pos.y == 396)
    }

    @Test("Overflowing panel right-aligns with its trigger")
    func rightAlignOnOverflow() {
        let panelSize = NSSize(width: 210, height: 100)
        // Trigger is at x: 1300. 1300 + 210 = 1510 which exceeds 1440.
        // The panel's right edge should stay aligned with the trigger at 1350.
        let triggerFrame = NSRect(x: 1300, y: 500, width: 50, height: 30)
        let pos = PopoverPositioner.computePosition(
            panelSize: panelSize,
            triggerFrame: triggerFrame,
            visibleFrame: screen
        )
        #expect(pos.x == 1140)
        #expect(pos.y == 396)
    }

    @Test("Clamp left edge of screen")
    func clampLeftEdge() {
        let panelSize = NSSize(width: 210, height: 100)
        // Trigger is at x: -50. -50 is less than 0.
        // Keep an 8-point margin inside the screen.
        let triggerFrame = NSRect(x: -50, y: 500, width: 50, height: 30)
        let pos = PopoverPositioner.computePosition(
            panelSize: panelSize,
            triggerFrame: triggerFrame,
            visibleFrame: screen
        )
        #expect(pos.x == 8)
        #expect(pos.y == 396)
    }

    @Test("Flip above trigger when extending below bottom edge")
    func flipAboveTrigger() {
        let panelSize = NSSize(width: 210, height: 100)
        // Trigger is close to bottom: y: 80.
        // Default targetY = 80 - 100 - 4 = -24 (extends below 0).
        // It should flip above: triggerFrame.maxY + 4 = 80 + 30 + 4 = 114.
        let triggerFrame = NSRect(x: 100, y: 80, width: 50, height: 30)
        let pos = PopoverPositioner.computePosition(
            panelSize: panelSize,
            triggerFrame: triggerFrame,
            visibleFrame: screen
        )
        #expect(pos.x == 100)
        #expect(pos.y == 114)
    }

    @Test("Clamp to bottom edge when it does not fit above either")
    func clampToBottomWhenItCannotFitAbove() {
        // screen height is 900. Let's make a huge panel: height 800.
        let panelSize = NSSize(width: 210, height: 800)
        // Trigger is at y: 300.
        // Default targetY = 300 - 800 - 4 = -504.
        // Flip targetY = (300 + 30) + 4 = 334.
        // But 334 + 800 = 1134 which exceeds 900.
        // Neither side fits, so keep an 8-point margin above the bottom edge.
        let triggerFrame = NSRect(x: 100, y: 300, width: 50, height: 30)
        let pos = PopoverPositioner.computePosition(
            panelSize: panelSize,
            triggerFrame: triggerFrame,
            visibleFrame: screen
        )
        #expect(pos.x == 100)
        #expect(pos.y == 8)
    }

    @Test("Right alignment still keeps the panel within the screen margin")
    func rightMargin() {
        let pos = PopoverPositioner.computePosition(
            panelSize: NSSize(width: 210, height: 100),
            triggerFrame: NSRect(x: 1430, y: 500, width: 50, height: 30),
            visibleFrame: screen
        )
        #expect(pos.x == 1222)
        #expect(pos.y == 396)
    }

    @Test("Placement respects margins on a screen with negative coordinates")
    func negativeScreenCoordinates() {
        let pos = PopoverPositioner.computePosition(
            panelSize: NSSize(width: 210, height: 100),
            triggerFrame: NSRect(x: -30, y: 0, width: 20, height: 30),
            visibleFrame: NSRect(x: -1440, y: -900, width: 1440, height: 900)
        )
        #expect(pos.x == -220)
        #expect(pos.y == -108)
    }

    @Test("A trigger above the visible frame keeps the panel below the top margin")
    func topMargin() {
        let pos = PopoverPositioner.computePosition(
            panelSize: NSSize(width: 210, height: 100),
            triggerFrame: NSRect(x: 100, y: 1000, width: 50, height: 30),
            visibleFrame: screen
        )
        #expect(pos.x == 100)
        #expect(pos.y == 792)
    }

    @Test("An oversized panel anchors to the lower left margin")
    func oversizedPanel() {
        let pos = PopoverPositioner.computePosition(
            panelSize: NSSize(width: 1600, height: 1000),
            triggerFrame: NSRect(x: 100, y: 500, width: 50, height: 30),
            visibleFrame: screen
        )
        #expect(pos.x == 8)
        #expect(pos.y == 8)
    }
}

@Suite("PopoverHost resize placement", .serialized)
@MainActor
struct PopoverHostResizeTests {
    @Test("Panel resize notifications keep growing content below its trigger")
    func asynchronousResizeRepositions() throws {
        let (window, trigger, coordinator) = try makePopover()
        defer {
            coordinator.dismissPanel()
            window.orderOut(nil)
        }
        let panel = try #require(coordinator.panel)
        let triggerFrame = window.convertToScreen(trigger.convert(trigger.bounds, to: nil))

        panel.setContentSize(NSSize(width: 180, height: 140))
        NotificationCenter.default.post(name: NSWindow.didResizeNotification, object: panel)

        #expect(panel.frame.maxY == triggerFrame.minY - 4)
        #expect(panel.frame.minX == triggerFrame.minX)
    }

    @Test("Resize placement recomputes the trigger after the parent window moves")
    func resizedPanelFollowsMovedTrigger() throws {
        let (window, trigger, coordinator) = try makePopover()
        defer {
            coordinator.dismissPanel()
            window.orderOut(nil)
        }
        let panel = try #require(coordinator.panel)
        window.setFrameOrigin(NSPoint(x: window.frame.minX + 80, y: window.frame.minY + 30))
        let triggerFrame = window.convertToScreen(trigger.convert(trigger.bounds, to: nil))

        panel.setContentSize(NSSize(width: 180, height: 140))
        NotificationCenter.default.post(name: NSWindow.didResizeNotification, object: panel)

        #expect(panel.frame.maxY == triggerFrame.minY - 4)
        #expect(panel.frame.minX == triggerFrame.minX)
    }

    private func makePopover() throws -> (NSWindow, NSView, PopoverHost<EmptyView>.Coordinator) {
        let screen = try #require(NSScreen.main)
        let window = NSWindow(
            contentRect: NSRect(x: screen.visibleFrame.minX + 100, y: screen.visibleFrame.midY,
                                width: 360, height: 200),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        let trigger = NSView(frame: NSRect(x: 20, y: 100, width: 40, height: 20))
        window.contentView?.addSubview(trigger)
        let coordinator = PopoverHost<EmptyView>.Coordinator(isPresented: .constant(true))
        coordinator.showPanel(
            from: trigger, content: { Color.clear.frame(width: 100, height: 40) },
            preferredColorScheme: nil, nsAppearance: nil
        )
        return (window, trigger, coordinator)
    }
}
