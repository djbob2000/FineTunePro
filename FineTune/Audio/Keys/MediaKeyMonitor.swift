// FineTune/Audio/Keys/MediaKeyMonitor.swift
import AppKit
import AudioToolbox
import CoreGraphics
import os

/// View-layer collaborators MediaKeyMonitor drives. Abstracting them keeps the audio
/// layer free of concrete view types (HUDWindowController, MenuBarIconCoordinator);
/// the view layer supplies the conformances.
@MainActor
protocol MediaKeyHUDPresenting: AnyObject {
    func show(sliderFraction: Double, mute: Bool, deviceName: String)
    func swallowObserved()
}

@MainActor
protocol MediaKeyIconFlashing: AnyObject {
    func flashDevice()
}

/// Intercepts F10/F11/F12 via a `CGEventTap`, swallows them so the native HUD
/// does not double-fire, and drives the default output device.
@MainActor
final class MediaKeyMonitor {
    // MARK: - Collaborators

    private let decoder: any MediaKeyEventDecoding
    private let audioEngine: AudioEngine
    private let settingsManager: SettingsManager
    private let accessibility: any AccessibilityTrustProviding
    private let hudController: MediaKeyHUDPresenting
    private let popupVisibility: PopupVisibilityService
    private let mediaKeyStatus: MediaKeyStatus
    private let logger = Logger(subsystem: "com.finetuneapp.FineTune", category: "MediaKeyMonitor")
    private let lifecycle: CGEventTapLifecycle

    // MARK: - Tap state

    /// 80 ms floor between DDC-tier repeats — DDC write queues saturate at key-repeat rate.
    var lastDDCRepeatTime: DispatchTime?

    var onRunLoopSourceRemoved: (() -> Void)? {
        get { lifecycle.onRunLoopSourceRemoved }
        set { lifecycle.onRunLoopSourceRemoved = newValue }
    }

    var watchdogOpen: Bool { lifecycle.watchdogOpen }

    /// Optional coordinator notified on every volume/mute key event so the menu bar icon
    /// can flash the current device's transport symbol. Wired by FineTuneApp after init.
    var iconCoordinator: MediaKeyIconFlashing?

    /// Plays the system volume-feedback pop on volume key steps. Wired by FineTuneApp after init.
    var feedbackPlayer: VolumeFeedbackPlayer?

    nonisolated(unsafe) private let settingsLock = NSLock()
    nonisolated(unsafe) private var cachedMediaKeyControlEnabled: Bool = false

    nonisolated var isMediaKeyControlEnabled: Bool {
        settingsLock.lock()
        defer { settingsLock.unlock() }
        return cachedMediaKeyControlEnabled
    }

    private func updateCachedSettings() {
        settingsLock.lock()
        defer { settingsLock.unlock() }
        cachedMediaKeyControlEnabled = settingsManager.appSettings.mediaKeyControlEnabled
    }

    init(
        decoder: any MediaKeyEventDecoding,
        audioEngine: AudioEngine,
        settingsManager: SettingsManager,
        accessibility: any AccessibilityTrustProviding,
        hudController: MediaKeyHUDPresenting,
        popupVisibility: PopupVisibilityService,
        mediaKeyStatus: MediaKeyStatus
    ) {
        self.decoder = decoder
        self.audioEngine = audioEngine
        self.settingsManager = settingsManager
        self.accessibility = accessibility
        self.hudController = hudController
        self.popupVisibility = popupVisibility
        self.mediaKeyStatus = mediaKeyStatus
        self.lifecycle = CGEventTapLifecycle(logger: logger)
        updateCachedSettings()

        lifecycle.onGhostTapDisabled = { [weak self] in
            self?.mediaKeyStatus.isOffline = true
        }
        lifecycle.onDoubleDisable = { [weak self] in
            self?.mediaKeyStatus.isOffline = true
        }
        lifecycle.onWakeNeedsReconcile = { [weak self] in
            self?.reconcile()
        }
    }

    isolated deinit {
        lifecycle.teardown()
    }

    // MARK: - Lifecycle

