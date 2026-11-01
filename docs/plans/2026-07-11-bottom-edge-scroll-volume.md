# Bottom Edge Scroll Volume Control Implementation Plan

> **For Antigravity:** REQUIRED WORKFLOW: Use `.agent/workflows/execute-plan.md` to execute this plan in single-flow mode.

**Goal:** Allow users to adjust system volume by scrolling their mouse wheel or trackpad while the cursor is positioned at the bottom boundary of any connected screen.

**Architecture:** Create a `BottomEdgeScrollMonitor` class that registers a `CGEventTap` for `.scrollWheel` events. When a scroll wheel event occurs at the bottom-most boundary of any screen, the event is swallowed and converted into a volume adjustment (using the configured step size), displaying the Tahoe/Classic HUD and playing the volume tick sound. A new toggle and custom step slider will be added to the General settings tab.

**Tech Stack:** Swift, SwiftUI, AppKit, CoreGraphics (CGEventTap)

---

### Task 1: Add new properties to AppSettings model

**Files:**
- Modify: `FineTune/Settings/SettingsManager.swift:25-103`

**Step 1: Write the failing test**

Modify `FineTuneTests/SettingsManagerTests.swift` to add a test asserting that `bottomEdgeScrollEnabled` defaults to `false` and `bottomEdgeScrollStep` defaults to `0.02` (2%), and that they persist correctly.

```swift
@Test("AppSettings has correct defaults for bottom-edge scroll and persists them")
func appSettingsBottomEdgeScrollDefaults() {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let settings = SettingsManager(directory: tempDir)
    
    // Check defaults
    #expect(settings.appSettings.bottomEdgeScrollEnabled == false)
    #expect(settings.appSettings.bottomEdgeScrollStep == 0.02)
    
    // Modify settings and check persistence
    var appSettings = settings.appSettings
    appSettings.bottomEdgeScrollEnabled = true
    appSettings.bottomEdgeScrollStep = 0.05
    settings.updateAppSettings(appSettings)
    
    let settingsReloaded = SettingsManager(directory: tempDir)
    #expect(settingsReloaded.appSettings.bottomEdgeScrollEnabled == true)
    #expect(settingsReloaded.appSettings.bottomEdgeScrollStep == 0.05)
}
```

**Step 2: Run test to verify it fails**

Run: `swift test --filter SettingsManagerTests` (or run it via Xcode / command line)
Expected: Fail (Compilation error: AppSettings does not have properties `bottomEdgeScrollEnabled` and `bottomEdgeScrollStep`)

**Step 3: Write minimal implementation**

In `FineTune/Settings/SettingsManager.swift`:
1. Add to `AppSettings`:
```swift
    // Bottom Edge Scroll
    var bottomEdgeScrollEnabled: Bool = false
    var bottomEdgeScrollStep: Float = 0.02
```
2. Decode the new properties in `AppSettings.init(from:)`:
```swift
        bottomEdgeScrollEnabled = try c.decodeIfPresent(Bool.self, forKey: .bottomEdgeScrollEnabled) ?? false
        bottomEdgeScrollStep = try c.decodeIfPresent(Float.self, forKey: .bottomEdgeScrollStep) ?? 0.02
```
3. Add a custom `Notification.Name` extension in the file for settings updates:
```swift
extension Notification.Name {
    static let appSettingsDidChange = Notification.Name("com.finetuneapp.FineTune.appSettingsDidChange")
}
```
4. Post `appSettingsDidChange` inside the `didSet` block of `appSettings` inside `SettingsManager`:
```swift
            settings.appSettings = appSettings
            scheduleSave()
            NotificationCenter.default.post(name: .appSettingsDidChange, object: nil)
```

**Step 4: Run test to verify it passes**

Run: `swift test --filter SettingsManagerTests`
Expected: PASS

**Step 5: Commit**

```bash
git add FineTune/Settings/SettingsManager.swift FineTuneTests/SettingsManagerTests.swift
git commit -m "feat: add bottom-edge scroll settings parameters to AppSettings"
```

---

### Task 2: Create BottomEdgeScrollMonitor

**Files:**
- Create: `FineTune/Audio/Keys/BottomEdgeScrollMonitor.swift`

