// FineTune/Views/HUD/HUDWindowController.swift
import AppKit
import SwiftUI
import os

/// Owns the on-screen volume HUD panel and its auto-hide timing.
@MainActor
final class HUDWindowController: MediaKeyHUDPresenting {
    private let settingsManager: SettingsManager
    private let mediaKeyStatus: MediaKeyStatus
    private let popupVisibility: PopupVisibilityService
    private let logger = Logger(subsystem: "com.finetuneapp.FineTune", category: "HUDWindowController")

    private var panel: NSPanel?
    private var hostingView: NSHostingView<AnyView>?
    private var hideTask: Task<Void, Never>?
    private var styleAtLastShow: HUDStyle = .tahoe

    /// Slider fraction in [0, 1]. The wiring site converts to gain using the current device's tier.
    var volumeWriter: ((Double) -> Void)?
    var foregroundAppFullscreenProvider: () -> Bool = {
        HUDWindowController.detectForegroundAppFullscreen()
    }

    // MARK: - Suppression-degraded tracking

    private var lastSwallowedKeyTime: DispatchTime?
    private var settingsChangedObserver: NSObjectProtocol?

    var hideDelayOverride: Duration?
    var frameProvider: () -> NSRect? = { NSScreen.main?.visibleFrame ?? NSScreen.screens.first?.visibleFrame }
    private(set) var showCallCount: Int = 0
    private(set) var showDidUpdatePanel: Bool = false

    init(
        settingsManager: SettingsManager,
        mediaKeyStatus: MediaKeyStatus,
        popupVisibility: PopupVisibilityService
    ) {
        self.settingsManager = settingsManager
        self.mediaKeyStatus = mediaKeyStatus
        self.popupVisibility = popupVisibility
        subscribeToSettingsChangedNotification()
    }

    isolated deinit {
        if let observer = settingsChangedObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
        // Prefer shutdown() for synchronous teardown during willTerminate; this
        // deinit safety-net only fires for objects released without that call.
        if let panel {
            panel.orderOut(nil)
        }
    }

    /// Synchronous teardown for `willTerminate` — hides without animation.
    func shutdown() {
        hideTask?.cancel()
        hideTask = nil
        if let panel, panel.isVisible {
            panel.orderOut(nil)
        }
    }

    // MARK: - Style-indexed hide delay

    func hideDelay(for style: HUDStyle, position: HUDScreenPosition = .topTrailing) -> Duration {
        if let override = hideDelayOverride { return override }
        // Bottom anchors stay up a bit longer (easier to read while looking down).
        if position.isBottom { return .milliseconds(1600) }
        return .milliseconds(1100)
    }

    // MARK: - Public API