    /// Idempotent. No-op unless media keys are enabled and Accessibility is trusted.
    func start() {
        updateCachedSettings()
        guard !lifecycle.isInstalled else { return }
        guard cachedMediaKeyControlEnabled else {
            logger.debug("Media key control disabled in settings; tap not installed")
            return
        }
        guard accessibility.isTrusted else {
            logger.info("Accessibility not trusted; tap not installed")
            return
        }

        // NX_SYSDEFINED = 14 (from <IOLLEvent.h>); CGEventType has no Swift case.
        let mask = CGEventMask(1 << 14)
        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        let ok = lifecycle.install(
            eventsOfInterest: mask,
            callback: mediaKeyTapCallback,
            userInfo: userInfo
        )
        if ok {
            mediaKeyStatus.isOffline = false
            logger.info("Media key tap installed")
        } else {
            mediaKeyStatus.isOffline = true
            logger.error("CGEvent.tapCreate returned nil — media keys will not be intercepted")
        }
    }

    /// Reconciles tap state against settings + Accessibility trust. Idempotent.
    /// When offline, tears down and reinstalls so Retry actually recovers.
    func reconcile() {
        updateCachedSettings()
        if cachedMediaKeyControlEnabled && accessibility.isTrusted {
            if mediaKeyStatus.isOffline {
                lifecycle.stop()
                mediaKeyStatus.isOffline = false
            }
            let wasOffline = !lifecycle.isInstalled
            start()
            if wasOffline && lifecycle.isInstalled {
                lifecycle.armGhostTapProbe()
            }
        } else {
            lifecycle.cancelGhostTapProbe()
            lifecycle.stop()
            // Intentional off / no trust is not the kernel-stall card.
            mediaKeyStatus.isOffline = false
        }
    }

    /// Tears down the tap + runloop source. Must be called before dealloc.
    func stop() {
        lifecycle.stop()
    }

    // MARK: - Event handling

    /// Applies a decoded `MediaKeyEvent` to the default output device.
    func handle(_ event: MediaKeyEvent, shiftHeld: Bool = false, optionHeld: Bool = false) {
        let volumeMonitor = audioEngine.deviceVolumeMonitor
        let deviceID = volumeMonitor.defaultDeviceID
        guard deviceID.isValid else {
            logger.debug("Ignoring media key: no valid default output device")
            return
        }
        let tier = volumeMonitor.outputVolumeBackend(for: deviceID)
        let deviceName = audioEngine.deviceMonitor.outputDevices.first { $0.id == deviceID }?.name ?? ""
        handleCore(
            event: event,
            deviceID: deviceID,
            tier: tier,
            deviceName: deviceName,
            currentVolume: volumeMonitor.volumes[deviceID] ?? 0,
            currentMute: volumeMonitor.muteStates[deviceID] ?? false,
            setVolume: { id, vol in volumeMonitor.setVolume(for: id, to: vol) },
            setMute:   { id, mute in volumeMonitor.setMute(for: id, to: mute) },
            getVolume: { id in volumeMonitor.volumes[id] ?? 0 },
            playFeedback: { gain in
                self.feedbackPlayer?.requestFeedback(
                    gain: gain,
                    shiftHeld: shiftHeld,
                    optionHeld: optionHeld
                )
            }
        )
    }

