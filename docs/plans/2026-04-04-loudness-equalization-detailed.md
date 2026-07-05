# Loudness Equalization Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a new global real-time Loudness Equalization feature for all routed apps, placed before Loudness Compensation, with mono sidechain analysis, full K-weighting biquad pair, shared gain riding, and final protection via the existing global `SoftLimiter`.

**Architecture:** Keep the audible path simple and low-latency: one shared gain applied equally to all channels, no multiband processing, no per-channel gain, and no LUFS-based live control loop. Implement the analysis sidechain separately: mono downmix, K-weighting, short-window RMS, detector smoothing, gain computer, and gain smoother. Integrate the processor into `ProcessTapController` before the existing `LoudnessProcessor`, and expose it via a new global app setting and UI toggle.

**Tech Stack:** Swift, Core Audio / `ProcessTapController`, AVAudioEngine-compatible architecture, Accelerate/vDSP where useful, Swift Testing, existing `SoftLimiter`, existing `BiquadMath`.

---

### Task 1: Add red integration tests for feature wiring and processing order

**Files:**

- Modify: `FineTuneTests/ProcessingPipelineTests.swift`

**Step 1: Write the failing test**

Add two tests to `ProcessingChainTests`:

- A test that verifies `AudioEngine` exposes a dedicated `setLoudnessEqualizationEnabled(_:)` path.
- A test that verifies Loudness Equalization is inserted before Loudness Compensation inside `ProcessTapController.processMappedBuffers(...)`.

Use simple source-based assertions first if that is the least invasive path.

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -scheme FineTune -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO -only-testing:FineTuneTests/ProcessingChainTests
```

Expected:

- FAIL because `setLoudnessEqualizationEnabled` does not exist yet.
- FAIL because `loudnessEqualizerProc` is not present in the processing chain yet.

**Step 3: Do not write production code yet**

The point of this task is only to lock down integration expectations.

**Step 4: Re-run to confirm red state is legitimate**

Expected:

- Failures point to missing Loudness Equalization wiring and missing processor ordering.
- No unrelated failures.

**Step 5: Commit**

Do not commit while tests are intentionally red.

---

### Task 2: Add red tests for settings, helper math, and DSP primitives

**Files:**

- Create: `FineTuneTests/LoudnessEqualizerTests.swift`

**Step 1: Write the failing tests**

Add test suites for:

- `LoudnessEqualizerSettings` MVP defaults
- dB/linear conversion helpers
- smoothing-coefficient helper behavior
- `KWeightingFilter` reset determinism / finite output
- `LoudnessDetector` attack faster than release
- `GainComputer` clamp behavior
- `GainComputer` noise-floor boost restriction
- `GainSmoother` fast-cut / slow-recovery behavior
- `LoudnessEqualizer` shared-gain stereo preservation

Suggested test list:

```swift
@Test("Settings default to approved MVP values")
func settingsDefaults()

@Test("dB and linear conversions round-trip within tolerance")
func dbLinearRoundTrip()

@Test("Shorter time constant produces faster smoothing coefficient")
func smoothingCoefficientOrder()

@Test("K-weighting reset reproduces identical output for same input")
func kWeightingResetDeterminism()

@Test("Detector attack responds faster than release")
func detectorAttackFasterThanRelease()

@Test("Gain computer clamps to max cut and boost")
func gainComputerClamps()

@Test("Gain computer limits boost below noise floor threshold")
func gainComputerNoiseFloorProtection()

@Test("Gain smoother reduces gain faster than it recovers")
func gainSmootherAsymmetry()

@Test("Shared gain preserves left-right ratio")
func loudnessEqualizerPreservesStereoImage()
```

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -scheme FineTune -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO -only-testing:FineTuneTests/LoudnessEqualizerTests
```

Expected:

- FAIL because the new types do not exist yet.

**Step 3: Keep the failures focused**

If the first version of the test file fails due to syntax or bad test setup, fix the tests before writing production code.

**Step 4: Re-run and confirm correct red state**

Expected:

- Missing-type / missing-behavior failures only.

**Step 5: Commit**

Do not commit while tests are intentionally red.

---

### Task 3: Implement the runtime settings model and helper math

**Files:**

- Create: `FineTune/Audio/Loudness/LoudnessEqualizerSettings.swift`
- Create: `FineTune/Audio/Loudness/LoudnessEqualizerMath.swift`
- Test: `FineTuneTests/LoudnessEqualizerTests.swift`