    /// Displays the HUD. Skipped when the popup is visible.
    /// Screen corner / edge comes from `AppSettings.hudPosition` (shared by media keys,
    /// bottom-edge scroll, and hotkeys).
    func show(sliderFraction: Double, mute: Bool, deviceName: String) {
        showCallCount += 1
        showDidUpdatePanel = false

        guard !popupVisibility.isVisible else {
            logger.debug("Skipping HUD show: popup is visible")
            return
        }

        let style = settingsManager.appSettings.hudStyle
        let screenPosition = settingsManager.appSettings.hudPosition
        let appearance = settingsManager.appSettings.appearance
        styleAtLastShow = style
        lastScreenPosition = screenPosition

        let screen = screenForHUD()
        let hasNotch = screen?.hasNotch ?? false
        let activeStyle: HUDStyle
        if style == .notch {
            activeStyle = hasNotch ? .notch : .tahoe
        } else {
            activeStyle = style
        }

        let panel = ensurePanel()
        // Refresh on every show so a preference change between invocations
        // takes effect immediately.
        panel.appearance = appearance.nsAppearance
        panel.level = (activeStyle == .notch) ? .statusBar : .floating

        // Classic is click-through. Tahoe stays interactive for drag + hover
        // except when anchored at the bottom (near Dock / gesture) to avoid
        // stealing clicks from the menu bar or windows.
        // Notch HUD is also fully click-through to allow menu bar interaction.
        panel.ignoresMouseEvents = (style == .classic) || screenPosition.isBottom || (activeStyle == .notch)

        let scheme = appearance.swiftUIColorScheme
        let displayFraction = Float(max(0, min(1, sliderFraction)))
        let root: AnyView
        let size: NSSize
        switch activeStyle {
        case .tahoe:
            root = AnyView(
                TahoeStyleHUD(
                    sliderFraction: displayFraction,
                    mute: mute,
                    deviceName: deviceName,
                    onSliderChange: { [weak self] newFraction in
                        self?.volumeWriter?(Double(newFraction))
                    },
                    onHoverChange: { [weak self] hovering in
                        self?.handleHoverChange(hovering)
                    }
                )
                .preferredColorScheme(scheme)
            )
            size = NSSize(width: 300, height: 72)
        case .classic:
            root = AnyView(
                ClassicStyleHUD(sliderFraction: displayFraction, mute: mute)
                    .preferredColorScheme(scheme)
            )
            size = NSSize(width: 200, height: 200)
        case .notch:
            if let screen = screen, let notchRect = screen.notchRect {
                let notchWidth = notchRect.width
                let menuBarHeight = screen.safeAreaInsets.top
                root = AnyView(
                    NotchStyleHUD(
                        sliderFraction: displayFraction,
                        mute: mute,
                        deviceName: deviceName,
                        notchWidth: notchWidth,
                        menuBarHeight: menuBarHeight
                    )
                    .preferredColorScheme(scheme)
                )
                size = NSSize(width: notchWidth + 180, height: menuBarHeight + 14)
            } else {
                root = AnyView(
                    TahoeStyleHUD(
                        sliderFraction: displayFraction,
                        mute: mute,
                        deviceName: deviceName
                    )
                    .preferredColorScheme(scheme)
                )
                size = NSSize(width: 300, height: 72)
            }
        }

        if let existing = hostingView {
            existing.rootView = root
            existing.frame = NSRect(origin: .zero, size: size)
        } else {
            let hv = NSHostingView(rootView: root)
            hv.frame = NSRect(origin: .zero, size: size)
            panel.contentView = hv
            hostingView = hv
        }
        showDidUpdatePanel = true

        panel.setContentSize(size)
        if activeStyle == .notch, let screen = screen {
            let origin = NSPoint(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height)
            panel.setFrameOrigin(origin)
        } else {
            panel.setFrameOrigin(position(for: size, screenPosition: screenPosition))
        }

        if panel.isVisible {
            panel.orderFrontRegardless()
        } else {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            let duration = reduceMotionEnabled() ? 0.08 : 0.12
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = duration
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1.0
            }
        }

