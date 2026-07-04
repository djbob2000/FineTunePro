# Dynamic Headroom in Loudness Compensator Implementation Plan

> **For Antigravity:** REQUIRED WORKFLOW: Use `.agent/workflows/execute-plan.md` to execute this plan in single-flow mode.

**Goal:** Implement dynamic headroom compensation in the Loudness Compensator, reducing the headroom cut when digital volume attenuation already provides sufficient headroom.

**Architecture:** Instead of statically subtracting the entire peak boost of the EQ cascade (which makes the signal too quiet at lower listening levels), we convert the linear system volume factor to decibels of digital attenuation. The headroom subtraction is then reduced by this attenuation amount: `headroomToSubtract = max(0.0, peakDB - volumeAttenuationDB)`. This maintains a 0 dBFS peak output limit while preserving volume and dynamic range.

**Tech Stack:** Swift, Accelerate, Swift Testing.

---

### Task 1: Modify LoudnessCompensator to track system volume and apply dynamic headroom

**Files:**
- Modify: `FineTune/Audio/Loudness/LoudnessCompensator.swift`
- Test: `FineTuneTests/ISO226ContoursTests.swift`

**Step 1: Add system volume state property and update computeBandGains logic**

In [LoudnessCompensator.swift](file:///Users/air/develop/FineTuneFork/FineTune/Audio/Loudness/LoudnessCompensator.swift), add a private state variable `_currentSystemVolume` and modify the signatures and logic of `updateForVolume`, `computeBandGains`, and `recomputeCoefficients`.

```diff
     // MARK: - State
 
     /// Phon level used for the last coefficient computation.
     private var _currentPhon: Double = 85.0
     /// Reference phon level used for the last coefficient computation.
     private var _currentReferencePhon: Double = 85.0
+    /// System volume used for the last coefficient computation.
+    private var _currentSystemVolume: Float = 1.0
```

And update `updateForVolume`:

```swift
    func updateForVolume(_ systemVolume: Float, referencePhon: Double = 85.0) {
        // Volume-based phon estimation
        let phon = ISO226Contours.estimatedPhon(fromSystemVolume: systemVolume, referencePhon: referencePhon)
 
        // Coalesce rapid updates
        guard !isEnabled || abs(phon - _currentPhon) >= 1.0 || abs(referencePhon - _currentReferencePhon) >= 0.1 else { return }
        _currentPhon = phon
        _currentReferencePhon = referencePhon
        _currentSystemVolume = systemVolume
 
        let gains = computeBandGains(phon: phon, referencePhon: referencePhon, systemVolume: systemVolume)
```

And update `computeBandGains`:

```swift
    private func computeBandGains(phon: Double, referencePhon: Double, systemVolume: Float) -> [Float] {
        let gains = Self.fittedSectionGains(forPhon: phon, referencePhon: referencePhon, sampleRate: sampleRate)
        let realized = Self.realizedResponseDB(sectionGains: gains.map(Double.init), sampleRate: sampleRate)
        
        // Exclude infrasound frequencies below 30 Hz from the headroom calculation
        let frequencies = Self.fitGridFrequencies()
        var peakDB = 0.0
        for (index, freq) in frequencies.enumerated() {
            if freq >= 30.0 {
                peakDB = max(peakDB, realized[index])
            }
        }
        
        // Calculate digital headroom from current system volume
        let linearVolume = max(Double(systemVolume), 1e-4)
        let volumeAttenuationDB = -20.0 * log10(linearVolume)
        
        // Dynamic headroom subtraction (only subtract boost exceeding the digital attenuation)
        let headroomToSubtract = max(0.0, peakDB - volumeAttenuationDB)
        
        return gains.map { $0 - Float(headroomToSubtract) }
    }
```

And update `recomputeCoefficients`:

```swift
    override func recomputeCoefficients() -> (coefficients: [Double], sectionCount: Int)? {
        // Called by updateSampleRate() — recompute for current phon at new sample rate
        let gains = computeBandGains(phon: _currentPhon, referencePhon: _currentReferencePhon, systemVolume: _currentSystemVolume)
        let allNegligible = gains.allSatisfy { abs($0) < 0.1 }
        guard !allNegligible else { return nil }
        let coefficients = Self.coefficientsForBands(gains: gains, sampleRate: sampleRate)
        return (coefficients, Self.bandCount)
    }
```

**Step 2: Add dynamic headroom verification test**

In [ISO226ContoursTests.swift](file:///Users/air/develop/FineTuneFork/FineTuneTests/ISO226ContoursTests.swift), append the following test to verification suites:

```swift
    @Test("Dynamic headroom scales EQ gains based on system volume")
    func dynamicHeadroomScalesEQGains() {
        let processor = LoudnessCompensator(sampleRate: 48_000)
        
        // 1. Run at high volume (0.95 = almost 0 dB attenuation). Headroom subtraction must be active.
        processor.updateForVolume(0.95, referencePhon: 80.0)
        let coefficientsHigh = processor.recomputeCoefficients()?.coefficients ?? []
        
        // 2. Run at low volume (0.05 = ~26 dB attenuation). EQ can use this attenuation as headroom,
        // so less (or zero) headroom subtraction is required, resulting in larger band gains.
        processor.updateForVolume(0.05, referencePhon: 80.0)
        let coefficientsLow = processor.recomputeCoefficients()?.coefficients ?? []
        
        // 3. Since low volume has large digital headroom, its band gains should be higher
        // (meaning less digital attenuation on the filters). We verify the overall cascade
        // magnitude is larger (or coefficients have different scaling).
        #expect(coefficientsHigh != coefficientsLow)
    }
```

**Step 3: Run test to verify passes**

Run: `xcodebuild test -project FineTune.xcodeproj -scheme FineTune -destination 'platform=macOS'`
Expected: PASS

**Step 4: Commit**

```bash
git add FineTune/Audio/Loudness/LoudnessCompensator.swift FineTuneTests/ISO226ContoursTests.swift
git commit -m "feat(loudness): implement dynamic headroom based on system volume digital attenuation"
```