**Step 1: Write the failing test**

We will write unit tests for the core scroll-handling logic first in `FineTuneTests/BottomEdgeScrollMonitorTests.swift`.

```swift
// FineTuneTests/BottomEdgeScrollMonitorTests.swift
import Testing
import AppKit
import Foundation
@testable import FineTune

@Suite("BottomEdgeScrollMonitor Tests")
@MainActor
struct BottomEdgeScrollMonitorTests {
    
    private func makeMonitor() -> (BottomEdgeScrollMonitor, MockDeviceVolumeProviding) {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let settings = SettingsManager(directory: tempDir)
        
        let deviceMonitor = MockAudioDeviceMonitor()
        let device = AudioDevice(id: 1, uid: "test-device", name: "Test Device", icon: nil, supportsAutoEQ: false, transportType: .unknown)
        deviceMonitor.addOutputDevice(device)
        
        let mockVolume = MockDeviceVolumeProviding(deviceMonitor: deviceMonitor)
        mockVolume.defaultDeviceID = 1
        mockVolume.volumes[1] = 0.5 // Start at 50%
        
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
        let hud = HUDWindowController(settingsManager: settings, mediaKeyStatus: status, popupVisibility: popup)
        hud.frameProvider = { NSRect(x: 0, y: 0, width: 1440, height: 900) }
        hud.foregroundAppFullscreenProvider = { false }
        
        let monitor = BottomEdgeScrollMonitor(
            audioEngine: engine,
            settingsManager: settings,
            accessibility: MockAccessibilityTrustProviding(isTrusted: true),
            hudController: hud,
            popupVisibility: popup
        )
        return (monitor, mockVolume)
    }
    
    @Test("handleScroll scrolling up physically increases volume")
    func handleScrollUp() {
        let (monitor, volumeProvider) = makeMonitor()
        var appSettings = monitor.settingsManager.appSettings
        appSettings.bottomEdgeScrollStep = 0.05
        monitor.settingsManager.updateAppSettings(appSettings)
        
        // Scroll physically UP (rolling forward): positive change
        let handled = monitor.handleScroll(deltaY: 1.0, hasPrecise: false, isDirectionInverted: false)
        #expect(handled == true)
        
        let expectedVolume = VolumeMapping.systemGain(forSliderFraction: 0.5 + 0.05, tier: .software)
        #expect(abs(volumeProvider.volumes[1]! - expectedVolume) < 1e-4)
    }
    
    @Test("handleScroll scrolling down physically decreases volume")
    func handleScrollDown() {
        let (monitor, volumeProvider) = makeMonitor()
        var appSettings = monitor.settingsManager.appSettings
        appSettings.bottomEdgeScrollStep = 0.05
        monitor.settingsManager.updateAppSettings(appSettings)
        
        // Scroll physically DOWN (rolling backward): negative change
        let handled = monitor.handleScroll(deltaY: -1.0, hasPrecise: false, isDirectionInverted: false)
        #expect(handled == true)
        
        let expectedVolume = VolumeMapping.systemGain(forSliderFraction: 0.5 - 0.05, tier: .software)
        #expect(abs(volumeProvider.volumes[1]! - expectedVolume) < 1e-4)
    }
}
```

**Step 2: Run test to verify it fails**

Run: `swift test --filter BottomEdgeScrollMonitorTests`
Expected: Fail (Compilation error: `BottomEdgeScrollMonitor` does not exist)

**Step 3: Write minimal implementation**

Create `FineTune/Audio/Keys/BottomEdgeScrollMonitor.swift`:

