import AppKit

/// Anchor for the main mixer popup. Independent of the volume HUD preference.
enum MenuBarPopupPosition: String, Codable, CaseIterable, Identifiable, CustomStringConvertible {
    case followIcon
    case topLeft
    case topRight

    var id: String { rawValue }

    var description: String {
        switch self {
        case .followIcon: return L10n.string("Follow Icon")
        case .topLeft: return L10n.string("Top Left")
        case .topRight: return L10n.string("Top Right")
        }
    }

    func frame(size: NSSize, statusItemFrame: NSRect, visibleFrame: NSRect) -> NSRect {
        let horizontalInset = min(12, max(0, (visibleFrame.width - size.width) / 2))
        let verticalInset = min(12, max(0, (visibleFrame.height - size.height) / 2))
        var origin: NSPoint
        switch self {
        case .topLeft:
            origin = NSPoint(x: visibleFrame.minX + horizontalInset, y: visibleFrame.maxY - verticalInset - size.height)
        case .topRight:
            origin = NSPoint(x: visibleFrame.maxX - horizontalInset - size.width, y: visibleFrame.maxY - verticalInset - size.height)
        case .followIcon:
            // Match FluidMenuBarExtra's default left alignment and its reverse
            // alignment at the right edge, including its two-point window border.
            origin = NSPoint(x: statusItemFrame.minX - 2, y: statusItemFrame.minY - size.height)
            if origin.x + size.width > visibleFrame.maxX {
                origin.x = statusItemFrame.maxX - size.width + 2
            }
        }
        origin.x = max(visibleFrame.minX, min(origin.x, visibleFrame.maxX - size.width))
        if size.height <= visibleFrame.height {
            origin.y = max(visibleFrame.minY, min(origin.y, visibleFrame.maxY - size.height))
        } else {
            origin.y = visibleFrame.maxY - size.height
        }
        return NSRect(origin: origin, size: size)
    }
}
