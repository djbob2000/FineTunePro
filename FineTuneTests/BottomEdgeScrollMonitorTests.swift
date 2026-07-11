// FineTuneTests/BottomEdgeScrollMonitorTests.swift
import Testing
import AppKit
import Foundation
import AudioToolbox
@testable import FineTune

@Suite("BottomEdgeScrollMonitor Tests")
@MainActor
struct BottomEdgeScrollMonitorTests {

    private func makeMonitor(
        volumeSlider: Double = 0.5,
        muted: Bool = false,
        volumeHotkeyStep: VolumeHotkeyStep = .normal,
        defaultDeviceID: UInt32 = 1,
        bottomEdgeEnabled: Bool = true,
        isTrusted: Bool = true
    ) -> (
        BottomEdgeScrollMonitor,
        MockDeviceVolumeProviding,
        SettingsManager,
        EventTapStatus,
        MockAccessibilityTrustProviding
    ) {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let settings = SettingsManager(directory: tempDir)
        var appSettings = settings.appSettings
        appSettings.volumeHotkeyStep = volumeHotkeyStep
        appSettings.bottomEdgeScrollEnabled = bottomEdgeEnabled
        settings.updateAppSettings(appSettings)

        let deviceMonitor = MockAudioDeviceMonitor()
        let device = AudioDevice(
            id: 1,
            uid: "test-device",
            name: "Test Device",
            icon: nil,
            supportsAutoEQ: false,
            transportType: .unknown
        )
        deviceMonitor.addOutputDevice(device)

        let mockVolume = MockDeviceVolumeProviding(deviceMonitor: deviceMonitor)
        mockVolume.defaultDeviceID = defaultDeviceID
        mockVolume.volumes[1] = VolumeMapping.systemGain(forSliderFraction: volumeSlider, tier: .software)
        mockVolume.muteStates[1] = muted
        mockVolume.defaultTier = .software

        let engine = AudioEngine(
            permission: AudioRecordingPermission(),
            settingsManager: settings,
            autoEQProfileManager: AutoEQProfileManager(),
            deviceProvider: deviceMonitor,
            deviceVolumeMonitor: mockVolume,
            startMonitorsAutomatically: false
        )

        let popup = PopupVisibilityService()
        let status = MediaKeyStatus()
        let tapStatus = EventTapStatus()
        let hud = HUDWindowController(settingsManager: settings, mediaKeyStatus: status, popupVisibility: popup)
        hud.frameProvider = { NSRect(x: 0, y: 0, width: 1440, height: 900) }
        hud.foregroundAppFullscreenProvider = { false }

        let accessibility = MockAccessibilityTrustProviding(isTrusted: isTrusted)
        let monitor = BottomEdgeScrollMonitor(
            audioEngine: engine,
            settingsManager: settings,
            accessibility: accessibility,
            hudController: hud,
            popupVisibility: popup,
            eventTapStatus: tapStatus
        )
        return (monitor, mockVolume, settings, tapStatus, accessibility)
    }

    // MARK: - handleScroll

    @Test("handleScroll scrolling up physically increases volume by volumeHotkeyStep")
    func handleScrollUp() {
        let (monitor, volumeProvider, _, _, _) = makeMonitor(volumeHotkeyStep: .fine) // 1/32
        monitor.handleScroll(deltaY: 1.0, hasPrecise: false, isDirectionInverted: false)

        let expected = VolumeMapping.systemGain(
            forSliderFraction: 0.5 + VolumeHotkeyStep.fine.sliderDelta,
            tier: .software
        )
        #expect(abs(volumeProvider.volumes[1]! - expected) < 1e-4)
    }

    @Test("handleScroll scrolling down physically decreases volume")
    func handleScrollDown() {
        let (monitor, volumeProvider, _, _, _) = makeMonitor(volumeHotkeyStep: .fine)
        monitor.handleScroll(deltaY: -1.0, hasPrecise: false, isDirectionInverted: false)

        let expected = VolumeMapping.systemGain(
            forSliderFraction: 0.5 - VolumeHotkeyStep.fine.sliderDelta,
            tier: .software
        )
        #expect(abs(volumeProvider.volumes[1]! - expected) < 1e-4)
    }

    @Test("handleScroll inverted direction flips physical sense")
    func handleScrollInverted() {
        let (monitor, volumeProvider, _, _, _) = makeMonitor(volumeHotkeyStep: .fine)
        // Positive deltaY with inverted device → volume down
        monitor.handleScroll(deltaY: 1.0, hasPrecise: false, isDirectionInverted: true)

        let expected = VolumeMapping.systemGain(
            forSliderFraction: 0.5 - VolumeHotkeyStep.fine.sliderDelta,
            tier: .software
        )
        #expect(abs(volumeProvider.volumes[1]! - expected) < 1e-4)
    }

