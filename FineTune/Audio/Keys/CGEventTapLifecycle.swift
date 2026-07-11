// FineTune/Audio/Keys/CGEventTapLifecycle.swift
import AppKit
import CoreGraphics
import os

/// Shared CGEventTap install/teardown, sleep/wake, disable-watchdog, and ghost-tap probe.
/// Hosts own event-type handling and settings gates; this owns the fragile kernel plumbing.
@MainActor
final class CGEventTapLifecycle {
    private let logger: Logger

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// Second `.tapDisabledBy*` inside the watchdog window invokes `onDoubleDisable`.
    private var disableWatchdogTask: Task<Void, Never>?
    private(set) var watchdogOpen: Bool = false

    private var ghostTapProbeTask: Task<Void, Never>?
    private var workspaceObservers: [NSObjectProtocol] = []

    /// Ghost probe found the tap disabled after install/wake (media-key policy: mark offline).
    var onGhostTapDisabled: (() -> Void)?
    /// Second kernel disable inside the 5s watchdog window.
    var onDoubleDisable: (() -> Void)?
    /// Fired when a runloop source is actually removed during `stop()`.
    var onRunLoopSourceRemoved: (() -> Void)?
    /// Wake/session-activate with no tap installed — host should `reconcile()`.
    var onWakeNeedsReconcile: (() -> Void)?

    var isInstalled: Bool { tap != nil }

    init(logger: Logger) {
        self.logger = logger
        subscribeToWorkspaceLifecycle()
    }

    /// Tear down tap + observers. Call from host `deinit`.
    func teardown() {
        stop()
        let nc = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers { nc.removeObserver(observer) }
        workspaceObservers.removeAll()
    }

    // MARK: - Install / stop

    /// Idempotent install. Returns `false` if `tapCreate` failed; `true` if installed or already up.
    /// Tries `preferredLocation` first, then falls back to session / HID so scroll taps still land
    /// when one insertion point is unavailable.
    @discardableResult
    func install(
        eventsOfInterest: CGEventMask,
        callback: CGEventTapCallBack,
        userInfo: UnsafeMutableRawPointer?,
        preferredLocation: CGEventTapLocation = .cghidEventTap
    ) -> Bool {
        guard tap == nil else { return true }

        let locations: [CGEventTapLocation] = {
            switch preferredLocation {
            case .cghidEventTap:
                return [.cghidEventTap, .cgSessionEventTap]
            case .cgSessionEventTap:
                return [.cgSessionEventTap, .cghidEventTap]
            default:
                return [preferredLocation, .cghidEventTap, .cgSessionEventTap]
            }
        }()

        var newTap: CFMachPort?
        for location in locations {
            newTap = CGEvent.tapCreate(
                tap: location,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: eventsOfInterest,
                callback: callback,
                userInfo: userInfo
            )
            if newTap != nil {
                logger.info("CGEventTap created at \(String(describing: location), privacy: .public)")
                break
            }
        }

        guard let created = newTap else {
            logger.error("CGEvent.tapCreate failed for all locations")
            return false
        }

        let source = CFMachPortCreateRunLoopSource(nil, created, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: created, enable: true)

        self.tap = created
        self.runLoopSource = source
        logger.info("CGEventTap installed")
        return true
    }

    /// Tears down the tap + runloop source. Safe with no tap installed.
    func stop() {
        disableWatchdogTask?.cancel()
        disableWatchdogTask = nil
        watchdogOpen = false
        cancelGhostTapProbe()

        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            onRunLoopSourceRemoved?()
        }
        tap = nil
        runLoopSource = nil
        logger.info("CGEventTap removed")
    }

    /// Force reinstall: stop then install. Clears watchdog state. Used by Retry after offline.
    @discardableResult
    func reinstall(
        eventsOfInterest: CGEventMask,
        callback: CGEventTapCallBack,
        userInfo: UnsafeMutableRawPointer?
    ) -> Bool {
        stop()
        return install(
            eventsOfInterest: eventsOfInterest,
            callback: callback,
            userInfo: userInfo
        )
    }

    func setEnabled(_ enabled: Bool) {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: enabled)
    }

    func isEnabled() -> Bool {
        guard let tap else { return false }
        return CGEvent.tapIsEnabled(tap: tap)
    }

    // MARK: - Workspace lifecycle

    private func subscribeToWorkspaceLifecycle() {
        let nc = NSWorkspace.shared.notificationCenter
        func add(_ name: Notification.Name, _ handler: @escaping @MainActor () -> Void) {
            let token = nc.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { handler() }
            }
            workspaceObservers.append(token)
        }
        add(NSWorkspace.didWakeNotification) { [weak self] in self?.handleWake() }
        add(NSWorkspace.sessionDidBecomeActiveNotification) { [weak self] in self?.handleWake() }
        add(NSWorkspace.willSleepNotification) { [weak self] in self?.handleSuspend() }
        add(NSWorkspace.sessionDidResignActiveNotification) { [weak self] in self?.handleSuspend() }
    }

    private func handleWake() {
        guard isInstalled else {
            onWakeNeedsReconcile?()
            return
        }
        setEnabled(true)
        logger.info("CGEventTap re-enabled after wake / session activation")
        armGhostTapProbe()
    }

    private func handleSuspend() {
        guard isInstalled else { return }
        setEnabled(false)
        logger.info("CGEventTap disabled for sleep / session resign")
    }

    // MARK: - Ghost-tap probe

    /// Checks `tapIsEnabled` ~1.5s after install/wake; notifies host if the kernel dropped it.
    func armGhostTapProbe() {
        cancelGhostTapProbe()
        ghostTapProbeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled, let self else { return }
            if self.isInstalled && !self.isEnabled() {
                self.logger.error("Ghost-tap probe: tap reports disabled after regrant/wake — marking offline")
                self.onGhostTapDisabled?()
            }
            self.ghostTapProbeTask = nil
        }
    }

    func cancelGhostTapProbe() {
        ghostTapProbeTask?.cancel()
        ghostTapProbeTask = nil
    }

    // MARK: - Tap-disabled watchdog

    /// Kernel disabled the tap. One-shot re-enable; second disable inside 5s → `onDoubleDisable`.
    func handleTapDisabled(isAccessibilityTrusted: Bool, onRevocation: () -> Void) {
        if !isAccessibilityTrusted {
            logger.warning("Tap disabled and Accessibility no longer trusted — stopping")
            disableWatchdogTask?.cancel()
            disableWatchdogTask = nil
            watchdogOpen = false
            stop()
            onRevocation()
            return
        }

        logger.info("Tap disabled by kernel — attempting re-enable")

        if watchdogOpen {
            logger.error("Second tap-disable inside watchdog window; marking feature offline")
            disableWatchdogTask?.cancel()
            disableWatchdogTask = nil
            watchdogOpen = false
            onDoubleDisable?()
            return
        }

        watchdogOpen = true
        disableWatchdogTask?.cancel()
        disableWatchdogTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.watchdogOpen = false
            self?.disableWatchdogTask = nil
        }

        setEnabled(true)
    }
}
