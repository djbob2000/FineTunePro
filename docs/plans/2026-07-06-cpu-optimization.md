# Audio Pipeline CPU Optimization Implementation Plan

> **For Antigravity:** REQUIRED WORKFLOW: Use `.agent/workflows/execute-plan.md` to execute this plan in single-flow mode.

**Goal:** Reduce CPU consumption of the DSP audio pipeline (currently loading 48% of one core) by optimizing Smart Volume (Loudness Equalizer), Loudness Compensation, and EQ Preset Auto (Dynamic Equalizer).

**Architecture:** 
1. Downsample the Loudness Equalizer control path (envelope tracking and AGC band logic) to run every 32 samples (hop-based update) using block-based peak/mean-square tracking, while leaving crossover audio-path filtering per-sample.
2. Optimize Loudness Compensation by changing custom `BiquadState` coefficients to `Float` to eliminate 45 `Double`-to-`Float` conversions per sample on the audio thread, and inline/merge `applyStereoBoost` to process in a single pass.
3. Optimize the Dynamic Equalizer (EQ Preset Auto) by transitioning struct states/coefficients to single-precision `Float` math, unrolling the nested 5-band loop, and storing biquad structures in local stack-allocated variables before the loop to eliminate bounds checks and copy-on-write overhead.

**Tech Stack:** Swift, CoreAudio, Accelerate/vDSP

---

### Task 1: Optimize Loudness Equalizer (Smart Volume) via Downsampled AGC Control Path