        scheduleHide(for: style, position: screenPosition)
        postAccessibilityAnnouncement(panel: panel, sliderFraction: sliderFraction, mute: mute, deviceName: deviceName)
    }

    func showPerAppVolumeHUD(app: AudioApp, sliderFraction: Double) {
        presentPerApp(
            icon: app.icon,
            title: app.name,
            content: .volume(sliderFraction: max(0, min(1, sliderFraction)))
        )
    }

    func showPerAppMuteHUD(app: AudioApp, isMuted: Bool) {
        presentPerApp(
            icon: app.icon,
            title: app.name,
            content: .mute(isMuted: isMuted)
        )
    }

    func showPerAppNotControlledHUD(displayName: String?, bundleID: String?, icon: NSImage?) {
        let title = displayName?.nilIfEmpty
            ?? bundleID?.nilIfEmpty
            ?? L10n.string("FineTune isn't controlling this app yet")
        presentPerApp(
            icon: icon,
            title: title,
            content: .notControlled
        )
    }

    /// Hotkey-triggered per-app HUDs bypass the fullscreen guard because the user explicitly invoked them.
    private func presentPerApp(icon: NSImage?, title: String, content: PerAppHUDContent) {
        showCallCount += 1
        showDidUpdatePanel = false

        guard !popupVisibility.isVisible else {
            logger.debug("Skipping per-app HUD: popup is visible")
            return
        }

        let appearance = settingsManager.appSettings.appearance
        styleAtLastShow = .tahoe
        let panel = ensurePanel()
        panel.appearance = appearance.nsAppearance
        panel.ignoresMouseEvents = true

        let scheme = appearance.swiftUIColorScheme
        let root = AnyView(
            PerAppHUD(icon: icon, title: title, content: content)
                .preferredColorScheme(scheme)
        )
        let size = NSSize(width: 300, height: 72)

        if let existing = hostingView {
            existing.rootView = root
        } else {
            let hv = NSHostingView(rootView: root)
            hv.frame = NSRect(origin: .zero, size: size)
            panel.contentView = hv
            hostingView = hv
        }
        showDidUpdatePanel = true

        panel.setContentSize(size)
        let screenPosition = settingsManager.appSettings.hudPosition
        lastScreenPosition = screenPosition
        panel.setFrameOrigin(position(for: size, screenPosition: screenPosition))

        if panel.isVisible {
            panel.orderFrontRegardless()
        } else {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            let duration = reduceMotionEnabled() ? 0.08 : 0.12
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = duration
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1.0
            }
        }

        scheduleHide(for: .tahoe, position: screenPosition)
        postPerAppAccessibilityAnnouncement(panel: panel, title: title, content: content)
    }

    /// Called when the monitor swallows a keypress; used to detect if the native HUD still fired.
    func swallowObserved() {
        lastSwallowedKeyTime = DispatchTime.now()
    }

    func hide() {
        hideTask?.cancel()
        hideTask = nil
        guard let panel, panel.isVisible else { return }
        let duration = reduceMotionEnabled() ? 0.08 : 0.11
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().alphaValue = 0.0
        }, completionHandler: {
            MainActor.assumeIsolated { panel.orderOut(nil) }
        })
    }

    // MARK: - Position Math

    private static let edgeInset: CGFloat = 8
    private static let bottomInset: CGFloat = 20

    /// Places the HUD inside `visibleFrame` according to `screenPosition`.
    /// When `suppressionDegraded` and the preferred corner is top-trailing, shift
    /// left so we don't sit under the native macOS volume HUD.
    static func computePosition(
        size: NSSize,
        visibleFrame: NSRect,
        screenFrame: NSRect? = nil,
        screenPosition: HUDScreenPosition,
        suppressionDegraded: Bool = false
    ) -> NSPoint {
        var position = screenPosition
        if suppressionDegraded && position == .topTrailing {
            // Historic degraded layout: upper-left quarter (avoids native top-right OSD).
            let x = visibleFrame.minX + visibleFrame.width * 0.25 - size.width / 2
            let y = visibleFrame.maxY - size.height - edgeInset
            return NSPoint(x: x, y: y)
        }

        let x: CGFloat
        let y: CGFloat
        switch position {
        case .topLeading:
            x = visibleFrame.minX + edgeInset
            y = visibleFrame.maxY - size.height - edgeInset
        case .topCenter:
            let midX = screenFrame?.midX ?? visibleFrame.midX
            x = midX - size.width / 2
            y = visibleFrame.maxY - size.height - edgeInset
        case .topTrailing:
            x = visibleFrame.maxX - size.width - edgeInset
            y = visibleFrame.maxY - size.height - edgeInset
        case .bottomLeading:
            x = visibleFrame.minX + edgeInset
            y = visibleFrame.minY + bottomInset
        case .bottomCenter:
            let midX = screenFrame?.midX ?? visibleFrame.midX
            x = midX - size.width / 2
            y = visibleFrame.minY + bottomInset
        case .bottomTrailing:
            x = visibleFrame.maxX - size.width - edgeInset
            y = visibleFrame.minY + bottomInset
        }
        return NSPoint(x: x, y: y)
    }

    /// Backward-compatible overload used by older tests (Tahoe top-right / Classic bottom+140).
    static func computePosition(
        style: HUDStyle,
        size: NSSize,
        visibleFrame: NSRect,
        screenFrame: NSRect? = nil,
        suppressionDegraded: Bool
    ) -> NSPoint {
        // Classic historically ignored suppression-degraded and sat higher above the Dock.
        if style == .classic {
            let midX = screenFrame?.midX ?? visibleFrame.midX
            let x = midX - size.width / 2
            let y = visibleFrame.minY + 140
            return NSPoint(x: x, y: y)
        }
        return computePosition(
            size: size,
            visibleFrame: visibleFrame,
            screenFrame: screenFrame,
            screenPosition: .topTrailing,
            suppressionDegraded: suppressionDegraded
        )
    }

    private func position(for size: NSSize, screenPosition: HUDScreenPosition) -> NSPoint {
        let screen = screenForHUD()
        let frame = screen?.visibleFrame ?? frameProvider() ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let screenFrame = screen?.frame
        return Self.computePosition(
            size: size,
            visibleFrame: frame,
            screenFrame: screenFrame,
            screenPosition: screenPosition,
            suppressionDegraded: mediaKeyStatus.suppressionDegraded
        )
    }

    private func screenForHUD() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.insetBy(dx: -1, dy: -1).contains(mouse) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    // MARK: - Panel construction

    private func ensurePanel() -> NSPanel {
        if let existing = panel { return existing }

        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 72),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]
        p.hasShadow = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.ignoresMouseEvents = true
        // Needed for Tahoe hover/drag on a non-activating panel.
        p.acceptsMouseMovedEvents = true
        p.hidesOnDeactivate = false
        p.isMovable = false
        p.isReleasedWhenClosed = false
        // Initial appearance; refreshed on every show() so preference flips
        // between invocations propagate.
        p.appearance = settingsManager.appSettings.appearance.nsAppearance

        panel = p
        return p
    }

    private var lastScreenPosition: HUDScreenPosition = .topTrailing

    private func scheduleHide(for style: HUDStyle, position: HUDScreenPosition) {
        lastScreenPosition = position
        hideTask?.cancel()
        let delay = hideDelay(for: style, position: position)
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    private func handleHoverChange(_ hovering: Bool) {
        if hovering {
            hideTask?.cancel()
            hideTask = nil
        } else {
            scheduleHide(for: styleAtLastShow, position: lastScreenPosition)
        }
    }

    // MARK: - Accessibility

    private func postAccessibilityAnnouncement(panel: NSPanel, sliderFraction: Double, mute: Bool, deviceName: String) {
        let description = accessibilityDescription(sliderFraction: sliderFraction, mute: mute, deviceName: deviceName)
        NSAccessibility.post(
            element: panel,
            notification: .announcementRequested,
            userInfo: [
                .announcement: description,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue
            ]
        )
    }

    private func accessibilityDescription(sliderFraction: Double, mute: Bool, deviceName: String) -> String {
        let device = deviceName.isEmpty ? L10n.string("Unknown device") : deviceName
        if mute { return L10n.format("%@, muted", device) }
        let clamped = max(0, min(1, sliderFraction))
        return L10n.format("%@, volume %lld percent", device, Int((clamped * 100).rounded()))
    }

    private func postPerAppAccessibilityAnnouncement(panel: NSPanel, title: String, content: PerAppHUDContent) {
        let description: String
        switch content {
        case .volume(let sliderFraction):
            description = L10n.format("%@, volume %lld percent", title, Int((sliderFraction * 100).rounded()))
        case .mute(let isMuted):
            description = isMuted ? L10n.format("%@, muted", title) : L10n.format("%@, unmuted", title)
        case .notControlled:
            description = L10n.format("%@, not controlled by FineTune", title)
        }
        NSAccessibility.post(
            element: panel,
            notification: .announcementRequested,
            userInfo: [
                .announcement: description,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue
            ]
        )
    }

    private func reduceMotionEnabled() -> Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    // MARK: - Fullscreen guard

    private static func detectForegroundAppFullscreen() -> Bool {
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication else { return false }
        let pid = frontmostApp.processIdentifier
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        guard let mainScreen = NSScreen.main else { return false }
        let screenFrame = mainScreen.frame
        for windowInfo in windowList {
            guard let ownerPID = windowInfo[kCGWindowOwnerPID as String] as? pid_t, ownerPID == pid,
                  let boundsDict = windowInfo[kCGWindowBounds as String] as? [String: Any],
                  let boundsRect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else {
                continue
            }
            if boundsRect.width >= screenFrame.width && boundsRect.height >= screenFrame.height {
                return true
            }
        }
        return false
    }

    // MARK: - Suppression-degraded detection

    private func subscribeToSettingsChangedNotification() {
        settingsChangedObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.sound.settingsChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleSettingsChangedNotification()
            }
        }
    }

    private func handleSettingsChangedNotification() {
        guard let lastSwallow = lastSwallowedKeyTime else { return }
        let elapsed = DispatchTime.now().uptimeNanoseconds &- lastSwallow.uptimeNanoseconds
        let elapsedMs = elapsed / 1_000_000
        if elapsedMs <= 500 && !mediaKeyStatus.suppressionDegraded {
            mediaKeyStatus.suppressionDegraded = true
            logger.warning("Suppression degraded: native sound handler fired within \(elapsedMs)ms of our swallow")
        }
    }
}

