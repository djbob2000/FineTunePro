// FineTune/Shortcuts/MenuBarPopupController.swift
import AppKit
import Observation
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
    private let windows: () -> [NSWindow]
    private var pendingVisibility: Bool?
    private var coldLaunchVisibility: Bool?
    private var coldLaunchTask: Task<Void, Never>?
    private var pendingReset: DispatchWorkItem?
    private var positioner: MenuBarPopupPositioner?
    private var settingsManager: SettingsManager?
    private var trackingPosition = false

    init(
        accessibilityTitle: String = "FineTune",
        postEvent: @escaping (NSEvent) -> Void = { NSApp.postEvent($0, atStart: false) },
        windows: @escaping () -> [NSWindow] = { NSApp.windows },
        settingsManager: SettingsManager? = nil
    ) {
        self.accessibilityTitle = accessibilityTitle
        self.postEvent = postEvent
        self.windows = windows
        self.settingsManager = settingsManager
        if settingsManager != nil {
            let positioner = MenuBarPopupPositioner(
                position: { [weak self] in self?.settingsManager?.appSettings.popupPosition ?? .followIcon },
                popupWindow: { [weak self] in self?.findPopupWindow() },
                statusItemFrame: { [weak self] in self?.findStatusItem()?.button?.window?.frame },
                visibleFrame: { [weak self] in self?.findStatusItem()?.button?.window?.screen?.visibleFrame }
            )
            self.positioner = positioner
            trackingPosition = true
            positioner.start()
            trackPositionSetting()
        }
    }

    func stop() {
        trackingPosition = false
        coldLaunchTask?.cancel()
        coldLaunchTask = nil
        coldLaunchVisibility = nil
        pendingReset?.cancel()
        pendingReset = nil
        pendingVisibility = nil
        positioner?.stop()
    }

    private func trackPositionSetting() {
        guard trackingPosition else { return }
        withObservationTracking {
            _ = settingsManager?.appSettings.popupPosition
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.trackPositionSetting()
                self?.positioner?.reposition()
            }
        }
    }

    func toggle() {
        requestVisibility(!requestedVisibility)
    }

    private func requestVisibility(_ visible: Bool) {
        guard let statusItem = findStatusItem(), let button = statusItem.button,
              let window = button.window else {
            coldLaunchVisibility = visible
            waitForStatusItem()
            return
        }
        coldLaunchVisibility = nil
        coldLaunchTask?.cancel()
        coldLaunchTask = nil
        guard visible != requestedVisibility else { return }

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

        pendingVisibility = visible
        pendingReset?.cancel()
        // The posted click is asynchronous. Remember the requested state so
        // repeated open URLs in the same batch cannot enqueue two toggles.
        let reset = DispatchWorkItem { [weak self] in self?.pendingVisibility = nil }
        pendingReset = reset
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: reset)
        postEvent(event)
    }

    func open() {
        guard !requestedVisibility else { return }
        requestVisibility(true)
    }

    func close() {
        guard requestedVisibility else { return }
        requestVisibility(false)
    }

    private func waitForStatusItem() {
        guard coldLaunchTask == nil else { return }
        coldLaunchTask = Task { @MainActor [weak self] in
            for _ in 0..<30 {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled, let self else { return }
                if self.findStatusItem()?.button?.window != nil, let visible = self.coldLaunchVisibility {
                    self.requestVisibility(visible)
                    return
                }
            }
            self?.coldLaunchVisibility = nil
            self?.coldLaunchTask = nil
            Self.logger.debug("Popup request expired before the menu-bar scene was ready")
        }
    }

    private var requestedVisibility: Bool {
        if let coldLaunchVisibility { return coldLaunchVisibility }
        let visible = findPopupWindow()?.isVisible ?? false
        if pendingVisibility == visible {
            pendingVisibility = nil
        }
        return pendingVisibility ?? visible
    }

    func findPopupWindow() -> NSWindow? {
        windows().first {
            $0.title == accessibilityTitle &&
                String(describing: type(of: $0)).contains("FluidMenuBarExtra")
        }
    }

    private static var concreteStatusItemClassName: String {
        if #available(macOS 26.0, *) {
            return "NSSceneStatusItem"
        }
        return "NSStatusItem"
    }

    func findStatusItem() -> NSStatusItem? {
        let concreteName = Self.concreteStatusItemClassName

        return windows()
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