    @Test("handleScroll clamps at maximum")
    func handleScrollClampsMax() {
        let (monitor, volumeProvider, _, _, _) = makeMonitor(volumeSlider: 0.99, volumeHotkeyStep: .coarse)
        monitor.handleScroll(deltaY: 1.0, hasPrecise: false, isDirectionInverted: false)

        let expected = VolumeMapping.systemGain(forSliderFraction: 1.0, tier: .software)
        #expect(abs(volumeProvider.volumes[1]! - expected) < 1e-4)
    }

    @Test("handleScroll clamps at minimum")
    func handleScrollClampsMin() {
        let (monitor, volumeProvider, _, _, _) = makeMonitor(volumeSlider: 0.01, volumeHotkeyStep: .coarse)
        monitor.handleScroll(deltaY: -1.0, hasPrecise: false, isDirectionInverted: false)

        let expected = VolumeMapping.systemGain(forSliderFraction: 0.0, tier: .software)
        #expect(abs(volumeProvider.volumes[1]! - expected) < 1e-4)
        #expect(volumeProvider.muteStates[1] == true)
    }

    @Test("handleScroll mute at zero unmutes on scroll up")
    func handleScrollUnmutesFromSilence() {
        let (monitor, volumeProvider, _, _, _) = makeMonitor(
            volumeSlider: 0.0,
            muted: true,
            volumeHotkeyStep: .normal
        )
        monitor.handleScroll(deltaY: 1.0, hasPrecise: false, isDirectionInverted: false)

        #expect(volumeProvider.muteStates[1] == false)
        let expected = VolumeMapping.systemGain(
            forSliderFraction: VolumeHotkeyStep.normal.sliderDelta,
            tier: .software
        )
        #expect(abs(volumeProvider.volumes[1]! - expected) < 1e-4)
    }

    @Test("handleScroll to silence auto-mutes")
    func handleScrollAutoMutesAtZero() {
        let (monitor, volumeProvider, _, _, _) = makeMonitor(
            volumeSlider: VolumeHotkeyStep.normal.sliderDelta,
            muted: false,
            volumeHotkeyStep: .normal
        )
        monitor.handleScroll(deltaY: -1.0, hasPrecise: false, isDirectionInverted: false)

        #expect(volumeProvider.muteStates[1] == true)
        let expected = VolumeMapping.systemGain(forSliderFraction: 0.0, tier: .software)
        #expect(abs(volumeProvider.volumes[1]! - expected) < 1e-4)
    }

    @Test("handleScroll with invalid device is a no-op")
    func handleScrollInvalidDevice() {
        let (monitor, volumeProvider, _, _, _) = makeMonitor(defaultDeviceID: 0)
        let before = volumeProvider.volumes[1]
        monitor.handleScroll(deltaY: 1.0, hasPrecise: false, isDirectionInverted: false)
        #expect(volumeProvider.volumes[1] == before)
    }

    @Test("handleScroll precise events apply immediately on software tier (no lost pending)")
    func handleScrollPreciseAppliesImmediately() {
        let (monitor, volumeProvider, _, _, _) = makeMonitor(volumeHotkeyStep: .normal)
        let step = VolumeHotkeyStep.normal.sliderDelta
        // 25 precise points → half step each; both must apply (trackpad spam must not drop motion)
        monitor.handleScroll(deltaY: 25, hasPrecise: true, isDirectionInverted: false)
        monitor.handleScroll(deltaY: 25, hasPrecise: true, isDirectionInverted: false)
        let expected = VolumeMapping.systemGain(forSliderFraction: 0.5 + step, tier: .software)
        #expect(abs(volumeProvider.volumes[1]! - expected) < 1e-4)
        #expect(monitor.pendingPreciseChange == 0)
    }

    @Test("handleScroll fine precise steps accumulate visibly")
    func handleScrollFinePreciseAccumulates() {
        let (monitor, volumeProvider, _, _, _) = makeMonitor(volumeHotkeyStep: .fine)
        let step = VolumeHotkeyStep.fine.sliderDelta
        // ~50 precise points ≈ one full fine step
        for _ in 0..<5 {
            monitor.handleScroll(deltaY: 10, hasPrecise: true, isDirectionInverted: false)
        }
        let expected = VolumeMapping.systemGain(forSliderFraction: 0.5 + step, tier: .software)
        #expect(abs(volumeProvider.volumes[1]! - expected) < 1e-4)
    }

    @Test("handleScroll scrolling up from hardware silence/mute with a small precise delta jumps to minAudibleSlider (0.01) and unmutes")
    func handleScrollUpFromSilenceHardwarePrecise() {
        let (monitor, volumeProvider, _, _, _) = makeMonitor(
            volumeSlider: 0.0,
            muted: true,
            volumeHotkeyStep: .normal
        )
        volumeProvider.defaultTier = .hardware
        volumeProvider.volumes[1] = 0.0

        // 1 precise point delta -> change of 0.00125
        monitor.handleScroll(deltaY: 1.0, hasPrecise: true, isDirectionInverted: false)

        #expect(volumeProvider.muteStates[1] == false)
        #expect(abs(volumeProvider.volumes[1]! - 0.01) < 1e-4)
    }