**Step 1: Implement `LoudnessEqualizerSettings`**

Create a production-style settings struct:

```swift
struct LoudnessEqualizerSettings: Codable, Equatable, Sendable {
    var targetLoudnessDb: Float = -20
    var maxBoostDb: Float = 10
    var maxCutDb: Float = 12

    var analysisWindowMs: Float = 20
    var analysisHopMs: Float = 10

    var detectorAttackMs: Float = 15
    var detectorReleaseMs: Float = 120

    var gainAttackMs: Float = 30
    var gainReleaseMs: Float = 700

    var noiseFloorThresholdDb: Float = -55
    var lowLevelMaxBoostDb: Float = 4

    var limiterCeilingDb: Float = -1
    var enabled: Bool = false
}
```

**Step 2: Implement `LoudnessEqualizerMath`**

Include:

- `dbToLinear(_:)`
- `linearToDb(_:)`
- `meanSquareToDb(_:)`
- `rmsFromMeanSquare(_:)`
- `clamp(_:min:max:)`
- `timeConstantCoefficient(timeMs:stepMs:)`

Use epsilon-safe conversions. Keep the functions deterministic and side-effect-free.

**Step 3: Run only the tests that should now pass**

Run:

```bash
xcodebuild test -scheme FineTune -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO -only-testing:FineTuneTests/LoudnessEqualizerTests
```

Expected:

- Settings/math tests pass.
- DSP tests still fail because the filter, detector, smoother, and processor do not exist yet.

**Step 4: Clean up naming before moving on**

Make sure helper names match how they will be used later. Avoid dead helpers.

**Step 5: Commit**

Recommended commit:

```bash
git add FineTune/Audio/Loudness/LoudnessEqualizerSettings.swift FineTune/Audio/Loudness/LoudnessEqualizerMath.swift FineTuneTests/LoudnessEqualizerTests.swift
git commit -m "feat: add loudness equalizer settings and helper math"
```

---

### Task 4: Implement the K-weighting sidechain filter

**Files:**

- Create: `FineTune/Audio/Loudness/KWeightingFilter.swift`
- Modify: `FineTune/Audio/EQ/BiquadMath.swift`
- Test: `FineTuneTests/LoudnessEqualizerTests.swift`

**Step 1: Add any missing reusable biquad math**

If needed, extend `BiquadMath` with a high-pass helper:

```swift
static func highPassCoefficients(
    frequency: Double,
    q: Double,
    sampleRate: Double
) -> [Double]
```

Only add helpers that are genuinely reused.

**Step 2: Implement `KWeightingFilter`**

Create a mono sidechain processor with two biquad sections:

- stage 1: high-shelf section
- stage 2: high-pass / RLB-like section

Use fixed K-weighting-style parameters and rebuild coefficients from `sampleRate`.

Suggested API:

```swift
final class KWeightingFilter: @unchecked Sendable {
    init(sampleRate: Float)
    func processSample(_ sample: Float) -> Float
    func updateSampleRate(_ sampleRate: Float)
    func reset()
}
```

Use direct-form state with fixed scalar fields. No allocations in `processSample`.

**Step 3: Run targeted tests**

Run:

```bash
xcodebuild test -scheme FineTune -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO -only-testing:FineTuneTests/LoudnessEqualizerTests/kWeightingResetDeterminism
```

Expected:

- PASS once reset determinism and finite-output behavior are correct.

**Step 4: Add one extra sanity test if needed**

If the first test is too weak, add:

- a low-frequency attenuation sanity check relative to `1 kHz`

Do not overfit to exact reference magnitudes unless you have a trustworthy source.

**Step 5: Commit**

```bash
git add FineTune/Audio/Loudness/KWeightingFilter.swift FineTune/Audio/EQ/BiquadMath.swift FineTuneTests/LoudnessEqualizerTests.swift
git commit -m "feat: add k-weighting sidechain filter"
```

---

### Task 5: Implement the detector and sidechain RMS measurement

**Files:**

- Create: `FineTune/Audio/Loudness/LoudnessDetector.swift`
- Test: `FineTuneTests/LoudnessEqualizerTests.swift`

**Step 1: Implement `LoudnessDetector`**

Design it as a block-safe, allocation-free state machine:

- preallocated ring buffer of squared samples
- running sum for efficient moving RMS
- `analysisWindowMs` and `analysisHopMs` converted to sample counts
- detector attack/release smoothing in dB domain using coefficients derived from hop duration

Suggested API:

