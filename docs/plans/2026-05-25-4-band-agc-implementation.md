# 4-Band AGC Upgrade Implementation Plan

> **For Antigravity:** REQUIRED WORKFLOW: Use `.agent/workflows/execute-plan.md` to execute this plan in single-flow mode.

**Goal:** Upgrade the Loudness Equalizer (AGC) from a 3-band layout to a 4-band layout matching the DutchChocolateMooseHot preset.

**Architecture:** Update settings model to have 4 bands by default, implement a 4-band Linkwitz-Riley crossover with parallel allpass phase compensation, and update the LoudnessEqualizer processing loop to run 4 band processors with Low-mid (Band 1) master coupling and 4-band channel linking.

**Tech Stack:** Swift, Core Audio, `xcodebuild`

---

### Task 1: Update LoudnessEqualizerSettings to 4-band defaults

**Files:**
- Modify: `FineTune/Audio/Loudness/LoudnessEqualizerSettings.swift`
- Modify: `FineTuneTests/LoudnessEqualizerTests.swift:13-43`

**Step 1: Write the failing test**
Update the `settingsDefaults` test in `FineTuneTests/LoudnessEqualizerTests.swift` to verify the new 4-band preset parameters:
```swift
    @Test("Settings default to approved values")
    func settingsDefaults() {
        let s = LoudnessEqualizerSettings()
        #expect(s.driveDb == 23.0)
        #expect(s.targetLevelDb == -8.5)
        #expect(s.ratio == Float.infinity)
        #expect(s.progressiveRatio == false)
        #expect(s.maxDynamicAdjustment == 2.0)
        #expect(s.suddenJumpProtection == false)
        #expect(s.suddenJumpThresholdDb == 6.0)
        #expect(s.silenceGateThresholdDb == -50.1)
        #expect(s.silenceGateSlowdownDb == -35.0)
        #expect(s.gateSlowdownFactor == 0.086)
        #expect(s.dynamicSpeedFastThresholdDb == 3.0)
        #expect(s.dynamicSpeedSlowThresholdDb == 1.0)
        #expect(s.rmsWindowSizeMs == 40.0)
        #expect(s.enabled == false)
        #expect(s.crossoverFrequenciesHz == [24.0, 923.0, 1143.0])
        #expect(s.bandTargetLevelsDb == [-2.0, -1.0, -3.0, -6.0])
        #expect(s.channelLinkDb == [3.0, 4.0, 5.0, 6.0])
        #expect(s.agcWindowDb == [2.0, 2.0, 2.0, 3.0])
        #expect(s.attackTimesMs == [250.0, 122.0, 122.0, 122.0])
        #expect(s.releaseTimesMs == [2000.0, 2000.0, 2010.0, 2010.0])
        #expect(s.suddenDropProtection == true)
        #expect(s.suddenDropThresholdDb == 12.0)
        #expect(s.suddenDropSpeedup == 2.5)
        #expect(s.dynamicAttackSpeedup == 3.0)
        #expect(s.dynamicReleaseSlowdown == 1.0)
    }
```

**Step 2: Run test to verify it fails**
Run: `xcodebuild -scheme FineTune -destination 'platform=macOS' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO -only-testing:FineTuneTests/LoudnessEqualizerTests/settingsDefaults test`
Expected: FAIL due to assertions on 3-band default mismatches.

**Step 3: Write minimal implementation**
Update `FineTune/Audio/Loudness/LoudnessEqualizerSettings.swift` default values:
```swift
    var suddenJumpProtection: Bool = false
    var crossoverFrequenciesHz: [Float] = [24.0, 923.0, 1143.0]
    var bandTargetLevelsDb: [Float] = [-2.0, -1.0, -3.0, -6.0]
    var channelLinkDb: [Float] = [3.0, 4.0, 5.0, 6.0]
    var agcWindowDb: [Float] = [2.0, 2.0, 2.0, 3.0]
    var attackTimesMs: [Float] = [250.0, 122.0, 122.0, 122.0]
    var releaseTimesMs: [Float] = [2000.0, 2000.0, 2010.0, 2010.0]
```