// MARK: - Per-app HUD content

private enum PerAppHUDContent {
    case volume(sliderFraction: Double)
    case mute(isMuted: Bool)
    case notControlled
}

private struct PerAppHUD: View {
    let icon: NSImage?
    let title: String
    let content: PerAppHUDContent

    private static let frameWidth: CGFloat = 300
    private static let frameHeight: CGFloat = 72
    private static let cornerRadius: CGFloat = 22
    private static let percentageWidth: CGFloat = 36
    private static let iconSize: CGFloat = 28
    private static let barHeight: CGFloat = 4

    private var subtitleText: String? {
        if case .notControlled = content { return L10n.string("Not controlled by FineTune") }
        return nil
    }

    private var displayLevel: Double {
        switch content {
        case .volume(let sliderFraction): return max(0, min(1, sliderFraction))
        case .mute(let isMuted): return isMuted ? 0 : 1
        case .notControlled: return 0
        }
    }

    private var displayedPercent: Int {
        Int((displayLevel * 100).rounded())
    }

    private var isMutedDisplay: Bool {
        switch content {
        case .mute(let isMuted): return isMuted
        case .volume: return displayedPercent == 0
        case .notControlled: return false
        }
    }

    private var waveIconName: String {
        switch displayedPercent {
        case 0:        return "speaker.fill"
        case 1...33:   return "speaker.wave.1.fill"
        case 34...66:  return "speaker.wave.2.fill"
        default:       return "speaker.wave.3.fill"
        }
    }

