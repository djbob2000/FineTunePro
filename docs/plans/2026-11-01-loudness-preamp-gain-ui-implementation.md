# Loudness Compensation Preamp Gain UI Implementation Plan

> **For Antigravity:** REQUIRED WORKFLOW: Use `.agent/workflows/execute-plan.md` to execute this plan in single-flow mode.

**Goal:** Provide an Auto/Manual Preamp Gain control in `DeviceEnhancementPanel` allowing users to manually dial in input attenuation from 0.0 dB down to -12.0 dB or use automatic headroom calculation.

**Architecture:** Add `LoudnessPreampMode` (.auto / .manual) and `manualPreampDB` (-12.0 ... 0.0) to `SettingsManager`. Propagate these values through `AudioEngine` and `ProcessTapController` into `LoudnessCompensator.updatePreamp()`. Build the UI control in `DeviceEnhancementPanel.swift`.

**Tech Stack:** Swift, SwiftUI, Accelerate (vDSP), CoreAudio, XCTest.

---

### Task 1: Add Settings Persistence in `SettingsManager.swift`
**Files:**
- Modify: `FineTune/Settings/SettingsManager.swift`
- Test: `FineTuneTests/ProcessingPipelineTests.swift`

**Step 1: Write the failing unit test**
Add test in `FineTuneTests/ProcessingPipelineTests.swift` testing round-trip persistence of `deviceLoudnessPreampMode` and `deviceLoudnessPreampManualDB`.

**Step 2: Run test to verify failure**
Run: `xcodebuild test -project FineTune.xcodeproj -scheme FineTune -only-testing:FineTuneTests/ProcessingPipelineTests`
Expected: FAIL (types / methods not found).

**Step 3: Implement settings persistence**
Add `LoudnessPreampMode` enum (`auto`, `manual`), fields `deviceLoudnessPreampMode` and `deviceLoudnessPreampManualDB` with getters, setters, and defaults.

**Step 4: Run test to verify pass**
Run: `xcodebuild test -project FineTune.xcodeproj -scheme FineTune -only-testing:FineTuneTests/ProcessingPipelineTests`
Expected: PASS.

**Step 5: Commit**
`git commit -m "feat(settings): add LoudnessPreampMode and manual preamp gain persistence"`

---

### Task 2: Implement Manual Preamp in `LoudnessCompensator.swift`
**Files:**
- Modify: `FineTune/Audio/Loudness/LoudnessCompensator.swift`
- Test: `FineTuneTests/LoudnessHeadroomRegressionTests.swift`

**Step 1: Write unit test in `LoudnessHeadroomRegressionTests.swift`**
Test that setting `.manual` with `-3.0 dB` results in `_preampGain == pow(10, -3/20)` regardless of volume slider level.

**Step 2: Run test to verify failure**
Run: `xcodebuild test -project FineTune.xcodeproj -scheme FineTune -only-testing:FineTuneTests/LoudnessHeadroomRegressionTests`
Expected: FAIL.

**Step 3: Update `LoudnessCompensator`**
Accept `preampMode: LoudnessPreampMode` and `manualPreampDB: Double` in `updateForVolume(...)`. In `updatePreamp()`, branch on `_preampMode == .manual`.

**Step 4: Run test to verify pass**
Run: `xcodebuild test -project FineTune.xcodeproj -scheme FineTune -only-testing:FineTuneTests/LoudnessHeadroomRegressionTests`
Expected: PASS.

**Step 5: Commit**
`git commit -m "feat(dsp): support manual preamp gain in LoudnessCompensator"`

---

### Task 3: Propagate Settings through AudioEngine and Tap Controllers
**Files:**
- Modify: `FineTune/Audio/Engine/ProcessTapControlling.swift`
- Modify: `FineTune/Audio/Engine/ProcessTapController.swift`
- Modify: `FineTune/Audio/Engine/AudioEngine.swift`

**Step 1: Update protocols and tap controllers**
Pass `preampMode: LoudnessPreampMode` and `manualPreampDB: Double` through `updateLoudnessCompensation(...)`.

**Step 2: Wire AudioEngine listener and initial state**
Forward device settings from `SettingsManager` to `AudioEngine.updateTapsLoudness(...)`.

**Step 3: Run test suite**
Run: `xcodebuild test -project FineTune.xcodeproj -scheme FineTune -only-testing:FineTuneTests`
Expected: PASS.

**Step 4: Commit**
`git commit -m "feat(audio): propagate loudness preamp mode and manual dB through AudioEngine"`

---

### Task 4: Implement UI Controls in `DeviceEnhancementPanel.swift`
**Files:**
- Modify: `FineTune/Views/Components/DeviceEnhancementPanel.swift`
- Modify: `FineTune/Views/Components/DeviceEnhancementPicker.swift`

**Step 1: Add Preamp Gain Section**
Under `loudnessSection`, add an expandable row for Preamp Gain with:
- Auto / Manual segmented picker.
- When Manual: slider from `-12.0` to `0.0 dB` (step 0.5 dB) with formatted readout text.
- Explanatory caption text.

**Step 2: Verify UI compilation & build**
Run: `xcodebuild build -project FineTune.xcodeproj -scheme FineTune -configuration Debug`
Expected: SUCCEEDED.

**Step 3: Commit**
`git commit -m "feat(ui): add Loudness Preamp Gain Auto/Manual control in DeviceEnhancementPanel"`

---

### Task 5: Full Verification & Release App Build
**Step 1: Run full test suite**
Run: `xcodebuild test -project FineTune.xcodeproj -scheme FineTune -only-testing:FineTuneTests`
Expected: ALL PASS.

**Step 2: Build release archive and codesign**
Build `build/FineTune.app` and codesign.

**Step 3: Commit & Push to GitHub**
Push branch `feat/pure-harmonic-bass-exciter`.