```swift
import AppKit
import CoreGraphics
import os

@MainActor
final class BottomEdgeScrollMonitor {
    private let audioEngine: AudioEngine
    let settingsManager: SettingsManager
    private let accessibility: any AccessibilityTrustProviding
    private let hudController: any MediaKeyHUDPresenting
    private let popupVisibility: PopupVisibilityService
    private let logger = Logger(subsystem: "com.finetuneapp.FineTune", category: "BottomEdgeScrollMonitor")

    var feedbackPlayer: VolumeFeedbackPlayer?
    var iconCoordinator: MediaKeyIconFlashing?

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var settingsObserver: NSObjectProtocol?

    init(
        audioEngine: AudioEngine,
        settingsManager: SettingsManager,
        accessibility: any AccessibilityTrustProviding,
        hudController: any MediaKeyHUDPresenting,
        popupVisibility: PopupVisibilityService
    ) {
        self.audioEngine = audioEngine
        self.settingsManager = settingsManager
        self.accessibility = accessibility
        self.hudController = hudController
        self.popupVisibility = popupVisibility
        
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .appSettingsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reconcile()
        }
    }

    deinit {
        stop()
        if let observer = settingsObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func start() {
        guard tap == nil else { return }
        guard settingsManager.appSettings.bottomEdgeScrollEnabled else { return }
        guard accessibility.isTrusted else { return }

        let mask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)
        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        guard let newTap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: bottomEdgeScrollTapCallback,
            userInfo: userInfo
        ) else {
            logger.error("CGEvent.tapCreate failed for BottomEdgeScrollMonitor")
            return
        }

        let source = CFMachPortCreateRunLoopSource(nil, newTap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: newTap, enable: true)

        self.tap = newTap
        self.runLoopSource = source
        logger.info("BottomEdgeScrollMonitor event tap installed")
    }

    func stop() {
        if let tap = tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            self.tap = nil
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            self.runLoopSource = nil
        }
        logger.info("BottomEdgeScrollMonitor event tap stopped")
    }

    func reconcile() {
        if settingsManager.appSettings.bottomEdgeScrollEnabled && accessibility.isTrusted {
            start()
        } else {
            stop()
        }
    }

    func processScrollWheel(_ event: CGEvent) -> Bool {
        guard let nsEvent = NSEvent(cgEvent: event) else { return false }
        
        let mouseLocation = NSEvent.mouseLocation
        let screens = NSScreen.screens
        guard let screen = screens.first(where: { $0.frame.contains(mouseLocation) }) else {
            return false
        }
        
        let threshold: CGFloat = 4.0
        guard mouseLocation.y <= screen.frame.minY + threshold else {
            return false
        }
        
        let deltaY = nsEvent.scrollingDeltaY
        let hasPrecise = nsEvent.hasPreciseScrollingDeltas
        let isMomentum = nsEvent.momentumPhase != []
        let isDirectionInverted = nsEvent.isDirectionInvertedFromDevice
        
        if isMomentum {
            return true
        }
        
        guard deltaY != 0 else { return false }
        
        Task { @MainActor in
            _ = self.handleScroll(
                deltaY: deltaY,
                hasPrecise: hasPrecise,
                isDirectionInverted: isDirectionInverted
            )
        }
        
        return true
    }

    func handleScroll(deltaY: CGFloat, hasPrecise: Bool, isDirectionInverted: Bool) -> Bool {
        var physicalDelta = deltaY
        if isDirectionInverted {
            physicalDelta = -physicalDelta
        }
        
        let step = settingsManager.appSettings.bottomEdgeScrollStep
        let change: Float
        if hasPrecise {
            change = Float(physicalDelta) * (step * 0.2)
        } else {
            change = step * Float(physicalDelta > 0 ? 1.0 : -1.0)
        }
        
        let volumeMonitor = audioEngine.deviceVolumeMonitor
        let deviceID = volumeMonitor.defaultDeviceID
        guard deviceID.isValid else { return false }
        let tier = volumeMonitor.outputVolumeBackend(for: deviceID)
        let deviceName = audioEngine.deviceMonitor.outputDevices.first { $0.id == deviceID }?.name ?? ""
        
        let currentVolume = volumeMonitor.volumes[deviceID] ?? 0.0
        let currentMute = volumeMonitor.muteStates[deviceID] ?? false
        
        let currentSlider = VolumeMapping.sliderFraction(forSystemGain: currentVolume, tier: tier)
        let nextSlider = min(1.0, max(0.0, currentSlider + Double(change)))
        let newVolume = VolumeMapping.systemGain(forSliderFraction: nextSlider, tier: tier)
        let willBeSilent = nextSlider <= 0.001
        
        if currentMute && !willBeSilent {
            volumeMonitor.setMute(for: deviceID, to: false)
        } else if !currentMute && willBeSilent {
            volumeMonitor.setMute(for: deviceID, to: true)
        }
        
        volumeMonitor.setVolume(for: deviceID, to: newVolume)
        feedbackPlayer?.requestFeedback(gain: VolumeFeedback.gain(tier: tier, sliderFraction: nextSlider))
        
        if !popupVisibility.isVisible {
            hudController.show(sliderFraction: nextSlider, mute: willBeSilent, deviceName: deviceName)
        }
        iconCoordinator?.flashDevice()
        
        return true
    }
}

private let bottomEdgeScrollTapCallback: CGEventTapCallBack = { proxy, type, event, userInfo in
    guard let userInfo = userInfo else {
        return Unmanaged.passUnretained(event)
    }
    let monitor = Unmanaged<BottomEdgeScrollMonitor>.fromOpaque(userInfo).takeUnretainedValue()
    
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        Task { @MainActor in
            monitor.stop()
            monitor.start()
        }
        return nil
    }
    
    guard type == .scrollWheel else {
        return Unmanaged.passUnretained(event)
    }
    
    let shouldSwallow = monitor.processScrollWheel(event)
    return shouldSwallow ? nil : Unmanaged.passUnretained(event)
}
```