    private var percentageText: String {
        "\(displayedPercent)%"
    }

    private var accessibilityDescription: String {
        switch content {
        case .volume:
            return L10n.format("%@, volume %lld percent", title, Int((displayLevel * 100).rounded()))
        case .mute(let isMuted):
            return isMuted ? L10n.format("%@, muted", title) : L10n.format("%@, unmuted", title)
        case .notControlled:
            return L10n.format("%@, not controlled by FineTune", title)
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            iconView
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(TahoeStyleHUD.nameFont)
                    .foregroundStyle(DesignTokens.Colors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                trailingRow
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .frame(width: Self.frameWidth, height: Self.frameHeight)
        .glassStyle(cornerRadius: Self.cornerRadius, borderColor: DesignTokens.Colors.hudBorder, borderWidth: 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
    }

    @ViewBuilder
    private var iconView: some View {
        if let icon {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: Self.iconSize, height: Self.iconSize)
        } else {
            Image(systemName: "app.dashed")
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(DesignTokens.Colors.textSecondary)
                .frame(width: Self.iconSize, height: Self.iconSize)
        }
    }

    @ViewBuilder
    private var trailingRow: some View {
        switch content {
        case .volume:
            HStack(spacing: 8) {
                Image(systemName: isMutedDisplay ? "speaker.slash.fill" : waveIconName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isMutedDisplay
                                     ? DesignTokens.Colors.mutedIndicator
                                     : DesignTokens.Colors.hudTileActive)
                    .frame(width: 18, height: 18, alignment: .center)

                progressBar
                    .opacity(isMutedDisplay ? 0.5 : 1.0)

                Text(percentageText)
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
                    .frame(width: Self.percentageWidth, alignment: .trailing)
            }
        case .mute(let isMuted):
            HStack(spacing: 8) {
                Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isMuted
                                     ? DesignTokens.Colors.mutedIndicator
                                     : DesignTokens.Colors.hudTileActive)
                    .frame(width: 18, height: 18, alignment: .center)
                Text(L10n.string(isMuted ? "Muted" : "Unmuted"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
                Spacer(minLength: 0)
            }
        case .notControlled:
            if let subtitleText {
                Text(subtitleText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(DesignTokens.Colors.textSecondary.opacity(0.25))
                    .frame(height: Self.barHeight)
                Capsule()
                    .fill(DesignTokens.Colors.hudTileActive)
                    .frame(width: geo.size.width * CGFloat(displayLevel), height: Self.barHeight)
            }
            .frame(maxHeight: .infinity)
        }
        .frame(height: Self.barHeight + 8)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
