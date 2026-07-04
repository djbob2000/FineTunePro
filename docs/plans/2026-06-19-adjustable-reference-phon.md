# Adjustable Reference Phon Implementation Plan

> **For Antigravity:** REQUIRED WORKFLOW: Use `.agent/workflows/execute-plan.md` to execute this plan in single-flow mode.

**Goal:** Make the Reference Level for Loudness Compensation adjustable per-device between 20 and 120 phon, replacing the hardcoded 85.0 phon reference level.

**Architecture:** 
1. Store a per-device `deviceLoudnessReferencePhon` dictionary in `SettingsManager` that maps device UID to a custom phon level (defaulting to 85.0 phon).
2. Modify the `ISO226Contours.estimatedPhon` mapping and `LoudnessCompensator` coefficient fitting logic to dynamically scale and calculate band gains based on the custom reference phon.
3. Pass the custom reference phon from `AudioEngine` to `ProcessTapController` on volume updates, device activations, or settings changes.
4. Add a "Reference Level" slider to the `DeviceDetailSheet` UI underneath the Loudness Compensation toggle when enabled.

**Tech Stack:** Swift, SwiftUI, CoreAudio

---

## Bite-Sized Tasks

### Task 1: Update SettingsManager
**Files:**
- Modify: `FineTune/Settings/SettingsManager.swift`

**Step 1: Add setting and accessor methods**
Add `deviceLoudnessReferencePhon: [String: Double]` dictionary in Settings struct. Update CodingKeys, init(from decoder:), resetAllSettings(), and add get/set helper methods.

**Step 2: Commit**

---

### Task 2: Update ISO226Contours Heuristics
**Files:**
- Modify: `FineTune/Audio/Loudness/ISO226Contours.swift`

**Step 1: Modify estimatedPhon calculation**
Update estimatedPhon to accept referencePhon and map system volume scale dynamically up to the custom reference level instead of defaultReferencePhon.

**Step 2: Commit**

---

### Task 3: Update LoudnessCompensator DSP
**Files:**
- Modify: `FineTune/Audio/Loudness/LoudnessCompensator.swift`

**Step 1: Add state variable and update fit routines**
Add `_currentReferencePhon` property. Update `updateForVolume` to accept `referencePhon` and compute target curve using the custom reference phon. Update `recomputeCoefficients` override.

**Step 2: Commit**

---

### Task 4: Update Tap Controller Routing
**Files:**
- Modify: `FineTune/Audio/Engine/ProcessTapControlling.swift`
- Modify: `FineTune/Audio/Engine/TapInitialState.swift`
- Modify: `FineTune/Audio/Engine/ProcessTapController.swift`
- Modify: `FineTune/Audio/Engine/AudioEngine.swift`

**Step 1: Update protocol and initial state**
Add `loudnessReferencePhon` to TapInitialState and update the updateLoudnessCompensation signature in the ProcessTapControlling protocol.

**Step 2: Update concrete implementation in tap controller**
Implement the new signature in ProcessTapController and use the initial state reference phon on activate.

**Step 3: Update engine routing and callbacks**
Pass the device-specific reference phon in AudioEngine callbacks and set up `setLoudnessReferencePhon(for:to:)` to push dynamic updates.

**Step 4: Commit**

---

### Task 5: Add UI Controls
**Files:**
- Modify: `FineTune/Views/Sheets/DeviceDetailSheet.swift`
- Modify: `FineTune/Views/MenuBarPopupView.swift`

**Step 1: Add Reference Level Slider in DeviceDetailSheet**
Add slider row in DeviceDetailSheet that only shows when Loudness Compensation is active. 

**Step 2: Wire the UI bindings in MenuBarPopupView**
Pass the reference level binding/callback values to DeviceDetailSheet in MenuBarPopupView.

**Step 3: Commit**

---

### Task 6: Add Tests & Verify
**Files:**
- Modify: `FineTuneTests/ISO226ContoursTests.swift`
- Modify: `FineTuneTests/LoudnessEqualizerTests.swift`

**Step 1: Write tests for dynamic reference phon**
Add tests in ISO226ContoursTests for estimatedPhon with custom reference levels, and in LoudnessEqualizerTests to verify tap setting.

**Step 2: Run automated verification**
Verify all tests compile and pass.

**Step 3: Commit**