```swift
final class LoudnessDetector: @unchecked Sendable {
    init(settings: LoudnessEqualizerSettings, sampleRate: Float)
    func ingest(weightedSample: Float) -> Float?
    func updateEnvelope(with measuredLevelDb: Float) -> Float
    func updateSettings(_ settings: LoudnessEqualizerSettings, sampleRate: Float)
    func reset()
}
```

`ingest(weightedSample:)` should return a new smoothed detector level only when a hop boundary is reached.

**Step 2: Run targeted detector tests**

Run:

```bash
xcodebuild test -scheme FineTune -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO -only-testing:FineTuneTests/LoudnessEqualizerTests/detectorAttackFasterThanRelease
```

Expected:

- PASS after the envelope asymmetry is correct.

**Step 3: Add one startup test if needed**

If you hit startup weirdness, add a test that confirms the detector does not return `NaN` or `inf` during the initial fill phase.

**Step 4: Re-run the whole test file**

Run:

```bash
xcodebuild test -scheme FineTune -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO -only-testing:FineTuneTests/LoudnessEqualizerTests
```

Expected:

- Detector-related tests pass.
- Gain and main processor tests may still fail.

**Step 5: Commit**

```bash
git add FineTune/Audio/Loudness/LoudnessDetector.swift FineTuneTests/LoudnessEqualizerTests.swift
git commit -m "feat: add loudness detector"
```

---

### Task 6: Implement the gain computer and gain smoother

**Files:**

- Create: `FineTune/Audio/Loudness/GainComputer.swift`
- Create: `FineTune/Audio/Loudness/GainSmoother.swift`
- Test: `FineTuneTests/LoudnessEqualizerTests.swift`

**Step 1: Implement `GainComputer`**

Suggested API:

```swift
struct GainComputer: Sendable {
    var settings: LoudnessEqualizerSettings
    func desiredGainDb(forLevelDb smoothedLevelDb: Float) -> Float
}
```

Behavior:

- `desiredGainDb = targetLoudnessDb - smoothedLevelDb`
- clamp to `[-maxCutDb, +maxBoostDb]`
- if `smoothedLevelDb < noiseFloorThresholdDb`, cap upward gain to `lowLevelMaxBoostDb`

**Step 2: Implement `GainSmoother`**

Suggested API:

```swift
final class GainSmoother: @unchecked Sendable {
    init(settings: LoudnessEqualizerSettings, sampleRate: Float)
    var currentGainDb: Float { get }
    func process(targetGainDb: Float) -> Float
    func updateSettings(_ settings: LoudnessEqualizerSettings, sampleRate: Float)
    func reset(initialGainDb: Float = 0)
}
```

Behavior:

- if target gain moves downward, react faster
- if target gain moves upward, recover more slowly

**Step 3: Run targeted tests**

Run:

```bash
xcodebuild test -scheme FineTune -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO -only-testing:FineTuneTests/LoudnessEqualizerTests/gainComputerClamps -only-testing:FineTuneTests/LoudnessEqualizerTests/gainComputerNoiseFloorProtection -only-testing:FineTuneTests/LoudnessEqualizerTests/gainSmootherAsymmetry
```

Expected:

- PASS

**Step 4: Re-run full LoudnessEqualizer test file**

Expected:

- Only the main processor tests should remain red.

**Step 5: Commit**

```bash
git add FineTune/Audio/Loudness/GainComputer.swift FineTune/Audio/Loudness/GainSmoother.swift FineTuneTests/LoudnessEqualizerTests.swift
git commit -m "feat: add loudness equalizer gain stages"
```

---

### Task 7: Implement the main Loudness Equalizer processor

**Files:**

- Create: `FineTune/Audio/Loudness/LoudnessEqualizer.swift`
- Test: `FineTuneTests/LoudnessEqualizerTests.swift`

**Step 1: Implement the class skeleton**

Suggested API:

```swift
final class LoudnessEqualizer: @unchecked Sendable {
    init(settings: LoudnessEqualizerSettings, sampleRate: Float, channelCount: Int)

    var isEnabled: Bool { get }
    var currentSettings: LoudnessEqualizerSettings { get }

    func process(
        input: UnsafePointer<Float>,
        output: UnsafeMutablePointer<Float>,
        frameCount: Int,
        channelCount: Int
    )

    func updateSettings(_ settings: LoudnessEqualizerSettings)
    func updateSampleRate(_ sampleRate: Float)
    func reset()
}
```

**Step 2: Implement the processing loop**