**Files:**
- Modify: [LoudnessEqualizer.swift](file:///Users/air/develop/FineTuneFork/FineTune/Audio/Loudness/LoudnessEqualizer.swift)
- Test: [LoudnessEqualizerTests.swift](file:///Users/air/develop/FineTuneFork/FineTuneTests/LoudnessEqualizerTests.swift)

**Step 1: Write the plan / check current tests**
Make sure unit tests pass before changes.
Run: `xcodebuild test -scheme FineTune -only-testing:FineTuneTests/LoudnessEqualizerTests -destination 'platform=macOS' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO`
Expected: PASS

**Step 2: Implement hop-based control path in LoudnessEqualizer.swift**
Modify `LoudnessEqualizer.swift`:
- Add properties for downsampling:
  ```swift
  private let hopSize: Int = 32
  private var hopCounter: Int = 0
  private var weightedSumSq: Float = 0.0
  private var bassSumSq: Float = 0.0
  private var masterSumSq: Float = 0.0
  private var blockBassDrivenPeak: Float = 0.0
  private var blockMasterDrivenPeak: Float = 0.0
  ```
- Store and precompute hop-specific coefficients in `init`:
  ```swift
  let hop = Float(32)
  self.attackNormHop = attackSpeedNorm * hop
  self.releaseNormHop = releaseSpeedNorm * hop
  let stepMsHop = (1000.0 / sampleRate) * hop
  self.envAttackCoeffHop = LoudnessEqualizerMath.timeConstantCoefficient(timeMs: 10, stepMs: stepMsHop)
  self.envReleaseCoeffHop = LoudnessEqualizerMath.timeConstantCoefficient(timeMs: 200, stepMs: stepMsHop)
  self.sjpAttackCoeffHop = LoudnessEqualizerMath.timeConstantCoefficient(timeMs: 5.0, stepMs: stepMsHop)
  if settings.silenceGateFallbackTimeS > 0 {
      self.fallbackAlphaHop = Float(1.0 - exp(-Double(hop) / (Double(sampleRate) * Double(settings.silenceGateFallbackTimeS))))
  } else {
      self.fallbackAlphaHop = 0.0
  }
  ```
- Update `process` loop to accumulate input squares and peak values over `hopSize` samples.
- Trigger envelope follower and band-level updates (`processBandHop`) only when `hopCounter >= hopSize` using the hop-specific coefficients and resetting accumulators.
- Apply gains `bassBand.currentGainLinear` and `masterBand.currentGainLinear` to each sample per-frame.

**Step 3: Verify and run tests**
Run: `xcodebuild test -scheme FineTune -only-testing:FineTuneTests/LoudnessEqualizerTests -destination 'platform=macOS' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO`
Expected: PASS

**Step 4: Commit**
```bash
git add FineTune/Audio/Loudness/LoudnessEqualizer.swift
git commit -m "perf: downsample LoudnessEqualizer AGC control path to run every 32 samples"
```

---

### Task 2: Optimize Loudness Compensation via Float-Based Biquads and Integrated Stereo Boost Loop

**Files:**
- Modify: [LoudnessCompensator.swift](file:///Users/air/develop/FineTuneFork/FineTune/Audio/Loudness/LoudnessCompensator.swift)
- Test: [LoudnessEqualizerTests.swift](file:///Users/air/develop/FineTuneFork/FineTuneTests/LoudnessEqualizerTests.swift) (contains wideness tests)
- Test: [ISO226ContoursTests.swift](file:///Users/air/develop/FineTuneFork/FineTuneTests/ISO226ContoursTests.swift)

**Step 1: Convert BiquadState to use Float fields in LoudnessCompensator.swift**
Modify `BiquadState` struct in `LoudnessCompensator.swift` (around line 602):
- Change type of `b0`, `b1`, `b2`, `a1`, `a2` to `Float`.
- Cast `Double` arguments to `Float` inside `updateCoefficients`.
- Remove `Float(...)` casts from the audio path in `process(_:)`:
  ```swift
  let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
  ```

**Step 2: Inline applyStereoBoost in the exciter processing loop**
Modify `LoudnessCompensator.process(...)`:
- When exciter is active, inline the mid/side decomposition, `_sideHPF` filtering, side boosting, and reconstruction directly inside the frame loop.
- Remove the second loop over `frameCount` (i.e. do not call `applyStereoBoost`).

**Step 3: Verify and run tests**
Run: `xcodebuild test -scheme FineTune -only-testing:FineTuneTests/ISO226ContoursTests -destination 'platform=macOS' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO`
Expected: PASS

**Step 4: Commit**
```bash
git add FineTune/Audio/Loudness/LoudnessCompensator.swift
git commit -m "perf: optimize LoudnessCompensator with Float biquad states and inline stereo boost"
```

---

### Task 3: Optimize Dynamic Equalizer (EQ Preset Auto) via Stack Buffering and Loop Unrolling

**Files:**
- Modify: [DynamicEqualizer.swift](file:///Users/air/develop/FineTuneFork/FineTune/Audio/EQ/DynamicEqualizer.swift)
- Test: [DynamicEqualizerTests.swift](file:///Users/air/develop/FineTuneFork/FineTuneTests/DynamicEqualizerTests.swift)

**Step 1: Convert DynamicEqualizer state and coefficients to Float**
Modify `DynamicEqualizer.swift`:
- Change `DynamicEqualizerBiquadState` and `BiquadCoefficients` to store `Float` variables instead of `Double`.
- Update `StereoBiquad` to process `Float` values.
- Cast coefficient values to `Float` inside `bandpassCoefficients` and `peakingCoefficients`.

**Step 2: Store filter structures locally and unroll loops in process()**
Modify `process(input:output:frameCount:)`:
- Extract `bandpassFilters` array into local stack-allocated variables before the loop:
  ```swift
  var bp0 = bandpassFilters[0]
  var bp1 = bandpassFilters[1]
  ...
  ```
- Unroll the bandpass filtering loop over the 5 bands using the local variables `bp0...bp4`.
- Copy back local variables to `bandpassFilters` array after the loop.
- Extract `peakingFilters` array into local stack-allocated variables before the second loop:
  ```swift
  var pk0 = peakingFilters[0]
  var pk1 = peakingFilters[1]
  ...
  ```
- Unroll the peaking cascade filtering loop over the 5 bands using the local variables `pk0...pk4`.
- Copy back local variables to `peakingFilters` array after the loop.
- Ensure all intermediate math (like `makeupGain`) uses `Float`.

**Step 3: Verify and run tests**
Run: `xcodebuild test -scheme FineTune -only-testing:FineTuneTests/DynamicEqualizerTests -destination 'platform=macOS' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO`
Expected: PASS

**Step 5: Commit**
```bash
git add FineTune/Audio/EQ/DynamicEqualizer.swift
git commit -m "perf: optimize DynamicEqualizer using Float math, local stack variables, and loop unrolling"
```
