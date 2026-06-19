# Loudness Default Reference Phon Adjustment Implementation Plan

> **For Antigravity:** REQUIRED WORKFLOW: Use `.agent/workflows/execute-plan.md` to execute this plan in single-flow mode.

**Goal:** Change the default reference level for Loudness Compensation from 85 Phon to 83 Phon across the codebase, update the UI hint text to "Default is 83. Compensation for the sensitivity of your headphones.", and update associated unit tests to pass.

**Architecture:** Update static defaults, initial state structs, and fallback values to `83.0` instead of `85.0`, and update text labels in the detail view.

**Tech Stack:** Swift, SwiftUI, Xcode Test

---

### Task 1: Update Core Audio/Loudness Defaults

**Files:**
- Modify: `FineTune/Audio/Loudness/ISO226Contours.swift:50-55`
- Modify: `FineTune/Audio/Loudness/LoudnessCompensator.swift:45-55`
- Modify: `FineTune/Audio/Loudness/LoudnessCompensator.swift:80-85`
- Modify: `FineTune/Audio/Loudness/LoudnessCompensator.swift:145-150`

**Step 1: Modify defaultReferencePhon in ISO226Contours.swift**
Change `defaultReferencePhon` to `83.0` in `FineTune/Audio/Loudness/ISO226Contours.swift`.

**Step 2: Modify initial properties and functions in LoudnessCompensator.swift**
Change `_currentPhon`, `_currentReferencePhon`, and default parameters in `updateForVolume` and `fittedSectionGains` from `85.0` to `83.0`.

**Step 3: Verify build**
Run: `xcodebuild build -project FineTune.xcodeproj -scheme FineTune -destination 'platform=macOS' CODE_SIGN_IDENTITY="-"`
Expected: Build succeeds.

**Step 4: Commit**
```bash
git add FineTune/Audio/Loudness/ISO226Contours.swift FineTune/Audio/Loudness/LoudnessCompensator.swift
git commit -m "chore: update core loudness default reference level to 83.0 phon"
```

---

### Task 2: Update App Engine & Settings Defaults

**Files:**
- Modify: `FineTune/Settings/SettingsManager.swift:150-155`
- Modify: `FineTune/Settings/SettingsManager.swift:830-835`
- Modify: `FineTune/Audio/Engine/ProcessTapController.swift:130-135`
- Modify: `FineTune/Audio/Engine/AudioEngine.swift:645-650`
- Modify: `FineTune/Audio/Engine/TapInitialState.swift:10-15`

**Step 1: Modify SettingsManager.swift**
Update default reference phon in comments, dictionary initializers, and fallback values from `85.0` to `83.0`.

**Step 2: Modify ProcessTapController.swift and TapInitialState.swift**
Update initial properties `_lastLoudnessReferencePhon` and `loudnessReferencePhon` to `83.0`.

**Step 3: Modify AudioEngine.swift**
Update default reference level fallback in `AudioEngine.swift` to `83.0`.

**Step 4: Verify build**
Run: `xcodebuild build -project FineTune.xcodeproj -scheme FineTune -destination 'platform=macOS' CODE_SIGN_IDENTITY="-"`
Expected: Build succeeds.

**Step 5: Commit**
```bash
git add FineTune/Settings/SettingsManager.swift FineTune/Audio/Engine/ProcessTapController.swift FineTune/Audio/Engine/AudioEngine.swift FineTune/Audio/Engine/TapInitialState.swift
git commit -m "chore: update settings, tap controllers, and engine defaults to 83.0 phon"
```

---

### Task 3: Update UI Text

**Files:**
- Modify: `FineTune/Views/Sheets/DeviceDetailSheet.swift:295-302`

**Step 1: Update hint text in DeviceDetailSheet.swift**
Replace `Text("Calibrate compensation for the sensitivity of your headphones or speakers")` with `Text("Default is 83. Compensation for the sensitivity of your headphones.")`.

**Step 2: Verify build**
Run: `xcodebuild build -project FineTune.xcodeproj -scheme FineTune -destination 'platform=macOS' CODE_SIGN_IDENTITY="-"`
Expected: Build succeeds.

**Step 3: Commit**
```bash
git add FineTune/Views/Sheets/DeviceDetailSheet.swift
git commit -m "ui: simplify loudness reference calibration label to mention 83 default"
```

---

### Task 4: Update and Verify Unit Tests

**Files:**
- Modify: `FineTuneTests/AudioEngineTapInitialStateTests.swift:510-515`
- Modify: `FineTuneTests/DeviceDetailSheetToggleTests.swift:45-50`

**Step 1: Update expected loudnessReferencePhon in AudioEngineTapInitialStateTests.swift**
Change `snap.loudnessReferencePhon == 85.0` to `83.0`.

**Step 2: Update default in DeviceDetailSheetToggleTests.swift**
Change mock `loudnessReferencePhon: 85.0` to `83.0`.

**Step 3: Run unit tests**
Run: `xcodebuild test -project FineTune.xcodeproj -scheme FineTune -destination 'platform=macOS' -only-testing:FineTuneTests CODE_SIGN_IDENTITY="-"`
Expected: All unit tests pass.

**Step 4: Commit**
```bash
git add FineTuneTests/AudioEngineTapInitialStateTests.swift FineTuneTests/DeviceDetailSheetToggleTests.swift
git commit -m "test: update expectations and mocks to use 83.0 phon default"
```