**Step 4: Run test to verify it passes**

Run: `swift test --filter BottomEdgeScrollMonitorTests`
Expected: PASS

**Step 5: Commit**

```bash
git add FineTune/Audio/Keys/BottomEdgeScrollMonitor.swift FineTuneTests/BottomEdgeScrollMonitorTests.swift
git commit -m "feat: create BottomEdgeScrollMonitor and tests"
```

---

### Task 3: Integrate BottomEdgeScrollMonitor into FineTuneApp and SettingsRootView

**Files:**
- Modify: `FineTune/FineTuneApp.swift:40-279`
- Modify: `FineTune/Views/Settings/SettingsRootView.swift`

**Step 1: Write the failing test**

We want to verify that `BottomEdgeScrollMonitor` compiles and instantiates. We will add a simple check in `FineTuneTests/BottomEdgeScrollMonitorTests.swift` to ensure we can initialize the monitor on main actor and check that it's off by default.

```swift
    @Test("BottomEdgeScrollMonitor initializes turned off by default")
    func bottomEdgeScrollMonitorOffByDefault() {
        let (monitor, _) = makeMonitor()
        #expect(monitor.settingsManager.appSettings.bottomEdgeScrollEnabled == false)
    }
```

**Step 2: Run test to verify it fails**

Run: `swift test --filter BottomEdgeScrollMonitorTests`
Expected: Pass

**Step 3: Write minimal implementation**

1. Modify `FineTune/FineTuneApp.swift`:
   - Add property `@State private var bottomEdgeScrollMonitor: BottomEdgeScrollMonitor?` (or non-optional `@State private var bottomEdgeScrollMonitor: BottomEdgeScrollMonitor`).
   - In `init()`, instantiate `bottomEdgeScrollMonitor`:
     ```swift
     let bottomEdgeScrollMonitor = BottomEdgeScrollMonitor(
         audioEngine: engine,
         settingsManager: settings,
         accessibility: accessibilityService,
         hudController: hud,
         popupVisibility: popupService
     )
     bottomEdgeScrollMonitor.feedbackPlayer = feedbackPlayer
     bottomEdgeScrollMonitor.iconCoordinator = coordinator
     ```
   - Wire `accessibilityService.onTrustChanged` callback to reconcile both monitors:
     ```swift
     accessibilityService.onTrustChanged = { [weak monitor, weak bottomEdgeScrollMonitor] _ in
         monitor?.reconcile()
         bottomEdgeScrollMonitor?.reconcile()
     }
     ```
   - Call reconcile on startup:
     ```swift
     monitor.reconcile()
     bottomEdgeScrollMonitor.reconcile()
     ```
   - Pass `bottomEdgeScrollMonitor` to `SettingsRootView` in `Settings {}` block:
     ```swift
             SettingsRootView(
                 settings: audioEngine.settingsManager,
                 audioEngine: audioEngine,
                 deviceVolumeMonitor: audioEngine.deviceVolumeMonitor as! DeviceVolumeMonitor,
                 accessibility: accessibility,
                 mediaKeyStatus: mediaKeyStatus,
                 mediaKeyMonitor: mediaKeyMonitor,
                 bottomEdgeScrollMonitor: bottomEdgeScrollMonitor,
                 shortcutsRegistry: shortcutsRegistry,
                 updateManager: updateManager
             )
     ```
   - Store it: `_bottomEdgeScrollMonitor = State(initialValue: bottomEdgeScrollMonitor)`

