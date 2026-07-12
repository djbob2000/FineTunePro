// FineTune/Audio/Keys/BottomEdgeScrollMonitor.swift
import AppKit
import AudioToolbox
import CoreGraphics
import os

/// Scroll at the bottom edge of any screen to change default-output volume.
///
/// Works with **mouse wheel** and **two-finger trackpad** scroll (both are `.scrollWheel`).
///
/// Input strategy:
/// 1. Prefer a **CGEventTap** so we can swallow scroll under the cursor (needs Accessibility;
///    Input Monitoring helps the tap actually receive scroll events on modern macOS).
/// 2. **Always** also install **NSEvent local + global monitors** as a volume path.
///    A “ghost” CG tap (installed but never delivered scroll) used to leave us with no input
///    when NSEvent was torn down — that was a total outage mode.
/// 3. Volume apply is **deduped** (~25 ms) so CG + NSEvent never double-step the same gesture.
///
/// Volume uses `volumeHotkeyStep` so feel matches media keys / hotkeys.
@MainActor
final class BottomEdgeScrollMonitor {
    // MARK: - Collaborators

    private let audioEngine: AudioEngine
    private let settingsManager: SettingsManager
    private let accessibility: any AccessibilityTrustProviding
    private let hudController: any MediaKeyHUDPresenting
    private let popupVisibility: PopupVisibilityService
    private let eventTapStatus: EventTapStatus
    private let logger = Logger(subsystem: "com.finetuneapp.FineTune", category: "BottomEdgeScrollMonitor")
    private let lifecycle: CGEventTapLifecycle

    var feedbackPlayer: VolumeFeedbackPlayer?
    var iconCoordinator: MediaKeyIconFlashing?

    // MARK: - NSEvent monitors (always-on volume path when feature is active)

    private var localMonitor: Any?
    private var globalMonitor: Any?

    // MARK: - Rate limiting

    /// 80 ms floor between DDC-tier steps — DDC write queues saturate under rapid scroll.
    var lastDDCStepTime: DispatchTime?

    /// Accumulator for precise deltas held during DDC coalesce (flushed on trailing timer).
    var pendingPreciseChange: Double = 0
    private var preciseFlushTask: Task<Void, Never>?

    /// Dedup only when CG tap and NSEvent both see the same physical scroll (~one frame).
    /// Same-source bursts (trackpad precise stream) must NOT be collapsed.
    private var lastApplyUptimeNs: UInt64 = 0
    private var lastApplySource: String = ""
    private static let applyDedupNs: UInt64 = 25_000_000 // 25 ms

    /// Hit-zone height from each screen's bottom (covers Dock / bottom bezel).
    nonisolated static let edgeThreshold: CGFloat = 48.0

    /// Precise (trackpad) deltas scale so ~50 points ≈ one `volumeHotkeyStep` tick.
    nonisolated private static let precisePointsPerStep: CGFloat = 50.0

    nonisolated(unsafe) private let settingsLock = NSLock()
    nonisolated(unsafe) private var cachedBottomEdgeScrollEnabled: Bool = false