Per frame:

1. downmix current frame to mono for sidechain
2. apply `KWeightingFilter`
3. ingest into `LoudnessDetector`
4. when detector produces a new smoothed level:
   - compute desired gain via `GainComputer`
5. smooth that gain via `GainSmoother`
6. convert dB to linear
7. apply the same linear gain to every channel in the audible path

Keep this processor allocation-free during `process(...)`.

**Step 3: Preserve stereo image**

Make sure left/right ratio is unchanged except for one shared gain.

**Step 4: Run targeted tests**

Run:

```bash
xcodebuild test -scheme FineTune -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO -only-testing:FineTuneTests/LoudnessEqualizerTests/loudnessEqualizerPreservesStereoImage
```

**Step 5: Re-run the full loudness equalizer test file**

Run:

```bash
xcodebuild test -scheme FineTune -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO -only-testing:FineTuneTests/LoudnessEqualizerTests
```

Expected:

- PASS for all unit tests in that file.

**Step 6: Commit**

```bash
git add FineTune/Audio/Loudness/LoudnessEqualizer.swift FineTuneTests/LoudnessEqualizerTests.swift
git commit -m "feat: add loudness equalizer processor"
```

---

### Task 8: Integrate the processor into `ProcessTapController`

**Files:**

- Modify: `FineTune/Audio/Engine/ProcessTapControlling.swift`
- Modify: `FineTune/Audio/Engine/ProcessTapController.swift`
- Test: `FineTuneTests/ProcessingPipelineTests.swift`

**Step 1: Extend the tap protocol**

Add a new method:

```swift
func updateLoudnessEqualization(_ settings: LoudnessEqualizerSettings)
```

Do not overload the Loudness Compensation API. Keep the features separate.

**Step 2: Add processor storage to `ProcessTapController`**

Add primary and secondary instances:

- `loudnessEqualizerProcessor`
- `secondaryLoudnessEqualizerProcessor`

Follow the same dual-processor pattern already used by:

- `eqProcessor`
- `autoEQProcessor`
- `loudnessProcessor`

**Step 3: Construct processors during activation / crossfade**

Update:

- primary activation
- secondary-tap creation
- promotion cleanup
- sample-rate update path

Make sure secondary taps have their own independent DSP state.

**Step 4: Update `processMappedBuffers(...)`**

Add a new processor parameter:

```swift
loudnessEqualizerProc: LoudnessEqualizer?
```

Insert processing order as:

1. volume ramp
2. EQ
3. AutoEQ
4. Loudness Equalization
5. Loudness Compensation
6. `SoftLimiter`

**Step 5: Run red/green integration tests**

Run:

```bash
xcodebuild test -scheme FineTune -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO -only-testing:FineTuneTests/ProcessingChainTests
```

Expected:

- PASS for:
  - dedicated toggle wiring
  - equalization before compensation ordering

**Step 6: Add one extra regression test if needed**

If the feature can be enabled/disabled without reprocessing active taps, add a test for immediate re-enable behavior similar to the earlier Loudness Compensation regression.

**Step 7: Commit**

```bash
git add FineTune/Audio/Engine/ProcessTapControlling.swift FineTune/Audio/Engine/ProcessTapController.swift FineTuneTests/ProcessingPipelineTests.swift
git commit -m "feat: integrate loudness equalization into process tap"
```

---

### Task 9: Integrate the global toggle and persistence

**Files:**

- Modify: `FineTune/Settings/SettingsManager.swift`
- Modify: `FineTune/Audio/Engine/AudioEngine.swift`
- Modify: `FineTuneTests/SettingsManagerTests.swift`

**Step 1: Extend `AppSettings`**

Add:

```swift
var loudnessEqualizationEnabled: Bool = false
```

Update `init(from decoder:)` to default it safely when missing.

**Step 2: Add `AudioEngine` API**

Add:

```swift
func setLoudnessEqualizationEnabled(_ enabled: Bool)
```

Behavior:

- iterate active taps
- call `tap.updateLoudnessEqualization(...)`
- keep it separate from `setLoudnessCompensationEnabled(_:)`

**Step 3: Apply settings when creating taps**

In both tap-creation paths, after EQ/AutoEQ setup and before loudness compensation update, apply the new Loudness Equalization settings to the new tap.

**Step 4: Add settings tests**

Update `SettingsManagerTests.swift`:

- default round-trip includes `loudnessEqualizationEnabled == false`
- populated round-trip can persist `true`
- default `AppSettings` test includes this field

