import AppKit

enum NotchGeometry {
    static func hasNotch(safeAreaTop: CGFloat, topLeft: NSRect?, topRight: NSRect?) -> Bool {
        return safeAreaTop > 0 && topLeft != nil && topRight != nil
    }

    static func notchRect(frame: NSRect, safeAreaTop: CGFloat, topLeft: NSRect?, topRight: NSRect?) -> NSRect? {
        guard hasNotch(safeAreaTop: safeAreaTop, topLeft: topLeft, topRight: topRight),
              let topLeft = topLeft,
              let topRight = topRight else {
            return nil
        }
        let x = topLeft.maxX
        let y = topLeft.minY
        let width = topRight.minX - topLeft.maxX
        let height = frame.maxY - topLeft.minY
        return NSRect(x: x, y: y, width: width, height: height)
    }
}

extension NSScreen {
    var hasNotch: Bool {
        guard #available(macOS 12.0, *) else { return false }
        return NotchGeometry.hasNotch(safeAreaTop: safeAreaInsets.top, topLeft: auxiliaryTopLeftArea, topRight: auxiliaryTopRightArea)
    }

    var notchRect: NSRect? {
        guard #available(macOS 12.0, *) else { return nil }
        return NotchGeometry.notchRect(frame: frame, safeAreaTop: safeAreaInsets.top, topLeft: auxiliaryTopLeftArea, topRight: auxiliaryTopRightArea)
    }
}