**Step 4: Run test to verify it passes**
Run: `xcodebuild -scheme FineTune -destination 'platform=macOS' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO -only-testing:FineTuneTests/LoudnessEqualizerTests/settingsDefaults test`
Expected: PASS

**Step 5: Commit**
Run:
```bash
git add FineTune/Audio/Loudness/LoudnessEqualizerSettings.swift FineTuneTests/LoudnessEqualizerTests.swift
git commit -m "feat: update LoudnessEqualizerSettings to 4-band defaults"
```

---

### Task 2: Implement LinkwitzRileyCrossover4

**Files:**
- Modify: `FineTune/Audio/Loudness/LinkwitzRileyCrossover.swift`
- Modify: `FineTuneTests/LinkwitzRileyCrossoverTests.swift`

**Step 1: Write the failing test**
Add a test suite `LinkwitzRileyCrossover4Tests` to `FineTuneTests/LinkwitzRileyCrossoverTests.swift` verifying:
- Allpass Reconstruction (flat summation within 1.0 dB across 20Hz-20kHz sweep).
- Band Separation for pure tones in Band 0 (20 Hz), Band 1 (500 Hz), and Band 3 (5000 Hz).
- Zero input stability.

**Step 2: Run test to verify it fails**
Run: `xcodebuild -scheme FineTune -destination 'platform=macOS' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO -only-testing:FineTuneTests/LinkwitzRileyCrossover4Tests test`
Expected: FAIL (compilation error, type not found).

**Step 3: Write minimal implementation**
Implement `LinkwitzRileyCrossover4` in `FineTune/Audio/Loudness/LinkwitzRileyCrossover.swift`:
```swift
struct LinkwitzRileyCrossover4 {
    private var lp4_f2: LR4Filter
    private var hp4_f2: LR4Filter

    private var lp4_f3_ap: LR4Filter
    private var hp4_f3_ap: LR4Filter
    private var lp4_f1_ap: LR4Filter
    private var hp4_f1_ap: LR4Filter

    private var lp4_f1: LR4Filter
    private var hp4_f1: LR4Filter
    private var lp4_f3: LR4Filter
    private var hp4_f3: LR4Filter

    init(frequencies: [Double], sampleRate: Double) {
        precondition(frequencies.count == 3, "Need exactly 3 crossover frequencies for 4 bands")
        let f1 = frequencies[0]
        let f2 = frequencies[1]
        let f3 = frequencies[2]

        lp4_f2 = LR4Filter(lowPass: f2, sampleRate: sampleRate)
        hp4_f2 = LR4Filter(highPass: f2, sampleRate: sampleRate)

        lp4_f3_ap = LR4Filter(lowPass: f3, sampleRate: sampleRate)
        hp4_f3_ap = LR4Filter(highPass: f3, sampleRate: sampleRate)
        lp4_f1_ap = LR4Filter(lowPass: f1, sampleRate: sampleRate)
        hp4_f1_ap = LR4Filter(highPass: f1, sampleRate: sampleRate)

        lp4_f1 = LR4Filter(lowPass: f1, sampleRate: sampleRate)
        hp4_f1 = LR4Filter(highPass: f1, sampleRate: sampleRate)
        lp4_f3 = LR4Filter(lowPass: f3, sampleRate: sampleRate)
        hp4_f3 = LR4Filter(highPass: f3, sampleRate: sampleRate)
    }

    @inline(__always)
    mutating func process(_ sample: Float) -> (Float, Float, Float, Float) {
        let lowBranch = lp4_f2.process(sample)
        let highBranch = hp4_f2.process(sample)

        let lowCompensated = lp4_f3_ap.process(lowBranch) + hp4_f3_ap.process(lowBranch)
        let highCompensated = lp4_f1_ap.process(highBranch) + hp4_f1_ap.process(highBranch)

        let band0 = lp4_f1.process(lowCompensated)
        let band1 = hp4_f1.process(lowCompensated)

        let band2 = lp4_f3.process(highCompensated)
        let band3 = hp4_f3.process(highCompensated)

        return (band0, band1, band2, band3)
    }

    mutating func reset() {
        lp4_f2.reset(); hp4_f2.reset()
        lp4_f3_ap.reset(); hp4_f3_ap.reset()
        lp4_f1_ap.reset(); hp4_f1_ap.reset()
        lp4_f1.reset(); hp4_f1.reset()
        lp4_f3.reset(); hp4_f3.reset()
    }
}
```