**Step 5: Run targeted tests**

Run:

```bash
xcodebuild test -scheme FineTune -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO -only-testing:FineTuneTests/SettingsJSONTests -only-testing:FineTuneTests/AppSettingsDefaultTests
```

Expected:

- PASS

**Step 6: Commit**

```bash
git add FineTune/Settings/SettingsManager.swift FineTune/Audio/Engine/AudioEngine.swift FineTuneTests/SettingsManagerTests.swift
git commit -m "feat: persist loudness equalization setting"
```

---

### Task 10: Expose the feature in the UI

**Files:**

- Modify: `FineTune/Views/Settings/SettingsView.swift`
- Modify: `FineTune/Views/MenuBarPopupView.swift`

**Step 1: Add a global settings toggle row**

Insert a new row in `SettingsView.swift` near Loudness Compensation:

- title: `Loudness Equalization`
- description: playback leveling / peak taming / night-mode style
- `isOn: $settings.loudnessEqualizationEnabled`

Keep it visually separate from Loudness Compensation.

**Step 2: Wire on-change propagation**

Update `MenuBarPopupView.swift`:

- detect when `loudnessEqualizationEnabled` changes
- call `audioEngine.setLoudnessEqualizationEnabled(...)`

**Step 3: Verify no accidental coupling**

Make sure toggling Loudness Equalization does not also toggle Loudness Compensation.

**Step 4: Run focused UI-adjacent tests if they exist**

If no direct UI tests exist, at minimum run:

```bash
xcodebuild test -scheme FineTune -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO -only-testing:FineTuneTests/SettingsJSONTests -only-testing:FineTuneTests/ProcessingChainTests
```

**Step 5: Commit**

```bash
git add FineTune/Views/Settings/SettingsView.swift FineTune/Views/MenuBarPopupView.swift
git commit -m "feat: add loudness equalization toggle"
```

---

### Task 11: Document the feature

**Files:**

- Create: `guide/loudness-equalization.md`
- Modify: `guide/iso226-2023-migration.md` only if a cross-reference is useful

**Step 1: Write a concise feature guide**

Document:

- what Loudness Equalization does
- how it differs from Loudness Compensation
- current chain order
- why K-weighting is sidechain-only
- why one shared gain is used
- why `SoftLimiter` remains the final safety stage

**Step 2: Add a short “limitations of MVP” section**

Include:

- no soft knee yet
- no lookahead limiter yet
- no long-term LUFS control loop
- no multiband behavior

**Step 3: If useful, cross-link from the ISO 226 migration note**

Only add a short “see also” if it improves discoverability.

**Step 4: Commit**

```bash
git add guide/loudness-equalization.md guide/iso226-2023-migration.md
git commit -m "docs: add loudness equalization guide"
```

---

### Task 12: Full verification before merge

**Files:**

- No new source files

**Step 1: Run targeted unit tests**

```bash
xcodebuild test -scheme FineTune -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO -only-testing:FineTuneTests/LoudnessEqualizerTests
xcodebuild test -scheme FineTune -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO -only-testing:FineTuneTests/ProcessingChainTests
xcodebuild test -scheme FineTune -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO -only-testing:FineTuneTests/SettingsJSONTests -only-testing:FineTuneTests/AppSettingsDefaultTests
```

**Step 2: Run the full unit test target**

```bash
xcodebuild test -scheme FineTune -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO -only-testing:FineTuneTests
```

Expected:

- `** TEST SUCCEEDED **`

If `FineTuneUITests-Runner` still has unrelated startup issues, note that explicitly and keep the verification focused on unit tests.

**Step 3: Manual sanity checks**

Build and run the app:

```bash
xcodebuild -scheme FineTune -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
open /Users/air/Library/Developer/Xcode/DerivedData/FineTune-*/Build/Products/Debug/FineTune.app
```

Manual checklist:

- toggle Loudness Equalization on/off without restarting app
- confirm it affects all routed apps
- confirm Loudness Compensation still works independently
- confirm loudness equalization reacts to loud peaks and quiet passages
- confirm stereo image stays centered
- confirm no obvious pumping on speech/music
- confirm no clipping beyond what `SoftLimiter` is expected to catch

**Step 4: Request code review**

Use `@requesting-code-review` before merging or finalizing the branch.

**Step 5: Final commit / branch handling**

Only after all tests and manual checks pass:

```bash
git status
git log --oneline -n 10
```

Then follow the normal finish flow.
