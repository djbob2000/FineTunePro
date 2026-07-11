// FineTune/Shortcuts/MenuBarPopupController.swift
import AppKit
import os

/// Toggles the FineTune menu-bar popup from outside the SwiftUI scene chain
/// (global hotkeys, multi-display status-item clicks).
///
/// FluidMenuBarExtra only reacts to clicks on the *primary* status-item window and
/// positions the panel from `statusItem.button.window.frame`. On multi-display
/// macOS those frames are often wrong, and a panel left open on display A makes
/// a click on display B look like a no-op (we would only dismiss, or open off
/// the clicked screen).
///
/// Strategy:
/// - Own status-item clicks (local + global) for every display.
/// - Place the panel under the cursor on the **screen that contains the mouse**.
/// - If the panel is already open on another screen, move it; only dismiss when
///   it is already on the clicked screen.
@MainActor
protocol MenuBarPopupControlling: AnyObject {
    func toggle()
}

@MainActor
final class MenuBarPopupController: MenuBarPopupControlling {
    private static let logger = Logger(
        subsystem: "com.finetuneapp.FineTune",
        category: "MenuBarPopupController"
    )

    private let accessibilityTitle: String

    private var localClickMonitor: Any?
    private var globalClickMonitor: Any?
    private var isHandlingStatusItemClick = false
    private var lastHandledClickUptime: TimeInterval = 0
    /// Last icon rect we used — reassert after Fluid's layout pass overwrites it.
    private var lastIconRect: NSRect?

    init(accessibilityTitle: String = "FineTune") {
        self.accessibilityTitle = accessibilityTitle
    }