    /// `.ddc` tier coalesces repeats to an 80 ms floor; hardware/software pass them through.
    /// Mute repeats are dropped upstream. Stepping operates on slider-position; HUD receives
    /// the slider fraction so it always matches the popup device row.
    func handleCore(
        event: MediaKeyEvent,
        deviceID: AudioDeviceID,
        tier: VolumeControlTier,
        deviceName: String,
        currentVolume: Float,
        currentMute: Bool,
        setVolume: (AudioDeviceID, Float) -> Void,
        setMute: (AudioDeviceID, Bool) -> Void,
        getVolume: ((AudioDeviceID) -> Float)? = nil,
        playFeedback: (Float) -> Void = { _ in }
    ) {
        let shouldShowHUD = !popupVisibility.isVisible
        let sliderDelta = settingsManager.appSettings.volumeHotkeyStep.sliderDelta
        let currentSlider = VolumeMapping.sliderFraction(forSystemGain: currentVolume, tier: tier)

        switch event {
        case .volumeUp(let isRepeat):
            if isRepeat && tier == .ddc && isDDCRepeatCoalesced() {
                logger.debug("DDC repeat coalesced")
                return
            }
            let nextSlider = min(1.0, currentSlider + sliderDelta)
            let newVolume = VolumeMapping.systemGain(forSliderFraction: nextSlider, tier: tier)
            // Volume-up from muted unmutes (system HUD parity).
            if currentMute {
                setMute(deviceID, false)
            }
            setVolume(deviceID, newVolume)
            playFeedback(VolumeFeedback.gain(tier: tier, sliderFraction: nextSlider))
            if shouldShowHUD {
                hudController.show(sliderFraction: nextSlider, mute: false, deviceName: deviceName)
            }
            iconCoordinator?.flashDevice()

        case .volumeDown(let isRepeat):
            if isRepeat && tier == .ddc && isDDCRepeatCoalesced() {
                logger.debug("DDC repeat coalesced")
                return
            }
            let nextSlider = max(0, currentSlider - sliderDelta)
            let newVolume = VolumeMapping.systemGain(forSliderFraction: nextSlider, tier: tier)
            let willBeSilent = nextSlider <= 0.001
            // muted+audible → unmute; unmuted+silent → auto-mute (system HUD parity).
            if currentMute && !willBeSilent {
                setMute(deviceID, false)
            } else if !currentMute && willBeSilent {
                setMute(deviceID, true)
            }
            setVolume(deviceID, newVolume)
            playFeedback(VolumeFeedback.gain(tier: tier, sliderFraction: nextSlider))
            if shouldShowHUD {
                hudController.show(sliderFraction: nextSlider, mute: willBeSilent, deviceName: deviceName)
            }
            iconCoordinator?.flashDevice()

        case .muteToggle:
            let newMute = !currentMute
            setMute(deviceID, newMute)
            if shouldShowHUD {
                // Software-tier mute zeroes the visible volume and unmute restores
                // the saved level inside setMute, so the pre-toggle snapshot reads
                // 0% after unmuting — re-read to show the restored level.
                let slider: Double
                if !newMute, let getVolume {
                    slider = VolumeMapping.sliderFraction(forSystemGain: getVolume(deviceID), tier: tier)
                } else {
                    slider = currentSlider
                }
                hudController.show(sliderFraction: slider, mute: newMute, deviceName: deviceName)
            }
            iconCoordinator?.flashDevice()
        }
    }

    /// `true` if this repeat falls inside the 80 ms floor and should be dropped.
    private func isDDCRepeatCoalesced() -> Bool {
        let now = DispatchTime.now()
        if let last = lastDDCRepeatTime {
            let deltaNs = now.uptimeNanoseconds &- last.uptimeNanoseconds
            if deltaNs < 80 * 1_000_000 { return true }
        }
        lastDDCRepeatTime = now
        return false
    }

    // MARK: - Tap-disabled watchdog

    /// Kernel disabled the tap. One-shot re-enable; second disable inside 5s marks offline.
    func handleTapDisabled() {
        // Runtime Accessibility revocation — tear down and let the permission card surface.
        // `isOffline` stays false here; it's reserved for kernel-stall ("Retry") scenarios.
        lifecycle.handleTapDisabled(isAccessibilityTrusted: accessibility.isTrusted) { [weak self] in
            self?.accessibility.refresh()
        }
    }

    // MARK: - Callback bridge

    /// Returns `true` if the caller should swallow the event.
    nonisolated func processSystemDefined(_ cgEvent: CGEvent) -> Bool {
        // Pass through if disabled mid-race; never silently eat another app's media keys.
        guard isMediaKeyControlEnabled else { return false }
        guard let nsEvent = NSEvent(cgEvent: cgEvent) else { return false }
        // Subtype 8 is the media-key channel; aux-button / brightness are pass-through.
        guard nsEvent.subtype.rawValue == 8 else { return false }
        let data1 = nsEvent.data1
        guard let mediaEvent = decoder.decode(data1: data1) else { return false }

        let shiftHeld = cgEvent.flags.contains(.maskShift)
        let optionHeld = cgEvent.flags.contains(.maskAlternate)

        Task { @MainActor in
            hudController.swallowObserved()
            handle(
                mediaEvent,
                shiftHeld: shiftHeld,
                optionHeld: optionHeld
            )
        }
        return true
    }
}

// MARK: - CGEventTap C callback

// Tap installs on `CFRunLoopGetMain()` so this runs on main.
private let mediaKeyTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
    guard let userInfo = userInfo else {
        return Unmanaged.passUnretained(event)
    }
    let monitor = Unmanaged<MediaKeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        Task { @MainActor in
            monitor.handleTapDisabled()
        }
        return nil
    }

    // NX_SYSDEFINED = 14; no Swift case in CGEventType.
    guard type.rawValue == 14 else {
        return Unmanaged.passUnretained(event)
    }

    let shouldSwallow = monitor.processSystemDefined(event)
    return shouldSwallow ? nil : Unmanaged.passUnretained(event)
}
