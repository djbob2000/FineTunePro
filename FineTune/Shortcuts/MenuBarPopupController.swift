// FineTune/Shortcuts/MenuBarPopupController.swift
import AppKit
import os

/// Toggles the FineTune menu-bar popup from outside the SwiftUI scene chain
/// (e.g. when a global hotkey fires).
///
/// Locates the underlying `NSStatusItem` via `NSApp.windows` + KVC introspection
/// of the private `NSStatusBarWindow.statusItem` key. Once located, it posts a
/// synthetic click to the button so FluidMenuBarExtra remains the sole owner of
/// popup presentation, dismissal, focus, and event handling.
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
    private let postEvent: (NSEvent) -> Void

    init(
        accessibilityTitle: String = "FineTune",
        postEvent: @escaping (NSEvent) -> Void = { NSApp.postEvent($0, atStart: false) }
    ) {
        self.accessibilityTitle = accessibilityTitle
        self.postEvent = postEvent
    }

    func toggle() {
        guard let statusItem = findStatusItem() else {
            Self.logger.debug("toggle: no status item found yet (cold-launch race?); ignoring")
            return
        }
        guard let button = statusItem.button, let window = button.window else {
            Self.logger.debug("toggle: status item found but button/window missing; ignoring")
            return
        }

        if !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }

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
        ) else {
            Self.logger.error("toggle: failed to construct synthetic mouse-down event")
            return
        }

        postEvent(event)
    }

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

    private static func extractStatusItem(from window: NSWindow) -> NSStatusItem? {
        if let item = window.value(forKey: "statusItem") as? NSStatusItem {
            return item
        }
        return Mirror(reflecting: window).descendant("statusItem") as? NSStatusItem
    }
}
