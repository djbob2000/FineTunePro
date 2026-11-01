# Menu Bar Bluetooth Headphones Icon Auto-Update Implementation Plan

> **For Antigravity:** REQUIRED WORKFLOW: Use `.agent/workflows/execute-plan.md` to execute this plan in single-flow mode.

**Goal:** Automatically update the menu bar icon to show the headphone/device symbol when any Bluetooth audio device is connected and active as the default output device, matching the native macOS volume settings behavior.

**Architecture:** Define a static method `MenuBarIconState.resolveStyle(defaultDeviceID:configuredStyle:isBluetooth:)` that overrides the configured menu bar icon style to `.device` if the default output device is a Bluetooth device. Use this method in `MenuBarIconCoordinator` and `FineTuneApp` during startup and dynamic icon updates.

**Tech Stack:** Swift, AppKit, CoreAudio, Testing

---

### Task 1: Add Unit Tests for MenuBarIconState.resolveStyle

**Files:**
- Modify: [MenuBarIconStateTests.swift](file:///Users/air/develop/FineTuneFork/FineTuneTests/MenuBarIconStateTests.swift)

**Step 1: Write the failing tests**
Add a new `@Suite` in `FineTuneTests/MenuBarIconStateTests.swift` with tests checking that:
1. `resolveStyle` returns `.device` when `isBluetooth` helper returns `true`, regardless of what style is configured.
2. `resolveStyle` returns the configured style when `isBluetooth` helper returns `false`.

```swift
@Suite("MenuBarIconState.resolveStyle — Bluetooth override")
struct MenuBarIconStyleResolveTests {

    @Test("Bluetooth device active → overrides any configured style to .device")
    func bluetoothDeviceOverridesToDevice() {
        for style in MenuBarIconStyle.allCases {
            let resolved = MenuBarIconState.resolveStyle(
                defaultDeviceID: 42,
                configuredStyle: style,
                isBluetooth: { _ in true }
            )
            #expect(resolved == .device, "style \(style) should be overridden to .device")
        }
    }

    @Test("Non-Bluetooth device active → respects configured style")
    func nonBluetoothDeviceRespectsStyle() {
        for style in MenuBarIconStyle.allCases {
            let resolved = MenuBarIconState.resolveStyle(
                defaultDeviceID: 42,
                configuredStyle: style,
                isBluetooth: { _ in false }
            )
            #expect(resolved == style, "style \(style) should be respected")
        }
    }
}
```

**Step 2: Run test to verify it fails**
Run the tests to ensure they fail compilation due to `resolveStyle` not existing yet.
Run: `xcodebuild test -project FineTune.xcodeproj -scheme FineTune -destination 'platform=macOS' -only-testing:FineTuneTests/MenuBarIconStyleResolveTests CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO`
Expected: FAIL (compilation error)

---

### Task 2: Implement MenuBarIconState.resolveStyle

**Files:**
- Modify: [MenuBarIconState.swift](file:///Users/air/develop/FineTuneFork/FineTune/Views/MenuBar/MenuBarIconState.swift)

**Step 1: Add resolveStyle to MenuBarIconState**
Add the `resolveStyle` helper to `MenuBarIconState` to perform the style override checking.

```swift
extension MenuBarIconState {
    static func resolveStyle(
        defaultDeviceID: AudioDeviceID,
        configuredStyle: MenuBarIconStyle,
        isBluetooth: (AudioDeviceID) -> Bool = { $0.isBluetoothDevice() }
    ) -> MenuBarIconStyle {
        if isBluetooth(defaultDeviceID) {
            return .device
        }
        return configuredStyle
    }
}
```

**Step 2: Run tests to verify they pass**
Run the newly created tests to verify the override logic behaves correctly.
Run: `xcodebuild test -project FineTune.xcodeproj -scheme FineTune -destination 'platform=macOS' -only-testing:FineTuneTests/MenuBarIconStyleResolveTests CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO`
Expected: PASS

**Step 3: Commit**
```bash
git add FineTune/Views/MenuBar/MenuBarIconState.swift FineTuneTests/MenuBarIconStateTests.swift
git commit -m "feat: add MenuBarIconState.resolveStyle with tests"
```

---

### Task 3: Integrate resolveStyle in MenuBarIconCoordinator and FineTuneApp

**Files:**
- Modify: [MenuBarIconCoordinator.swift](file:///Users/air/develop/FineTuneFork/FineTune/Views/MenuBar/MenuBarIconCoordinator.swift)
- Modify: [FineTuneApp.swift](file:///Users/air/develop/FineTuneFork/FineTune/FineTuneApp.swift)

**Step 1: Update computeState() in MenuBarIconCoordinator**
In [MenuBarIconCoordinator.swift](file:///Users/air/develop/FineTuneFork/FineTune/Views/MenuBar/MenuBarIconCoordinator.swift), update `computeState()` to use `MenuBarIconState.resolveStyle`.

Replace:
```swift
        return MenuBarIconState.baseline(
            style: settings.appSettings.menuBarIconStyle,
            volume: volume,
            muted: muted,
            deviceSymbol: currentDeviceSymbol()
        )
```

With:
```swift
        let style = MenuBarIconState.resolveStyle(
            defaultDeviceID: id,
            configuredStyle: settings.appSettings.menuBarIconStyle
        )
        return MenuBarIconState.baseline(
            style: style,
            volume: volume,
            muted: muted,
            deviceSymbol: currentDeviceSymbol()
        )
```

**Step 2: Update launchState in FineTuneApp**
In [FineTuneApp.swift](file:///Users/air/develop/FineTuneFork/FineTune/FineTuneApp.swift), update the launch state style computation.

Replace:
```swift
        let launchState = MenuBarIconState.baseline(
            style: settings.appSettings.menuBarIconStyle,
            volume: launchVolumeMonitor.volumes[launchID] ?? 1.0,
            muted: launchVolumeMonitor.muteStates[launchID] ?? false,
            deviceSymbol: MenuBarDeviceIconResolver.resolveSymbol(
                priorityOrder: settings.devicePriorityOrder,
                outputDevices: engine.deviceMonitor.outputDevices,
                defaultDeviceID: launchID
            )
        )
```

With:
```swift
        let launchStyle = MenuBarIconState.resolveStyle(
            defaultDeviceID: launchID,
            configuredStyle: settings.appSettings.menuBarIconStyle
        )
        let launchState = MenuBarIconState.baseline(
            style: launchStyle,
            volume: launchVolumeMonitor.volumes[launchID] ?? 1.0,
            muted: launchVolumeMonitor.muteStates[launchID] ?? false,
            deviceSymbol: MenuBarDeviceIconResolver.resolveSymbol(
                priorityOrder: settings.devicePriorityOrder,
                outputDevices: engine.deviceMonitor.outputDevices,
                defaultDeviceID: launchID
            )
        )
```

**Step 3: Run the full test suite**
Run all tests to verify no regressions were introduced.
Run: `xcodebuild test -project FineTune.xcodeproj -scheme FineTune -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO`
Expected: PASS

**Step 4: Commit**
```bash
git add FineTune/Views/MenuBar/MenuBarIconCoordinator.swift FineTune/FineTuneApp.swift
git commit -m "feat: integrate resolveStyle in MenuBarIconCoordinator and FineTuneApp"
```

---

## Verification Plan

### Automated Tests
- `xcodebuild test -project FineTune.xcodeproj -scheme FineTune -destination 'platform=macOS' -only-testing:FineTuneTests/MenuBarIconStyleResolveTests CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO`
- `xcodebuild test -project FineTune.xcodeproj -scheme FineTune -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO`

### Manual Verification
1. Run the app and open settings.
2. Select any style (e.g. `Speaker` or `Default`).
3. Connect a Bluetooth audio device (e.g., AirPods or other Bluetooth headphones).
4. Verify that the menu bar icon automatically changes to the headphones/device symbol.
5. Disconnect the Bluetooth audio device.
6. Verify that the menu bar icon automatically reverts back to the selected setting icon style.
