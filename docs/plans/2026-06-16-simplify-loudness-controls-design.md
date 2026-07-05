# Design: Simplify Loudness Controls

## Overview
We want to simplify the user interface for loudness compensation by reducing the control parameters from three sliders down to two.
1. **Boost (Intensity)**: Controls the amount of low-frequency and high-frequency compensation. It will now apply as a direct decibel multiplier on the final target gains rather than scaling the virtual phon level.
2. **Steepness (Exponent)**: Controls how rapidly the compensation curves scale down as the system volume increases. It will range from `1.0` (mathematical match for macOS Core Audio volume perception) to `1.5` (slightly more aggressive curve).
3. **Reference Offset**: Removed from the UI and set to a default of `0.0 dB` (standard calibration).

---

## Detailed Specification

### 1. DSP Changes in `LoudnessCompensator.swift`

Currently, `LoudnessCompensator` calculates the virtual listening level $P_{\text{adjusted}}$ using `intensity` as a multiplier on the phon range:
```swift
let adjustedPhon = referencePhon + (phon - referencePhon) * Double(clampedIntensity)
```
Because `clampedPhon` is restricted to $[20.0, 90.0]$, any `adjustedPhon` below $20$ is clamped. When listening at low volume levels (where $\text{phon}$ is already near $20-30$), setting `intensity` to $>1.0$ has no effect because it gets clamped to $20\text{ phon}$ anyway.

#### The Fix:
We will decouple `intensity` from the phon estimation and apply it directly as a multiplier to the calculated target decibel gains:
1. Calculate the estimated phon level using only `exponent` and `referenceOffset` (which defaults to $0.0$):
   $$\text{phon} = \text{estimatedPhon}(V, E, O)$$
   $$\text{adjustedPhon} = \text{phon}$$
2. Compute the standard ISO 226 target gains at `adjustedPhon` (which clamps at $20\text{ phon}$):
   $$\text{gains} = \text{fittedSectionGains}(\text{forPhon}: \text{adjustedPhon})$$
3. Multiply the resulting decibel gains by the intensity:
   $$\text{finalGains} = \text{gains} \times I$$
   *(where $I$ is `intensity` from `0.0` to `2.5`)*

This ensures that the Boost slider physically multiplies the decibel gain, allowing the user to exceed the standard $+27.5\text{ dB}$ limit if they set Intensity $> 1.0$.

---

### 2. UI Changes in `AudioTab.swift`
- Keep **Boost** slider: range `0.0...2.5`, format `%.1fx` or `%.0f%%`.
- Keep **Steepness** slider: range `1.0...1.5`, format `%.1fx`.
- Remove **Reference Offset** slider.

---

### 3. Setting Defaults and Migrations
In `SettingsManager.swift`:
- Default `loudnessCompensationIntensity` = `1.0`
- Default `loudnessCompensationCurveExponent` = `1.0` (mathematical match for macOS Core Audio)
- Default `loudnessCompensationReferenceOffset` = `0.0`

---

## Verification Plan

### Automated Tests
- Update unit tests in [ISO226ContoursTests.swift](file:///Users/air/develop/FineTuneFork/FineTuneTests/ISO226ContoursTests.swift) and [AudioEngineTapInitialStateTests.swift](file:///Users/air/develop/FineTuneFork/FineTuneTests/AudioEngineTapInitialStateTests.swift) to match the new behavior.
- Add a specific test verifying that `intensity` acts as a decibel multiplier and successfully exceeds the standard $20\text{ phon}$ gains.

### Manual Verification
- Compile and run the app.
- Toggle loudness compensation and verify that adjusting **Boost** and **Steepness** changes the sound in real-time, especially at low system volumes.