**Step 4: Run test to verify it passes**
Run: `xcodebuild -scheme FineTune -destination 'platform=macOS' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO -only-testing:FineTuneTests/LinkwitzRileyCrossover4Tests test`
Expected: PASS

**Step 5: Commit**
Run:
```bash
git add FineTune/Audio/Loudness/LinkwitzRileyCrossover.swift FineTuneTests/LinkwitzRileyCrossoverTests.swift
git commit -m "feat: implement LinkwitzRileyCrossover4 with phase compensation"
```

---

### Task 3: Upgrade LoudnessEqualizer to 4-band processing

**Files:**
- Modify: `FineTune/Audio/Loudness/LoudnessEqualizer.swift`
- Modify: `FineTuneTests/LoudnessEqualizerTests.swift`

**Step 1: Write the failing test**
Update existing tests in `FineTuneTests/LoudnessEqualizerTests.swift` (e.g. `loudSignalAttenuatedToTarget`, `quietSignalNoAttenuation`, etc.) to account for 4 bands and adapt any expected defaults/configurations. 

**Step 2: Run test to verify it fails**
Run: `xcodebuild -scheme FineTune -destination 'platform=macOS' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO -only-testing:FineTuneTests/LoudnessEqualizerTests test`
Expected: FAIL (compilation errors due to 3-band layout in `LoudnessEqualizer`).

**Step 3: Write minimal implementation**
Update `FineTune/Audio/Loudness/LoudnessEqualizer.swift`:
- Change `crossoverL` and `crossoverR` to `LinkwitzRileyCrossover4`.
- Change `bandProcessors` to map `0..<4`.
- Update `processStereo` and `processMono` to process 4 bands.
- Set coupling master to `gains[1]` and couple indices `[0, 2, 3]`.
- Update channel linking for 4 bands (`1..<4`).
- Update final gain summation to sum all 4 bands: `outL = out0 + out1 + out2 + out3` and `outR = out0 + out1 + out2 + out3`.

**Step 4: Run test to verify it passes**
Run: `xcodebuild -scheme FineTune -destination 'platform=macOS' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO -only-testing:FineTuneTests/LoudnessEqualizerTests test`
Expected: PASS

**Step 5: Commit**
Run:
```bash
git add FineTune/Audio/Loudness/LoudnessEqualizer.swift FineTuneTests/LoudnessEqualizerTests.swift
git commit -m "feat: upgrade LoudnessEqualizer to 4-band processing with coupling and channel linking"
```

---

### Task 4: Verify full pipeline integration and run regression tests

**Files:**
- Modify: `FineTuneTests/ProcessingPipelineTests.swift`

**Step 1: Run integration test**
Run: `xcodebuild -scheme FineTune -destination 'platform=macOS' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO -only-testing:FineTuneTests/ProcessingPipelineTests/testFullDynamicsChain test` (adapt naming if needed to match `Full dynamics chain: AGC + compressor + compensator...`)
Expected: PASS

**Step 2: Verify all unit tests pass**
Run: `xcodebuild -scheme FineTune -destination 'platform=macOS' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO -only-testing:FineTuneTests test`
Expected: PASS (except UITests-Runner).

**Step 3: Commit**
Run:
```bash
git commit --allow-empty -m "test: verify all unit tests and pipeline integration pass under 4-band AGC"
```