    @Test("handleScroll scrolling down below minAudibleSlider (0.01) on hardware tier auto-mutes")
    func handleScrollDownBelowMinAudibleHardware() {
        let (monitor, volumeProvider, _, _, _) = makeMonitor(
            volumeSlider: 0.0,
            muted: false,
            volumeHotkeyStep: .normal
        )
        volumeProvider.defaultTier = .hardware
        volumeProvider.volumes[1] = 0.012

        // Precise scroll down by -2 points -> change is -2 * 0.0625 / 50.0 = -0.0025
        // nextSlider = 0.012 - 0.0025 = 0.0095 (< 0.01)
        monitor.handleScroll(deltaY: -2.0, hasPrecise: true, isDirectionInverted: false)

        #expect(volumeProvider.muteStates[1] == true)
        #expect(abs(volumeProvider.volumes[1]! - 0.0095) < 1e-4)
    }

    // MARK: - Pure helpers

    @Test("isAtBottomEdge hits bottom strip and misses above")
    func bottomEdgeGeometry() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let threshold = BottomEdgeScrollMonitor.edgeThreshold
        #expect(BottomEdgeScrollMonitor.isAtBottomEdge(
            point: CGPoint(x: 100, y: 4),
            screens: [screen],
            threshold: threshold
        ))
        // Dock-height region (~30pt) must hit with default 48pt threshold
        #expect(BottomEdgeScrollMonitor.isAtBottomEdge(
            point: CGPoint(x: 100, y: 30),
            screens: [screen],
            threshold: threshold
        ))
        #expect(!BottomEdgeScrollMonitor.isAtBottomEdge(
            point: CGPoint(x: 100, y: threshold + 10),
            screens: [screen],
            threshold: threshold
        ))
        #expect(!BottomEdgeScrollMonitor.isAtBottomEdge(
            point: CGPoint(x: 100, y: 4),
            screens: [],
            threshold: threshold
        ))
    }

    @Test("isAtBottomEdge multi-monitor hits secondary bottom and misses gap")
    func bottomEdgeMultiMonitor() {
        let primary = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let secondary = CGRect(x: 1440, y: -200, width: 1920, height: 1080)
        let threshold = BottomEdgeScrollMonitor.edgeThreshold
        // Bottom strip of secondary (minY = -200)
        #expect(BottomEdgeScrollMonitor.isAtBottomEdge(
            point: CGPoint(x: 1500, y: -196),
            screens: [primary, secondary],
            threshold: threshold
        ))
        // Above secondary bottom strip
        #expect(!BottomEdgeScrollMonitor.isAtBottomEdge(
            point: CGPoint(x: 1500, y: 100),
            screens: [primary, secondary],
            threshold: threshold
        ))
        // In the horizontal gap between screens — not contained
        #expect(!BottomEdgeScrollMonitor.isAtBottomEdge(
            point: CGPoint(x: -50, y: 4),
            screens: [primary, secondary],
            threshold: threshold
        ))
    }

    @Test("isAtBottomEdgeQuartz uses high-Y as bottom (CGEvent space)")
    func bottomEdgeQuartzGeometry() {
        // Quartz: origin top-left, y increases downward. Bottom = high Y.
        let primary = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let threshold = BottomEdgeScrollMonitor.edgeThreshold
        #expect(BottomEdgeScrollMonitor.isAtBottomEdgeQuartz(
            point: CGPoint(x: 100, y: 896),
            displayBounds: [primary],
            threshold: threshold
        ))
        #expect(BottomEdgeScrollMonitor.isAtBottomEdgeQuartz(
            point: CGPoint(x: 100, y: 870),
            displayBounds: [primary],
            threshold: threshold
        ))
        #expect(!BottomEdgeScrollMonitor.isAtBottomEdgeQuartz(
            point: CGPoint(x: 100, y: 100),
            displayBounds: [primary],
            threshold: threshold
        ))
        // External display above primary (negative y origin in Quartz)
        let external = CGRect(x: -100, y: -1080, width: 1920, height: 1080)
        // Bottom of external is near y=0
        #expect(BottomEdgeScrollMonitor.isAtBottomEdgeQuartz(
            point: CGPoint(x: 200, y: -10),
            displayBounds: [primary, external],
            threshold: threshold
        ))
        #expect(!BottomEdgeScrollMonitor.isAtBottomEdgeQuartz(
            point: CGPoint(x: 200, y: -500),
            displayBounds: [primary, external],
            threshold: threshold
        ))
    }

    @Test("start() with trust keeps NSEvent even when CG tap cannot install")
    func startKeepsNSEventWithoutTap() {
        let (monitor, _, _, tapStatus, _) = makeMonitor(isTrusted: true)
        monitor.start()
        // Test host usually cannot install CGEventTap; NSEvent must still be active.
        #expect(monitor.isNSEventMonitoring == true)
        #expect(tapStatus.isOffline == false)
        monitor.stop()
        #expect(monitor.isNSEventMonitoring == false)
    }

    @Test("sliderChange discrete steps use sign of physical delta")
    func sliderChangeDiscrete() {
        let step = VolumeHotkeyStep.normal.sliderDelta
        #expect(BottomEdgeScrollMonitor.sliderChange(
            deltaY: 3, hasPrecise: false, isDirectionInverted: false, step: step
        ) == step)
        #expect(BottomEdgeScrollMonitor.sliderChange(
            deltaY: -2, hasPrecise: false, isDirectionInverted: false, step: step
        ) == -step)
        #expect(BottomEdgeScrollMonitor.sliderChange(
            deltaY: 0, hasPrecise: false, isDirectionInverted: false, step: step
        ) == nil)
    }

    @Test("sliderChange precise scales by points-per-step")
    func sliderChangePrecise() {
        let step = 0.1
        // 50 precise points → one full step
        let change = BottomEdgeScrollMonitor.sliderChange(
            deltaY: 50, hasPrecise: true, isDirectionInverted: false, step: step
        )
        #expect(change != nil)
        #expect(abs(change! - step) < 1e-9)
    }

    // MARK: - Lifecycle / offline

    @Test("start() with bottomEdgeScrollEnabled=false does not mark offline")
    func startDisabledDoesNotGoOffline() {
        let (monitor, _, _, tapStatus, _) = makeMonitor(bottomEdgeEnabled: false)
        monitor.start()
        #expect(tapStatus.isOffline == false)
    }

    @Test("start() when Accessibility untrusted does not mark offline")
    func startUntrustedDoesNotGoOffline() {
        let (monitor, _, _, tapStatus, _) = makeMonitor(isTrusted: false)
        monitor.start()
        #expect(tapStatus.isOffline == false)
    }

    @Test("stop() is idempotent")
    func stopIdempotent() {
        let (monitor, _, _, _, _) = makeMonitor()
        monitor.stop()
        monitor.stop()
    }

    @Test("stop() clears pending precise change")
    func stopClearsPendingPrecise() {
        let (monitor, _, _, _, _) = makeMonitor()
        monitor.pendingPreciseChange = 0.05
        monitor.stop()
        #expect(monitor.pendingPreciseChange == 0)
    }

    @Test("Single tap-disabled leaves isOffline false and opens watchdog")
    func singleDisableDoesNotGoOffline() {
        let (monitor, _, _, tapStatus, _) = makeMonitor()
        monitor.handleTapDisabled()
        #expect(tapStatus.isOffline == false)
        #expect(monitor.watchdogOpen == true)
    }

    @Test("Double tap-disabled does not force offline when NSEvent fallback can remain")
    func doubleDisableDoesNotForceOffline() {
        let (monitor, _, _, tapStatus, _) = makeMonitor()
        // Install NSEvent path so double-disable of the CG tap is not total input loss.
        monitor.start()
        monitor.handleTapDisabled()
        monitor.handleTapDisabled()
        #expect(monitor.watchdogOpen == false)
        // Offline only if neither tap nor NSEvent is listening.
        if monitor.isNSEventMonitoring {
            #expect(tapStatus.isOffline == false)
        }
    }

    @Test("tap-disabled while untrusted refreshes Accessibility and stays online")
    func revocationBranch() {
        let (monitor, _, _, tapStatus, accessibility) = makeMonitor(isTrusted: false)
        monitor.handleTapDisabled()
        #expect(tapStatus.isOffline == false)
        #expect(monitor.watchdogOpen == false)
        #expect(accessibility.refreshCallCount == 1)
    }

    @Test("reconcile from offline stops watchdog before reinstall attempt")
    func reconcileFromOfflineResetsWatchdog() {
        let (monitor, _, _, tapStatus, _) = makeMonitor()
        monitor.handleTapDisabled()
        #expect(monitor.watchdogOpen == true)
        tapStatus.isOffline = true
        monitor.reconcile()
        #expect(monitor.watchdogOpen == false)
    }

    @Test("reconcile when disabled clears offline")
    func reconcileDisabledClearsOffline() {
        let (monitor, _, settings, tapStatus, _) = makeMonitor()
        tapStatus.isOffline = true
        var app = settings.appSettings
        app.bottomEdgeScrollEnabled = false
        settings.updateAppSettings(app)
        monitor.reconcile()
        #expect(tapStatus.isOffline == false)
    }
}
