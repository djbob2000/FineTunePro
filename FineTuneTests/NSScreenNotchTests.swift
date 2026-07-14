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
}
