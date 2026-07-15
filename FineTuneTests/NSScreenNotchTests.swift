import Testing
import Foundation
import AppKit
@testable import FineTune

@Suite("NotchGeometry Tests")
struct NotchGeometryTests {
    @Test("hasNotch resolves true when safeAreaTop > 0 and auxiliary areas exist")
    func hasNotchValidation() {
        let has = NotchGeometry.hasNotch(
            safeAreaTop: 24,
            topLeft: NSRect(x: 0, y: 876, width: 630, height: 24),
            topRight: NSRect(x: 810, y: 876, width: 630, height: 24)
        )
        #expect(has == true)
        
        let hasNoSafeArea = NotchGeometry.hasNotch(
            safeAreaTop: 0,
            topLeft: nil,
            topRight: nil
        )
        #expect(hasNoSafeArea == false)
    }

    @Test("notchRect resolves correct bounds in between auxiliary areas")
    func notchRectBounds() {
        let frame = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let topLeft = NSRect(x: 0, y: 876, width: 630, height: 24)
        let topRight = NSRect(x: 810, y: 876, width: 630, height: 24)
        
        let rect = NotchGeometry.notchRect(
            frame: frame,
            safeAreaTop: 24,
            topLeft: topLeft,
            topRight: topRight
        )
        
        #expect(rect == NSRect(x: 630, y: 876, width: 180, height: 24))
    }

    @Test("hudGeometry calculates sideWidth and caps it correctly")
    func hudGeometryCalculations() {
        let g1 = NotchGeometry.hudGeometry(deviceName: "Short", notchWidth: 180, menuBarHeight: 24, screenWidth: 1440)
        let g2 = NotchGeometry.hudGeometry(deviceName: "A Long Device Name That Fits", notchWidth: 180, menuBarHeight: 24, screenWidth: 1440)
        let font = NSFont.systemFont(ofSize: 12, weight: .bold)
        let expectedNameWidth = ("A Long Device Name That Fits" as NSString).size(withAttributes: [.font: font]).width
        
        let extremelyLongName = String(repeating: "A", count: 1000)
        let g3 = NotchGeometry.hudGeometry(deviceName: extremelyLongName, notchWidth: 180, menuBarHeight: 24, screenWidth: 1440)
        
        #expect(g1.sideWidth == 100.0)
        #expect(g1.pillWidth == 380.0)
        #expect(g1.pillHeight == 38.0)
        #expect(abs(g2.sideWidth - max(100, expectedNameWidth + 48)) < 0.01)
        #expect(g3.sideWidth == 614.0)
        #expect(g3.pillWidth == 1408.0)
    }
}