    /// Runtime diagnostics path (read by humans / automation).
    nonisolated static var diagnosticsLogURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FineTune/bottom-edge-runtime.log", isDirectory: false)
    }



    var watchdogOpen: Bool { lifecycle.watchdogOpen }
    var isTapInstalled: Bool { lifecycle.isInstalled }
    var isNSEventMonitoring: Bool { localMonitor != nil || globalMonitor != nil }

    nonisolated var isBottomEdgeScrollEnabled: Bool {
        settingsLock.lock()
        defer { settingsLock.unlock() }
        return cachedBottomEdgeScrollEnabled
    }

    private func updateCachedSettings() {
        settingsLock.lock()
        defer { settingsLock.unlock() }
        cachedBottomEdgeScrollEnabled = settingsManager.appSettings.bottomEdgeScrollEnabled
    }

    init(
        audioEngine: AudioEngine,
        settingsManager: SettingsManager,
        accessibility: any AccessibilityTrustProviding,
        hudController: any MediaKeyHUDPresenting,
        popupVisibility: PopupVisibilityService,
        eventTapStatus: EventTapStatus
    ) {
        self.audioEngine = audioEngine
        self.settingsManager = settingsManager
        self.accessibility = accessibility
        self.hudController = hudController
        self.popupVisibility = popupVisibility
        self.eventTapStatus = eventTapStatus
        self.lifecycle = CGEventTapLifecycle(logger: logger)
        updateCachedSettings()

        lifecycle.onGhostTapDisabled = { [weak self] in
            guard let self else { return }
            self.logger.error("Bottom-edge CGEventTap disabled — NSEvent volume path remains")
            self.installNSEventMonitorsIfNeeded()
            self.writeDiagnostics(event: "ghost_tap_disabled")
        }
        lifecycle.onDoubleDisable = { [weak self] in
            guard let self else { return }
            self.logger.error("Bottom-edge CGEventTap double-disabled — NSEvent volume path remains")
            self.installNSEventMonitorsIfNeeded()
            // Not full offline while NSEvent can still drive volume.
            self.eventTapStatus.isOffline = !self.isNSEventMonitoring && !self.lifecycle.isInstalled
            self.writeDiagnostics(event: "double_disable")
        }
        lifecycle.onWakeNeedsReconcile = { [weak self] in
            self?.reconcile()
        }
    }

    isolated deinit {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        lifecycle.teardown()
    }

    // MARK: - Lifecycle

    /// Idempotent. Installs CGEventTap when possible **and** NSEvent monitors for volume.
    func start() {
        updateCachedSettings()
        guard cachedBottomEdgeScrollEnabled else {
            logger.debug("Bottom-edge scroll disabled in settings")
            return
        }
        guard accessibility.isTrusted else {
            logger.info("Accessibility not trusted; bottom-edge scroll not started")
            writeDiagnostics(event: "start_blocked_no_ax", extra: [
                "ax": "false",
                "listen": "\(CGPreflightListenEventAccess())"
            ])
            return
        }

        // Helps CGEventTap actually receive scroll on modern macOS (Input Monitoring).
        requestListenEventAccessIfNeeded()

        installEventTapIfNeeded()
        // Always install NSEvent — volume must work even if the CG tap is a ghost
        // (created successfully but never delivered scrollWheel events).
        installNSEventMonitorsIfNeeded()

        let listening = isNSEventMonitoring || lifecycle.isInstalled
        eventTapStatus.isOffline = !listening
        logger.info(
            "BottomEdgeScrollMonitor active (tap=\(self.lifecycle.isInstalled, privacy: .public), nsEvent=\(self.isNSEventMonitoring, privacy: .public), tapEnabled=\(self.lifecycle.isEnabled(), privacy: .public))"
        )
        writeDiagnostics(event: "start", extra: [
            "tap": "\(lifecycle.isInstalled)",
            "tapEnabled": "\(lifecycle.isEnabled())",
            "nsEvent": "\(isNSEventMonitoring)",
            "ax": "\(accessibility.isTrusted)",
            "listen": "\(CGPreflightListenEventAccess())",
            "offline": "\(eventTapStatus.isOffline)"
        ])
    }

    /// Reconciles listeners against settings + Accessibility trust. Idempotent.
    func reconcile() {
        updateCachedSettings()
        if cachedBottomEdgeScrollEnabled && accessibility.isTrusted {
            if eventTapStatus.isOffline {
                stop()
                eventTapStatus.isOffline = false
            }
            // Re-enable a disabled-but-installed tap without full teardown when possible.
            if lifecycle.isInstalled && !lifecycle.isEnabled() {
                lifecycle.setEnabled(true)
            }
            start()
            if lifecycle.isInstalled {
                lifecycle.armGhostTapProbe()
            }
        } else if cachedBottomEdgeScrollEnabled && !accessibility.isTrusted {
            // Feature on, but macOS has not granted Accessibility to *this* binary.
            // stop listeners (Debug builds are a separate TCC identity from /Applications).
            stop()
            eventTapStatus.isOffline = false
            writeDiagnostics(event: "reconcile_blocked_no_ax", extra: [
                "enabled": "true",
                "ax": "false",
                "listen": "\(CGPreflightListenEventAccess())"
            ])
        } else {
            stop()
            eventTapStatus.isOffline = false
            writeDiagnostics(event: "reconcile_stopped", extra: [
                "enabled": "\(cachedBottomEdgeScrollEnabled)",
                "ax": "\(accessibility.isTrusted)"
            ])
        }
    }

    func stop() {
        lifecycle.stop()
        removeNSEventMonitors()
        clearPendingPrecise()
    }

    private func clearPendingPrecise() {
        preciseFlushTask?.cancel()
        preciseFlushTask = nil
        pendingPreciseChange = 0
    }

    private func requestListenEventAccessIfNeeded() {
        if !CGPreflightListenEventAccess() {
            logger.info("Requesting Input Monitoring (Listen Event Access) for bottom-edge scroll")
            _ = CGRequestListenEventAccess()
        }
    }

    private func installEventTapIfNeeded() {
        guard !lifecycle.isInstalled else {
            if !lifecycle.isEnabled() {
                lifecycle.setEnabled(true)
            }
            return
        }
        // Explicit UInt64 shift — avoid Int overflow edge cases on mask construction.
        let mask = CGEventMask(1) << CGEventType.scrollWheel.rawValue
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        let ok = lifecycle.install(
            eventsOfInterest: mask,
            callback: bottomEdgeScrollTapCallback,
            userInfo: userInfo,
            preferredLocation: .cghidEventTap
        )
        if !ok {
            logger.warning("CGEventTap for bottom-edge scroll failed — NSEvent monitors still handle volume")
        }
    }

    private func installNSEventMonitorsIfNeeded() {
        if localMonitor == nil {
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self else { return event }
                return self.handleNSEventMonitor(event, canSwallow: true)
            }
        }
        if globalMonitor == nil {
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self else { return }
                _ = self.handleNSEventMonitor(event, canSwallow: false)
            }
        }
        if localMonitor != nil || globalMonitor != nil {
            logger.info("Bottom-edge NSEvent scroll monitors installed (local=\(self.localMonitor != nil), global=\(self.globalMonitor != nil))")
        }
    }

    private func removeNSEventMonitors() {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
    }

    // MARK: - Diagnostics

    /// Appends a line to `~/Library/Application Support/FineTune/bottom-edge-runtime.log`.
    private func writeDiagnostics(event: String, extra: [String: String] = [:]) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let pairs = extra.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " ")
        let line = "[\(stamp)] \(event) \(pairs)\n"
        let url = Self.diagnosticsLogURL
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: url.path) {
                if let handle = try? FileHandle(forWritingTo: url) {
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    if let data = line.data(using: .utf8) {
                        try handle.write(contentsOf: data)
                    }
                }
            } else {
                try line.write(to: url, atomically: true, encoding: .utf8)
            }
        } catch {
            logger.debug("Diagnostics write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Tap-disabled watchdog

    func handleTapDisabled() {
        lifecycle.handleTapDisabled(isAccessibilityTrusted: accessibility.isTrusted) { [weak self] in
            self?.accessibility.refresh()
        }
        // Volume must keep working if the tap is down.
        if cachedBottomEdgeScrollEnabled && accessibility.isTrusted {
            installNSEventMonitorsIfNeeded()
            eventTapStatus.isOffline = !isNSEventMonitoring && !lifecycle.isEnabled()
        }
        writeDiagnostics(event: "tap_disabled", extra: [
            "ax": "\(accessibility.isTrusted)",
            "nsEvent": "\(isNSEventMonitoring)",
            "tapEnabled": "\(lifecycle.isEnabled())"
        ])
    }

    // MARK: - Geometry / delta (testable)

    /// AppKit coordinates: `true` when `point` sits within `threshold` of the bottom edge
    /// of any screen rect (`NSScreen.frame` / `NSEvent.mouseLocation` space).
    nonisolated static func isAtBottomEdge(
        point: CGPoint,
        screens: [CGRect],
        threshold: CGFloat = BottomEdgeScrollMonitor.edgeThreshold
    ) -> Bool {
        // Inflate slightly so a cursor sitting on a half-open max edge still hits.
        guard let screen = screens.first(where: {
            $0.insetBy(dx: -1, dy: -1).contains(point)
        }) else { return false }
        return point.y <= screen.minY + threshold
    }

    /// Quartz / `CGEvent.location` coordinates (origin top-left of main display, y down).
    /// Bottom of a display is **high** Y. Used from the CGEventTap callback without MainActor.
    nonisolated static func isAtBottomEdgeQuartz(
        point: CGPoint,
        displayBounds: [CGRect],
        threshold: CGFloat = BottomEdgeScrollMonitor.edgeThreshold
    ) -> Bool {
        guard let bounds = displayBounds.first(where: {
            $0.insetBy(dx: -1, dy: -1).contains(point)
        }) else { return false }
        return point.y >= bounds.maxY - threshold
    }

    /// Live display bounds in Quartz global coordinates.
    nonisolated static func activeDisplayBoundsQuartz() -> [CGRect] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else {
            return []
        }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else {
            return []
        }
        return ids.prefix(Int(count)).map { CGDisplayBounds($0) }
    }

    /// Slider-domain delta for one scroll event. `nil` means ignore (zero).
    nonisolated static func sliderChange(
        deltaY: CGFloat,
        hasPrecise: Bool,
        isDirectionInverted: Bool,
        step: Double
    ) -> Double? {
        guard deltaY != 0 else { return nil }
        var physicalDelta = deltaY
        if isDirectionInverted {
            physicalDelta = -physicalDelta
        }
        if hasPrecise {
            return Double(physicalDelta) * step / Double(precisePointsPerStep)
        }
        return step * (physicalDelta > 0 ? 1.0 : -1.0)
    }

    // MARK: - NSEvent path (volume; local can swallow)

    private func handleNSEventMonitor(_ event: NSEvent, canSwallow: Bool) -> NSEvent? {
        guard isBottomEdgeScrollEnabled else { return event }

        let mouseLocation = NSEvent.mouseLocation
        let screenFrames = NSScreen.screens.map(\.frame)
        guard Self.isAtBottomEdge(point: mouseLocation, screens: screenFrames) else {
            return event
        }

        // Kinetic tail: no volume change; swallow only in local monitors.
        if event.momentumPhase != [] {
            return canSwallow ? nil : event
        }

        let deltaY = event.scrollingDeltaY
        guard deltaY != 0 else { return event }

        handleScroll(
            deltaY: deltaY,
            hasPrecise: event.hasPreciseScrollingDeltas,
            isDirectionInverted: event.isDirectionInvertedFromDevice,
            source: canSwallow ? "nsLocal" : "nsGlobal"
        )
        return canSwallow ? nil : event
    }

    // MARK: - CGEventTap path (preferred swallow when installed)

    /// Returns `true` if the caller should swallow the event.
    /// Mirrors MediaKeyMonitor: decide swallow quickly off MainActor, apply volume async.
    nonisolated func processScrollWheel(_ event: CGEvent) -> Bool {
        guard isBottomEdgeScrollEnabled else { return false }

        let momentum = event.getIntegerValueField(.scrollWheelEventMomentumPhase)
        let (deltaY, hasPrecise, inverted) = Self.scrollDelta(from: event)

        // Geometry from the event itself in Quartz space — no MainActor / NSScreen needed.
        let location = event.location
        let displays = Self.activeDisplayBoundsQuartz()
        guard Self.isAtBottomEdgeQuartz(point: location, displayBounds: displays) else {
            return false
        }

        // Momentum: swallow so windows do not kinetic-scroll; no volume.
        if momentum != 0 {
            return true
        }
        if deltaY == 0 {
            return true
        }

        // Async apply — do not block the event-tap callback (avoids tapDisabledByTimeout).
        Task { @MainActor in
            self.handleScroll(
                deltaY: deltaY,
                hasPrecise: hasPrecise,
                isDirectionInverted: inverted,
                source: "cgTap"
            )
        }
        return true
    }

    /// Line/point/fixed deltas from a CG scroll event.
    /// `hasPrecise` is true only for continuous (trackpad-style) streams — not merely
    /// because a point-delta field is non-zero (some mice fill both).
    nonisolated static func scrollDelta(from event: CGEvent) -> (deltaY: CGFloat, hasPrecise: Bool, inverted: Bool) {
        let isContinuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
        let pointDelta = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
        let lineDelta = event.getDoubleValueField(.scrollWheelEventDeltaAxis1)
        let fixedDelta = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
        let inverted = NSEvent(cgEvent: event)?.isDirectionInvertedFromDevice ?? false

        if isContinuous {
            let d = pointDelta != 0 ? pointDelta : lineDelta
            return (CGFloat(d), true, inverted)
        }
        if lineDelta != 0 {
            return (CGFloat(lineDelta), false, inverted)
        }
        if pointDelta != 0 {
            // Discrete device that only reports point deltas — treat as one notch by sign.
            return (pointDelta > 0 ? 1 : -1, false, inverted)
        }
        if fixedDelta != 0 {
            return (fixedDelta > 0 ? 1 : -1, false, inverted)
        }
        if let ns = NSEvent(cgEvent: event) {
            return (ns.scrollingDeltaY, ns.hasPreciseScrollingDeltas, ns.isDirectionInvertedFromDevice)
        }
        return (0, false, inverted)
    }

    // MARK: - Volume apply

    /// Applies a scroll delta to the default output device. Uses `volumeHotkeyStep`.
    func handleScroll(
        deltaY: CGFloat,
        hasPrecise: Bool,
        isDirectionInverted: Bool,
        source: String = "test"
    ) {
        let step = settingsManager.appSettings.volumeHotkeyStep.sliderDelta
        guard let rawChange = Self.sliderChange(
            deltaY: deltaY,
            hasPrecise: hasPrecise,
            isDirectionInverted: isDirectionInverted,
            step: step
        ) else { return }

        let volumeMonitor = audioEngine.deviceVolumeMonitor
        let deviceID = volumeMonitor.defaultDeviceID
        guard deviceID.isValid else {
            logger.debug("Scroll ignored: no valid default device (\(source, privacy: .public))")
            writeDiagnostics(event: "skip_invalid_device", extra: ["source": source])
            return
        }

        let tier = volumeMonitor.outputVolumeBackend(for: deviceID)

        let change: Double
        if hasPrecise {
            pendingPreciseChange += rawChange
            if tier == .ddc && isDDCStepCoalesced() {
                schedulePreciseFlush()
                return
            }
            preciseFlushTask?.cancel()
            preciseFlushTask = nil
            change = pendingPreciseChange
            pendingPreciseChange = 0
            if change == 0 { return }
        } else if tier == .ddc && isDDCStepCoalesced() {
            logger.debug("DDC scroll step coalesced")
            return
        } else {
            change = rawChange
        }

        // Cross-path dedup only (cgTap ↔ nsLocal/nsGlobal). Same-path bursts stay intact.
        let now = DispatchTime.now().uptimeNanoseconds
        if lastApplyUptimeNs != 0, now &- lastApplyUptimeNs < Self.applyDedupNs {
            let prevCG = lastApplySource.hasPrefix("cg")
            let curCG = source.hasPrefix("cg")
            let prevNS = lastApplySource.hasPrefix("ns")
            let curNS = source.hasPrefix("ns")
            if (prevCG && curNS) || (prevNS && curCG) {
                logger.debug("Scroll apply cross-path deduped (\(source, privacy: .public))")
                return
            }
        }
        lastApplyUptimeNs = now
        lastApplySource = source

        applyVolumeChange(change, deviceID: deviceID, tier: tier, volumeMonitor: volumeMonitor, source: source)
    }

    private func schedulePreciseFlush() {
        preciseFlushTask?.cancel()
        preciseFlushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled, let self else { return }
            self.flushPendingPrecise()
        }
    }

    private func flushPendingPrecise() {
        preciseFlushTask = nil
        let change = pendingPreciseChange
        pendingPreciseChange = 0
        guard change != 0 else { return }

        let volumeMonitor = audioEngine.deviceVolumeMonitor
        let deviceID = volumeMonitor.defaultDeviceID
        guard deviceID.isValid else { return }
        let tier = volumeMonitor.outputVolumeBackend(for: deviceID)
        lastDDCStepTime = DispatchTime.now()
        applyVolumeChange(change, deviceID: deviceID, tier: tier, volumeMonitor: volumeMonitor, source: "preciseFlush")
    }

    private func applyVolumeChange(
        _ change: Double,
        deviceID: AudioDeviceID,
        tier: VolumeControlTier,
        volumeMonitor: any DeviceVolumeProviding,
        source: String
    ) {
        let deviceName = audioEngine.deviceMonitor.outputDevices.first { $0.id == deviceID }?.name ?? ""
        let currentVolume = volumeMonitor.volumes[deviceID] ?? 0.0
        let currentMute = volumeMonitor.muteStates[deviceID] ?? false

        let currentSlider = VolumeMapping.sliderFraction(forSystemGain: currentVolume, tier: tier)
        var nextSlider = min(1.0, max(0.0, currentSlider + change))

        let minAudibleSlider: Double = (tier == .software) ? 0.001 : 0.01

        if change > 0 && nextSlider > 0.0 && nextSlider < minAudibleSlider {
            nextSlider = minAudibleSlider
        }

        let newVolume = VolumeMapping.systemGain(forSliderFraction: nextSlider, tier: tier)
        let willBeSilent = nextSlider < minAudibleSlider

        if currentMute && !willBeSilent {
            volumeMonitor.setMute(for: deviceID, to: false)
        } else if !currentMute && willBeSilent {
            volumeMonitor.setMute(for: deviceID, to: true)
        }

        volumeMonitor.setVolume(for: deviceID, to: newVolume)
        feedbackPlayer?.requestFeedback(gain: VolumeFeedback.gain(tier: tier, sliderFraction: nextSlider))

        if !popupVisibility.isVisible {
            // Position comes from Settings → HUD Position (shared with media keys).
            hudController.show(
                sliderFraction: nextSlider,
                mute: willBeSilent,
                deviceName: deviceName
            )
        }
        iconCoordinator?.flashDevice()

        logger.info(
            "Bottom-edge volume applied source=\(source, privacy: .public) slider=\(nextSlider, privacy: .public) tier=\(String(describing: tier), privacy: .public)"
        )
        writeDiagnostics(event: "volume_applied", extra: [
            "source": source,
            "slider": String(format: "%.4f", nextSlider),
            "change": String(format: "%.4f", change),
            "tier": "\(tier)",
            "device": deviceName
        ])
    }

    private func isDDCStepCoalesced() -> Bool {
        let now = DispatchTime.now()
        if let previous = lastDDCStepTime {
            let deltaNs = now.uptimeNanoseconds &- previous.uptimeNanoseconds
            if deltaNs < 80 * 1_000_000 { return true }
        }
        lastDDCStepTime = now
        return false
    }
}

// MARK: - CGEventTap C callback

private let bottomEdgeScrollTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
    guard let userInfo = userInfo else {
        return Unmanaged.passUnretained(event)
    }
    let monitor = Unmanaged<BottomEdgeScrollMonitor>.fromOpaque(userInfo).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        Task { @MainActor in
            monitor.handleTapDisabled()
        }
        return nil
    }

    guard type == .scrollWheel else {
        return Unmanaged.passUnretained(event)
    }

    let shouldSwallow = monitor.processScrollWheel(event)
    return shouldSwallow ? nil : Unmanaged.passUnretained(event)
}
