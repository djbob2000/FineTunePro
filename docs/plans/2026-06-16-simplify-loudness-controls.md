# Simplify Loudness Controls Implementation Plan

> **For Antigravity:** REQUIRED WORKFLOW: Use `.agent/workflows/execute-plan.md` to execute this plan in single-flow mode.

**Goal:** Simplify loudness compensation controls from three sliders to two by removing "Reference Level Offset" from the UI and changing "Boost" to apply as a direct decibel gain multiplier.

**Architecture:** 
1. Decouple `loudnessCompensationIntensity` from phon level calculations in `LoudnessCompensator.swift`. Apply it as a direct scalar multiplier to the computed EQ band gains before headroom normalization.
2. Fix default `loudnessCompensationCurveExponent` to `1.0` (mathematical match for macOS Core Audio volume perception).
3. Remove `loudnessCompensationReferenceOffset` slider from the `AudioTab` view and force-default its value to `0.0 dB`.
4. Ensure all changes are properly propagated via `AudioEngine` and tests.

**Tech Stack:** Swift, SwiftUI, AVFoundation, Accelerate (vDSP)

---

### Task 1: Update LoudnessCompensator to apply intensity directly to gains

**Files:**
- Modify: `FineTune/Audio/Loudness/LoudnessCompensator.swift`

**Step 1: Write the minimal implementation**
We need to:
1. Update `updateForVolume` to calculate `phon` and `adjustedPhon` without scaling them by `intensity` (clamping at 20 phon).
2. Pass `intensity` directly to `computeBandGains`.
3. Multiply the gains by `intensity` inside `computeBandGains` *before* the headroom calculation.

Let's update the file `LoudnessCompensator.swift`:
```swift
    func updateForVolume(_ systemVolume: Float, intensity: Float = 1.0, exponent: Float = 1.5, referenceOffset: Float = 0.0) {
        // Volume-based phon estimation
        let phon = ISO226Contours.estimatedPhon(fromSystemVolume: systemVolume, exponent: exponent, referenceOffset: referenceOffset)

        let paramsChanged = intensity != _currentIntensity || exponent != _currentExponent || referenceOffset != _currentReferenceOffset

        // Coalesce rapid updates
        guard !isEnabled || paramsChanged || abs(phon - _currentPhon) >= 1.0 else { return }
        _currentPhon = phon
        _currentIntensity = intensity
        _currentExponent = exponent
        _currentReferenceOffset = referenceOffset

        let gains = computeBandGains(phon: phon, intensity: intensity)

        // Bypass when all gains are negligible (near reference level)
        let allNegligible = gains.allSatisfy { abs($0) < 0.1 }
        if allNegligible {
            setEnabled(false)
            swapSetup(nil)
            return
        }

        let coefficients = Self.coefficientsForBands(gains: gains, sampleRate: sampleRate)
        let newSetup = coefficients.withUnsafeBufferPointer { ptr in
            vDSP_biquad_CreateSetup(ptr.baseAddress!, vDSP_Length(Self.bandCount))
        }
        swapSetup(newSetup)
        setEnabled(true)
    }

    private func computeBandGains(phon: Double, intensity: Float) -> [Float] {
        let gains = Self.fittedSectionGains(forPhon: phon, sampleRate: sampleRate)
        let scaledGains = gains.map { $0 * intensity }
        let realized = Self.realizedResponseDB(sectionGains: scaledGains.map(Double.init), sampleRate: sampleRate)
        let peakDB = max(realized.max() ?? 0.0, 0.0)
        return scaledGains.map { $0 - Float(peakDB) }
    }

    override func recomputeCoefficients() -> (coefficients: [Double], sectionCount: Int)? {
        let gains = computeBandGains(phon: _currentPhon, intensity: _currentIntensity)
        let allNegligible = gains.allSatisfy { abs($0) < 0.1 }
        guard !allNegligible else { return nil }
        let coefficients = Self.coefficientsForBands(gains: gains, sampleRate: sampleRate)
        return (coefficients, Self.bandCount)
    }
```

---

### Task 2: Update AppSettings default values and UI controls

**Files:**
- Modify: `FineTune/Settings/SettingsManager.swift`
- Modify: `FineTune/Views/Settings/Tabs/AudioTab.swift`

**Step 1: Set default exponent and referenceOffset in SettingsManager**
We will change:
- Exponent default to `1.0` (optimal matching curve for macOS).
- Reference Offset default to `0.0`.
- Retain the properties in `AppSettings` to prevent JSON decoding failures for existing profiles.

In `FineTune/Settings/SettingsManager.swift`:
```swift
    var loudnessCompensationCurveExponent: Float = 1.0  // Default to 1.0 (matching macOS Core Audio volume)
    var loudnessCompensationReferenceOffset: Float = 0.0  // Default to 0.0
```

**Step 2: Update UI in AudioTab**
We will:
1. Remove the **Reference Offset** slider from the view layout entirely.
2. Restrict the **Steepness** slider range to `1.0...1.5`.

In `FineTune/Views/Settings/Tabs/AudioTab.swift`:
Replace:
```swift
                SettingsRow(
                    "Steepness",
                    description: "Rate of compensation as volume decreases"
                ) {
                    ParameterSlider(
                        value: $settings.appSettings.loudnessCompensationCurveExponent,
                        range: 0.0...10.0,
                        format: "%.1fx",
                        width: 280
                    )
                }
                SettingsRowDivider()
                SettingsRow(
                    "Reference Offset",
                    description: "Compensate for quiet headphones or quiet audio sources"
                ) {
                    ParameterSlider(
                        value: $settings.appSettings.loudnessCompensationReferenceOffset,
                        range: 0.0...40.0,
                        format: "%.0f dB",
                        width: 280
                    )
                }
```
With only:
```swift
                SettingsRow(
                    "Steepness",
                    description: "Rate of compensation as volume decreases"
                ) {
                    ParameterSlider(
                        value: $settings.appSettings.loudnessCompensationCurveExponent,
                        range: 1.0...1.5,
                        format: "%.1fx",
                        width: 280
                    )
                }
```

---

### Task 3: Update and Run Unit Tests

**Files:**
- Modify: `FineTuneTests/ISO226ContoursTests.swift`
- Modify: `FineTuneTests/AudioEngineTapInitialStateTests.swift`

**Step 1: Update Test cases**
Ensure that unit tests verify:
1. `LoudnessCompensator` compiles correctly and passes standard tests with the updated `updateForVolume` signature.
2. We add a test case in `ISO226ContoursTests.swift` that verifies `intensity` acts as a direct gain multiplier and succeeds in scaling decibels beyond the normal $20\text{ phon}$ gains.

**Step 2: Run all tests**
Execute:
`xcodebuild test -scheme FineTune -only-testing:FineTuneTests -destination 'platform=macOS' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO`
Expected: **TEST SUCCEEDED**

---

### Task 4: Build Release & Package

**Step 1: Build & Package**
Run:
`./scripts/build-dmg.sh` or compile release configuration.
*Note: Make sure code-signing works for local deployment or bundle packaging.*
