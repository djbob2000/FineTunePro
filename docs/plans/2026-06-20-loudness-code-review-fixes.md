# Loudness Code Review Fixes Implementation Plan

> **For Antigravity:** REQUIRED WORKFLOW: Use `.agent/workflows/execute-plan.md` to execute this plan in single-flow mode.

**Goal:** Resolve code review findings by ensuring loudness settings persist on device switches, using static default phon levels in the detail sheet, and updating transition documents and test comments to 150 ms.

**Architecture:**
- Introduce a helper method `applyLoudnessCompensationToTap(_:)` in `AudioEngine` and hook it into every device switch and routing update.
- Replace literal `83.0` values in `DeviceDetailSheet` with references to `ISO226Contours.defaultReferencePhon`.
- Update transition design documents and unit test comments to reflect the 150 ms transition duration with CoreAudio driver buffering explanation.

**Tech Stack:** Swift, Swift Testing, Markdown.

---

### Task 1: Re-Apply Loudness Compensation on Device Switch

**Files:**
- Modify: [AudioEngine.swift](file:///Users/air/develop/FineTuneFork/FineTune/Audio/Engine/AudioEngine.swift:1003-1660)
- Test: [AudioEngineTapInitialStateTests.swift](file:///Users/air/develop/FineTuneFork/FineTuneTests/AudioEngineTapInitialStateTests.swift)

**Step 1: Write the failing test**

Add a test case in [AudioEngineTapInitialStateTests.swift](file:///Users/air/develop/FineTuneFork/FineTuneTests/AudioEngineTapInitialStateTests.swift) verifying that loudness compensation settings are re-applied to the tap after device switches.

```swift
    @Test("Loudness Compensation settings are re-applied to tap after device switches")
    func loudnessCompensationReappliedOnSwitch() async throws {
        let fix = makeFixture()
        let secondDevice = AudioDevice(
            id: AudioDeviceID(100),
            uid: "uid-second-device",
            name: "Second Output",
            icon: nil,
            supportsAutoEQ: true
        )
        fix.deviceMonitor.addOutputDevice(secondDevice)
        
        // 1. Initial routing (device is "uid-test", default loudness compensation is false)
        fix.engine.setDevice(for: fix.app, deviceUID: fix.device.uid)
        let tap = try #require(fix.lastTap())
        tap.clearEvents()
        
        // 2. Enable loudness compensation for the second device
        fix.settings.setLoudnessCompensationEnabled(for: secondDevice.uid, to: true)
        
        // 3. Switch device to the second device
        fix.engine.setDevice(for: fix.app, deviceUID: secondDevice.uid)
        
        // Allow tasks to run
        try await Task.sleep(nanoseconds: 50_000_000)
        
        // 4. Verify that updateLoudnessCompensation(enabled: true) was called on the tap
        let loudnessEvents = tap.events.compactMap { event -> (volume: Float, enabled: Bool, referencePhon: Double, gainScale: Float)? in
            if case let .updateLoudnessCompensation(volume, enabled, referencePhon, gainScale) = event {
                return (volume, enabled, referencePhon, gainScale)
            }
            return nil
        }
        #expect(loudnessEvents.contains(where: { $0.enabled == true }))
    }
```

**Step 2: Run test to verify it fails**

Run:
```bash
xcodebuild -scheme FineTune -destination 'platform=macOS' test -only-testing FineTuneTests/AudioEngineTapInitialStateTests/loudnessCompensationReappliedOnSwitch CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO
```
Expected: FAIL (the tap's events do not register the loudness compensation update event).

**Step 3: Implement minimal code changes**

Modify [AudioEngine.swift](file:///Users/air/develop/FineTuneFork/FineTune/Audio/Engine/AudioEngine.swift):

1. Define `applyLoudnessCompensationToTap` right next to `applyAutoEQToTap`:
```swift
    private func applyLoudnessCompensationToTap(_ tap: any ProcessTapControlling) {
        guard let deviceUID = tap.currentDeviceUID else { return }
        let enabled = settingsManager.getLoudnessCompensationEnabled(for: deviceUID)
        let referencePhon = settingsManager.getLoudnessReferencePhon(for: deviceUID)
        tap.updateLoudnessCompensation(
            volume: effectiveLoudnessVolume(for: tap),
            enabled: enabled,
            referencePhon: referencePhon,
            gainScale: enabled ? 1.0 : 0.0
        )
    }
```

2. Call `self.applyLoudnessCompensationToTap(...)` in the switch/update paths of:
- `setDevice(for:app:deviceUID:)` (around line 1113)
- `updateTapForCurrentMode(for:)` (around line 1207, also add `self.applyAutoEQToTap(tap)`)
- `applyPersistedSettings()` (around line 1350)
- `routeFollowsDefaultApps(to:)` (around line 1495)
- `handleDeviceDisconnected(_:name:)` (around line 1577 and line 1591)
- `handleDeviceConnected(_:name:)` (around line 1653)

**Step 4: Run test to verify it passes**

Run:
```bash
xcodebuild -scheme FineTune -destination 'platform=macOS' test -only-testing FineTuneTests/AudioEngineTapInitialStateTests/loudnessCompensationReappliedOnSwitch CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO
```
Expected: SUCCESS (TEST SUCCEEDED)

**Step 5: Commit**

```bash
git add FineTune/Audio/Engine/AudioEngine.swift FineTuneTests/AudioEngineTapInitialStateTests.swift
git commit -m "fix: re-apply loudness compensation settings on device switch/update"
```

---

### Task 2: Use Static Default Phon Constant in DeviceDetailSheet

**Files:**
- Modify: [DeviceDetailSheet.swift](file:///Users/air/develop/FineTuneFork/FineTune/Views/Sheets/DeviceDetailSheet.swift:260-295)

**Step 1: Write the changes**

Update the following in [DeviceDetailSheet.swift](file:///Users/air/develop/FineTuneFork/FineTune/Views/Sheets/DeviceDetailSheet.swift):
- Line 267: Change `onLoudnessReferencePhonChange(83.0)` to `onLoudnessReferencePhonChange(ISO226Contours.defaultReferencePhon)`.
- Line 275: Change `disabled(loudnessReferencePhon == 83.0)` to `disabled(loudnessReferencePhon == ISO226Contours.defaultReferencePhon)`.
- Line 292: Change `phon == 83.0 ? "Default" : "Custom"` to `phon == ISO226Contours.defaultReferencePhon ? "Default" : "Custom"`.

**Step 2: Verify compilation and tests**

Run:
```bash
xcodebuild -scheme FineTune -destination 'platform=macOS' test -only-testing FineTuneTests/DeviceDetailSheetToggleTests CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO
```
Expected: SUCCESS

**Step 3: Commit**

```bash
git add FineTune/Views/Sheets/DeviceDetailSheet.swift
git commit -m "refactor: use ISO226Contours.defaultReferencePhon instead of hardcoded 83.0"
```

---

### Task 3: Update Transition Documentation and Test Comments to 150 ms

**Files:**
- Modify: [2026-06-19-loudness-timbral-transition.md](file:///Users/air/develop/FineTuneFork/docs/plans/2026-06-19-loudness-timbral-transition.md)
- Modify: [2026-06-19-loudness-timbral-transition-design.md](file:///Users/air/develop/FineTuneFork/docs/plans/2026-06-19-loudness-timbral-transition-design.md)
- Modify: [LoudnessVolumeCompensationTests.swift](file:///Users/air/develop/FineTuneFork/FineTuneTests/LoudnessVolumeCompensationTests.swift)

**Step 1: Write the changes**

1. In [2026-06-19-loudness-timbral-transition.md](file:///Users/air/develop/FineTuneFork/docs/plans/2026-06-19-loudness-timbral-transition.md):
   - Update any occurrences of "300 ms" to "150 ms".
   - Note the rationale: 150 ms transition duration avoids backlog in the CoreAudio driver/hardware volume queue during rapid volume adjustments.
2. In [2026-06-19-loudness-timbral-transition-design.md](file:///Users/air/develop/FineTuneFork/docs/plans/2026-06-19-loudness-timbral-transition-design.md):
   - Update occurrences of "300 ms" or similar transition periods to "150 ms".
   - Document the queue backlog / performance rationale.
3. In [LoudnessVolumeCompensationTests.swift](file:///Users/air/develop/FineTuneFork/FineTuneTests/LoudnessVolumeCompensationTests.swift):
   - Update comments (e.g. `// Wait for the 300ms volume ramp task to complete`) to say `150ms`.

**Step 2: Verify all unit tests pass**

Run:
```bash
xcodebuild -scheme FineTune -destination 'platform=macOS' test -only-testing FineTuneTests CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO
```
Expected: SUCCESS

**Step 3: Commit**

```bash
git add docs/plans/2026-06-19-loudness-timbral-transition.md docs/plans/2026-06-19-loudness-timbral-transition-design.md FineTuneTests/LoudnessVolumeCompensationTests.swift
git commit -m "docs: correct transition duration references to 150 ms and document CoreAudio backlog rationale"
```
