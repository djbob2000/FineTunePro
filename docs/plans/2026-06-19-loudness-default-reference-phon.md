# Design: Loudness Default Reference Phon Adjustment and UI Text Refactoring

We are updating the default reference level for Loudness Compensation from 85 Phon to 83 Phon. This aligns better with nearfield studio/music monitoring and headphone standards (e.g., K-System and ATSC A/85). Additionally, we are simplifying the UI hint text to be more user-friendly.

## Proposed Changes

### 1. Default Phon Value Update
We will change the default value of the Loudness Reference Phon from `85.0` to `83.0` in the following files:
- `FineTune/Audio/Loudness/ISO226Contours.swift`
- `FineTune/Settings/SettingsManager.swift`
- `FineTune/Audio/Engine/ProcessTapController.swift`
- `FineTune/Audio/Loudness/LoudnessCompensator.swift`
- `FineTune/Audio/Engine/AudioEngine.swift`
- `FineTune/Audio/Engine/TapInitialState.swift`

### 2. UI Text Update
In `FineTune/Views/Sheets/DeviceDetailSheet.swift`, the description text for the Reference Level will be updated from:
```swift
Text("Calibrate compensation for the sensitivity of your headphones or speakers")
```
to:
```swift
Text("Default is 83. Compensation for the sensitivity of your headphones.")
```

### 3. Test Assertions Update
We will update test assertions in unit tests to expect the new default of `83.0`:
- `FineTuneTests/AudioEngineTapInitialStateTests.swift`
- `FineTuneTests/DeviceDetailSheetToggleTests.swift`
- Other unit tests checking default values

## Verification Plan

- Run unit tests to ensure that the new default value of 83.0 is correctly handled in state snapshots, presets, and audio engines.
- Ensure the app builds successfully.