    func installMultiDisplayClickFallback() {
        guard localClickMonitor == nil else { return }

        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self else { return event }
            return self.handleLocalStatusItemClick(event)
        }

        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            DispatchQueue.main.async {
                self?.handleGlobalPossibleStatusItemClick()
            }
        }

        Self.logger.info("Status-item click fallback installed")
    }

    func stop() {
        if let localClickMonitor {
            NSEvent.removeMonitor(localClickMonitor)
            self.localClickMonitor = nil
        }
        if let globalClickMonitor {
            NSEvent.removeMonitor(globalClickMonitor)
            self.globalClickMonitor = nil
        }
    }

    func toggle() {
        toggle(mouse: NSEvent.mouseLocation)
    }

    func toggle(mouse: NSPoint) {
        guard let statusItem = findStatusItem(),
              let button = statusItem.button
        else {
            Self.logger.debug("toggle: status item not ready")
            return
        }

        if !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }

        let screen = Self.screen(containing: mouse) ?? NSScreen.main ?? NSScreen.screens[0]
        let icon = Self.iconRect(mouse: mouse, on: screen)

        guard let popup = Self.fluidPopupWindow() else {
            postSyntheticClick(on: button)
            return
        }

        if Self.isEffectivelyShowing(popup) {
            if let popupScreen = Self.primaryScreen(for: popup),
               popupScreen == screen {
                // Same display → dismiss.
                dismiss(popup, button: button)
                return
            }
            // Open on another display → move under this icon (do not just dismiss).
        }

        present(popup, underIcon: icon, on: screen, highlighting: button)
    }

    // MARK: - Clicks

    private func handleLocalStatusItemClick(_ event: NSEvent) -> NSEvent? {
        if isHandlingStatusItemClick { return event }
        if event.modifierFlags.contains(.command) { return event }
        guard let window = event.window else { return event }
        let className = window.className
        guard className.contains("StatusBar") || className.contains("NSStatusItem") else {
            return event
        }
        guard windowHostsOurStatusItem(window), findStatusItem() != nil else {
            return event
        }
        handleClick(mouse: NSEvent.mouseLocation, source: "local")
        return nil // swallow — we own show/hide
    }

    private func handleGlobalPossibleStatusItemClick() {
        if isHandlingStatusItemClick { return }
        if NSEvent.modifierFlags.contains(.command) { return }

        let mouse = NSEvent.mouseLocation
        guard Self.mouseIsInMenuBarStrip(mouse) else { return }
        guard findStatusItem() != nil else { return }

        // Hit any of our status-bar windows (primary or replicant), even when
        // their reported frames are slightly off — pad generously.
        let hitOurWindow = NSApp.windows.contains { window in
            guard window.className.contains("StatusBar") || window.className.contains("NSStatusItem")
            else { return false }
            guard windowHostsOurStatusItem(window) else { return false }
            return window.frame.insetBy(dx: -16, dy: -12).contains(mouse)
        }

        // Or: menu-bar strip + FineTune is the only status item we host, and the
        // cursor is near a plausible icon X from AX / last known — keep it simple:
        // any menu-bar strip click on a window that hosts us is enough; if no
        // window frame matches, still open when the mouse is in the strip and we
        // have a status item (single-item process). Prefer window hit when possible.
        if hitOurWindow || Self.mouseNearAnyOfOurStatusWindows(mouse) {
            handleClick(mouse: mouse, source: "global")
        }
    }

    private static func mouseNearAnyOfOurStatusWindows(_ mouse: NSPoint) -> Bool {
        // Fallback when frames are garbage: still require menu-bar strip (caller)
        // and that *some* status bar window exists in this process near the mouse X
        // on the same screen (compare midX loosely).
        guard let screen = screen(containing: mouse) else { return false }
        let statusWindows = NSApp.windows.filter {
            $0.className.contains("StatusBar") || $0.className.contains("NSStatusItem")
        }
        for window in statusWindows {
            // Same screen by vertical band of menu bar, even if window.frame is wrong:
            // use mouse screen only; accept if window.frame midX is within 80pt of mouse
            // OR window frame is nonsense (not intersecting any screen).
            let f = window.frame
            let framePlausible = NSScreen.screens.contains { $0.frame.intersects(f) }
            if framePlausible {
                if abs(f.midX - mouse.x) < 80, abs(f.midY - mouse.y) < 40 {
                    return true
                }
            } else {
                // Nonsense frame (common on macOS 26 multi-display): treat strip click
                // as ours — we only host one status item.
                _ = screen
                return true
            }
        }
        return !statusWindows.isEmpty
    }

    private func handleClick(mouse: NSPoint, source: String) {
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastHandledClickUptime < 0.3 { return }
        lastHandledClickUptime = now

        isHandlingStatusItemClick = true
        defer { isHandlingStatusItemClick = false }

        Self.logger.debug("status-item click source=\(source, privacy: .public) mouse=\(NSStringFromPoint(mouse), privacy: .public)")
        toggle(mouse: mouse)
    }

    private func windowHostsOurStatusItem(_ window: NSWindow) -> Bool {
        if let item = Self.extractStatusItem(from: window) {
            if item.button?.accessibilityTitle() == accessibilityTitle { return true }
            if item.className.contains("Replicant"), findStatusItem() != nil { return true }
            if let primary = findStatusItem(), item === primary { return true }
        }
        if let content = window.contentView,
           Self.findStatusBarButton(in: content, matching: accessibilityTitle) != nil {
            return true
        }
        // One status item per process.
        return findStatusItem() != nil
            && (window.className.contains("StatusBar") || window.className.contains("NSStatusItem"))
    }

    private static func findStatusBarButton(in view: NSView, matching title: String) -> NSStatusBarButton? {
        if let button = view as? NSStatusBarButton, button.accessibilityTitle() == title {
            return button
        }
        for subview in view.subviews {
            if let match = findStatusBarButton(in: subview, matching: title) {
                return match
            }
        }
        return nil
    }

    // MARK: - Geometry

    /// Icon stand-in: under the cursor, on the menu bar of the clicked screen.
    private static func iconRect(mouse: NSPoint, on screen: NSScreen) -> NSRect {
        let barHeight: CGFloat = 24
        let width: CGFloat = 40
        return NSRect(
            x: mouse.x - width / 2,
            y: screen.frame.maxY - barHeight,
            width: width,
            height: barHeight
        )
    }

    private static func screen(containing point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.insetBy(dx: -1, dy: -1).contains(point) }
    }

    private static func primaryScreen(for window: NSWindow) -> NSScreen? {
        // Largest intersection with window frame wins.
        let frame = window.frame
        return NSScreen.screens
            .map { screen -> (NSScreen, CGFloat) in
                let inter = screen.frame.intersection(frame)
                let area = inter.isNull ? 0 : inter.width * inter.height
                return (screen, area)
            }
            .filter { $0.1 > 0 }
            .max { $0.1 < $1.1 }?
            .0
    }

    private static func mouseIsInMenuBarStrip(_ mouse: NSPoint) -> Bool {
        NSScreen.screens.contains { screen in
            let strip = NSRect(
                x: screen.frame.minX,
                y: screen.frame.maxY - 40,
                width: screen.frame.width,
                height: 40
            )
            return strip.contains(mouse)
        }
    }

    // MARK: - Present / dismiss

    private static func fluidPopupWindow() -> NSWindow? {
        NSApp.windows.first {
            String(describing: type(of: $0)).contains("FluidMenuBarExtra")
                || $0.className.contains("FluidMenuBarExtra")
        }
    }

    private static func isEffectivelyShowing(_ popup: NSWindow) -> Bool {
        guard popup.isVisible, popup.alphaValue > 0.5 else { return false }
        return primaryScreen(for: popup) != nil
    }

    private func dismiss(_ popup: NSWindow, button: NSStatusBarButton) {
        popup.resignKey()
        if Self.isEffectivelyShowing(popup) {
            popup.orderOut(nil)
            popup.alphaValue = 1
        }
        button.highlight(false)
        lastIconRect = nil
    }

    private func present(
        _ popup: NSWindow,
        underIcon icon: NSRect,
        on screen: NSScreen,
        highlighting button: NSStatusBarButton
    ) {
        popup.alphaValue = 1
        lastIconRect = icon

        DistributedNotificationCenter.default().post(
            name: Notification.Name("com.apple.HIToolbox.beginMenuTrackingNotification"),
            object: nil
        )

        Self.position(popup, underIcon: icon, on: screen)
        popup.orderFrontRegardless()
        popup.makeKeyAndOrderFront(nil)
        Self.position(popup, underIcon: icon, on: screen)
        button.highlight(true)

        // Fluid repositions after SwiftUI layout using broken status-item frames —
        // pin back to the clicked screen a few times.
        let iconCopy = icon
        let screenCopy = screen
        for delay in [0.05, 0.15, 0.3] as [TimeInterval] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.lastIconRect != nil else { return }
                Self.position(popup, underIcon: iconCopy, on: screenCopy)
                if !popup.isVisible {
                    popup.alphaValue = 1
                    popup.orderFrontRegardless()
                    popup.makeKeyAndOrderFront(nil)
                    Self.position(popup, underIcon: iconCopy, on: screenCopy)
                }
                button.highlight(true)
            }
        }
    }

    private static func position(_ popup: NSWindow, underIcon icon: NSRect, on screen: NSScreen) {
        var size = popup.frame.size
        if size.width < 80 || size.height < 80 {
            size = CGSize(width: max(size.width, 510), height: max(size.height, 340))
        }

        var frame = NSRect(origin: .zero, size: size)
        // Left-align under icon, hang below the menu bar of *this* screen.
        frame.origin.x = icon.minX - 2
        frame.origin.y = icon.minY - frame.height

        let visible = screen.visibleFrame
        let margin: CGFloat = 4
        if frame.maxX > visible.maxX {
            frame.origin.x = visible.maxX - frame.width - margin
        }
        if frame.minX < visible.minX {
            frame.origin.x = visible.minX + margin
        }
        // Never leave the clicked screen vertically.
        if frame.maxY > screen.frame.maxY - 2 {
            frame.origin.y = screen.frame.maxY - 24 - frame.height
        }
        if frame.minY < visible.minY {
            frame.origin.y = visible.minY + margin
        }
        // Final clamp: origin must stay inside this screen's frame.
        if !screen.frame.insetBy(dx: -2, dy: -2).contains(NSPoint(x: frame.midX, y: frame.midY)) {
            frame.origin.x = min(max(frame.origin.x, visible.minX + margin), visible.maxX - frame.width - margin)
            frame.origin.y = min(max(frame.origin.y, visible.minY + margin), screen.frame.maxY - 24 - frame.height)
        }

        popup.setFrame(frame, display: true)
    }

    private func postSyntheticClick(on button: NSStatusBarButton) {
        guard let window = button.window else { return }
        let location = NSPoint(x: button.bounds.midX, y: button.bounds.midY)
        guard let event = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: location,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1.0
        ) else { return }
        NSApp.postEvent(event, atStart: true)
    }

    // MARK: - Status item discovery

    private static var concreteStatusItemClassName: String {
        if #available(macOS 26.0, *) {
            return "NSSceneStatusItem"
        }
        return "NSStatusItem"
    }

    func findStatusItem() -> NSStatusItem? {
        let concreteName = Self.concreteStatusItemClassName
        return NSApp.windows
            .filter { $0.className.contains("NSStatusBarWindow") }
            .compactMap(Self.extractStatusItem(from:))
            .filter { $0.className == concreteName }
            .first { $0.button?.accessibilityTitle() == accessibilityTitle }
    }

    static func extractStatusItem(from window: NSWindow) -> NSStatusItem? {
        if let item = window.value(forKey: "statusItem") as? NSStatusItem {
            return item
        }
        return Mirror(reflecting: window).descendant("statusItem") as? NSStatusItem
    }
}