2. Modify `FineTune/Views/Settings/SettingsRootView.swift`:
   - Add parameter `let bottomEdgeScrollMonitor: BottomEdgeScrollMonitor`.
   - Pass it down to `GeneralTab`:
     ```swift
     GeneralTab(settings: settings, bottomEdgeScrollMonitor: bottomEdgeScrollMonitor, onResetAll: { ... })
     ```

**Step 4: Run test to verify it passes**

Run: `swift test`
Expected: PASS

**Step 5: Commit**

```bash
git add FineTune/FineTuneApp.swift FineTune/Views/Settings/SettingsRootView.swift
git commit -m "feat: integrate BottomEdgeScrollMonitor into App lifecycle"
```

---

### Task 4: Add Bottom Edge Scroll settings UI to GeneralTab

**Files:**
- Modify: `FineTune/Views/Settings/Tabs/GeneralTab.swift`

**Step 1: Write the failing test**

We verify that the app builds correctly after modifications to `GeneralTab.swift`.

**Step 2: Run test to verify it fails**

No compiler failure yet. Let's make the modification.

**Step 3: Write minimal implementation**

In `FineTune/Views/Settings/Tabs/GeneralTab.swift`:
1. Add property: `let bottomEdgeScrollMonitor: BottomEdgeScrollMonitor`
2. Update the preview provider to supply a dummy monitor if needed.
3. In `generalSection`, add the new settings rows:
```swift
            SettingsRowDivider()
            SettingsRow(
                "Scroll at Bottom Edge",
                description: "Scroll the mouse wheel at the bottom of the screen to change volume"
            ) {
                Toggle("", isOn: $settings.appSettings.bottomEdgeScrollEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }
            if settings.appSettings.bottomEdgeScrollEnabled {
                SettingsRowDivider()
                SettingsRow(
                    "Scroll Step Size",
                    description: "How much the volume changes per scroll tick"
                ) {
                    HStack(spacing: 8) {
                        Slider(
                            value: Binding(
                                get: { Double(settings.appSettings.bottomEdgeScrollStep) },
                                set: { settings.appSettings.bottomEdgeScrollStep = Float($0) }
                            ),
                            in: 0.01...0.10,
                            step: 0.01
                        )
                        .frame(width: 100)
                        
                        Text(String(format: "%.0f%%", settings.appSettings.bottomEdgeScrollStep * 100))
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(DesignTokens.Colors.textSecondary)
                            .frame(width: 32, alignment: .trailing)
                    }
                }
            }
```

**Step 4: Run test to verify it passes**

Run: `swift build`
Expected: Build finishes with no errors.

**Step 5: Commit**

```bash
git add FineTune/Views/Settings/Tabs/GeneralTab.swift
git commit -m "feat: add bottom-edge scroll settings controls to General settings tab"
```

---

## Verification Plan

### Automated Tests
- `swift test --filter SettingsManagerTests`
- `swift test --filter BottomEdgeScrollMonitorTests`

### Manual Verification
1. Launch the app locally.
2. Open Settings, go to the General tab.
3. Verify that the "Scroll at Bottom Edge" toggle is present and turned off by default.
4. Toggle it on. Confirm that the "Scroll Step Size" slider appears underneath.
5. Drag the slider to 5%.
6. Move the mouse to the absolute bottom edge of the screen and scroll the wheel or trackpad.
7. Verify that:
   - Volume changes in steps of 5%.
   - The Tahoe or Classic HUD appears correctly.
   - The volume feedback tick plays.
   - The menu bar icon updates and flashes.
8. Disable the toggle, scroll at the bottom of the screen, and verify that the volume no longer changes.
