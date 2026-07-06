// FineTuneTests/PopoverHostTests.swift
import Testing
import Foundation
import AppKit
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

    @Test("Clamp right edge of screen")
    func clampRightEdge() {
        let panelSize = NSSize(width: 210, height: 100)
        // Trigger is at x: 1300. 1300 + 210 = 1510 which exceeds 1440.
        // It should shift left to: 1440 - 210 = 1230.
        let triggerFrame = NSRect(x: 1300, y: 500, width: 50, height: 30)
        let pos = PopoverPositioner.computePosition(
            panelSize: panelSize,
            triggerFrame: triggerFrame,
            visibleFrame: screen
        )
        #expect(pos.x == 1230)
        #expect(pos.y == 396)
    }

    @Test("Clamp left edge of screen")
    func clampLeftEdge() {
        let panelSize = NSSize(width: 210, height: 100)
        // Trigger is at x: -50. -50 is less than 0.
        // It should shift right to: 0.
        let triggerFrame = NSRect(x: -50, y: 500, width: 50, height: 30)
        let pos = PopoverPositioner.computePosition(
            panelSize: panelSize,
            triggerFrame: triggerFrame,
            visibleFrame: screen
        )
        #expect(pos.x == 0)
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
        // So it cannot fit below or above, and it should clamp to visibleFrame.minY = 0.
        let triggerFrame = NSRect(x: 100, y: 300, width: 50, height: 30)
        let pos = PopoverPositioner.computePosition(
            panelSize: panelSize,
            triggerFrame: triggerFrame,
            visibleFrame: screen
        )
        #expect(pos.x == 100)
        #expect(pos.y == 0)
    }
}
