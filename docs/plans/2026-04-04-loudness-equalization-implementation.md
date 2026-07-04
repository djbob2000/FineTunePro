# Loudness Equalization Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a new global real-time Loudness Equalization module for all routed apps, placed before Loudness Compensation and controlled by a new global toggle.

**Architecture:** Implement a single-pass playback leveller with mono analysis sidechain, K-weighting biquad pair, short-window RMS detector, detector smoothing, gain computer, gain smoothing, and one shared audible-path gain for all channels. Integrate it into `ProcessTapController` before existing Loudness Compensation and reuse the existing final `SoftLimiter` as end-of-chain protection.

**Tech Stack:** Swift, Accelerate/vDSP, AVAudioEngine/Core Audio-style real-time processing, Swift Testing

---

### Task 1: Add failing tests for the new global feature wiring

**Files:**
- Modify: `FineTuneTests/ProcessingPipelineTests.swift`
- Modify: `FineTuneTests/ISO226ContoursTests.swift` only if loudness-adjacent helpers are reused

**Step 1: Write the failing test**
- Add a test that verifies the new Loudness Equalization processor is ordered before Loudness Compensation in the processing chain.
- Add a test that verifies re-enabling the global Loudness Equalization toggle updates active taps immediately.

**Step 2: Run test to verify it fails**
- Run: `xcodebuild test -scheme FineTune -destination "platform=macOS" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO -only-testing:FineTuneTests/ProcessingPipelineTests`
- Expected: FAIL because the new module and wiring do not exist yet.

**Step 3: Write minimal implementation**
- No production code yet.

**Step 4: Run test to verify it still fails for the right reason**
- Confirm failure is due to missing Loudness Equalization integration, not a broken test.

**Step 5: Commit**
- Do not commit a failing branch.

### Task 2: Add failing DSP tests for the leveller primitives

**Files:**
- Create: `FineTuneTests/LoudnessEqualizerTests.swift`

**Step 1: Write the failing tests**
- Add tests for:
  - K-weighting filter reset/stability
  - detector attack faster than release
  - gain computer clamp behavior
  - noise-floor boost limiting
  - gain smoother fast-cut / slow-recovery behavior
  - shared gain applied equally to stereo channels

**Step 2: Run test to verify it fails**
- Run: `xcodebuild test -scheme FineTune -destination "platform=macOS" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO -only-testing:FineTuneTests/LoudnessEqualizerTests`
- Expected: FAIL because the module types are not implemented.

**Step 3: Write minimal implementation**
- No production code yet.

**Step 4: Re-run to verify correct red state**
- Confirm the missing-type / missing-behavior failures match the new tests.

**Step 5: Commit**
- Do not commit a failing branch.

### Task 3: Implement the core settings and helper math

**Files:**
- Create: `FineTune/Audio/Loudness/LoudnessEqualizerSettings.swift`
- Create: `FineTune/Audio/Loudness/LoudnessEqualizerMath.swift`

**Step 1: Add `LoudnessEqualizerSettings`**
- Include:
  - `targetLoudnessDb`
  - `maxBoostDb`
  - `maxCutDb`
  - `analysisWindowMs`
  - `analysisHopMs`
  - `detectorAttackMs`
  - `detectorReleaseMs`
  - `gainAttackMs`
  - `gainReleaseMs`
  - `noiseFloorThresholdDb`
  - `lowLevelMaxBoostDb`
  - `limiterCeilingDb`
  - `enabled`
- Provide MVP defaults from the approved design.

**Step 2: Add helper math**
- dB/linear conversions
- time-constant to smoothing-coefficient helpers
- clamp helpers
- epsilon-safe RMS conversions

**Step 3: Run targeted tests**
- Run the new `LoudnessEqualizerTests` subset.

**Step 4: Refine only as needed**
- Keep helpers minimal and deterministic.

**Step 5: Commit**
- Commit after tests are green for this task group if work is logically isolated.

### Task 4: Implement the sidechain filter and detector primitives

**Files:**
- Create: `FineTune/Audio/Loudness/KWeightingFilter.swift`
- Create: `FineTune/Audio/Loudness/LoudnessDetector.swift`
- Modify: `FineTune/Audio/EQ/BiquadMath.swift` only if a reusable helper is genuinely needed

**Step 1: Implement `KWeightingFilter`**
- Two-section biquad pair for mono sidechain input.
- Precompute coefficients per sample rate.
- Keep state resettable and allocation-free during processing.

**Step 2: Implement `LoudnessDetector`**
- Preallocated ring/window buffer.
- RMS windowing with hop-based updates.
- Detector attack/release smoothing derived from hop interval.

**Step 3: Run tests**
- Run: `xcodebuild test -scheme FineTune -destination "platform=macOS" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO -only-testing:FineTuneTests/LoudnessEqualizerTests`

**Step 4: Fix only failing DSP behaviors**
- Keep detector logic block-based and MVP-sized.

**Step 5: Commit**
- Commit after DSP primitive tests pass.

### Task 5: Implement the gain computer and gain smoother

**Files:**
- Create: `FineTune/Audio/Loudness/GainComputer.swift`
- Create: `FineTune/Audio/Loudness/GainSmoother.swift`
- Test: `FineTuneTests/LoudnessEqualizerTests.swift`

**Step 1: Implement `GainComputer`**
- `desiredGainDb = targetLoudnessDb - smoothedLevelDb`
- clamp to boost/cut bounds
- apply noise-floor upward-boost restriction

**Step 2: Implement `GainSmoother`**
- faster response for gain reduction
- slower recovery for gain increase

**Step 3: Run tests**
- Re-run `LoudnessEqualizerTests`.

**Step 4: Keep implementation minimal**
- No soft-knee or adaptive program modes in MVP.

**Step 5: Commit**
- Commit when gain logic tests pass.

### Task 6: Implement the main `LoudnessEqualizer` processor

**Files:**
- Create: `FineTune/Audio/Loudness/LoudnessEqualizer.swift`
- Test: `FineTuneTests/LoudnessEqualizerTests.swift`

**Step 1: Implement preallocated state**
- mono analysis buffer
- sidechain filter
- detector
- gain smoother
- cached settings/sample-rate/channel-count

**Step 2: Implement `process(...)`**
- mono downmix for analysis
- sidechain weighting
- RMS + detector smoothing
- gain computer
- gain smoothing
- apply one shared linear gain equally to all channels

**Step 3: Implement `updateSettings(...)` and `reset()`**
- no callback-thread allocations
- deterministic reset of filter/detector/smoother state

**Step 4: Run tests**
- Run `LoudnessEqualizerTests`.

**Step 5: Commit**
- Commit when processor tests pass.

### Task 7: Integrate the new processor into the engine and tap controller

**Files:**
- Modify: `FineTune/Audio/Engine/ProcessTapControlling.swift`
- Modify: `FineTune/Audio/Engine/ProcessTapController.swift`
- Modify: `FineTune/Audio/Engine/AudioEngine.swift`

**Step 1: Extend the tap abstraction**
- Add update API for Loudness Equalization enable/config propagation.

**Step 2: Add processor instances**
- primary and secondary processor instances in `ProcessTapController`
- initialize/reset/update sample rate alongside the existing processors

**Step 3: Insert into processing chain**
- place Loudness Equalization before Loudness Compensation

**Step 4: Add immediate toggle propagation**
- ensure toggling the feature on/off updates active taps immediately

**Step 5: Run targeted integration tests**
- Run `ProcessingPipelineTests` and `LoudnessEqualizerTests`.

**Step 6: Commit**
- Commit once integration tests are green.

### Task 8: Expose the feature in settings/UI

**Files:**
- Modify: `FineTune/Settings/SettingsManager.swift`
- Modify: `FineTune/Views/Settings/SettingsView.swift`
- Modify: `FineTune/Views/MenuBarPopupView.swift`

**Step 1: Add global app setting**
- `loudnessEqualizationEnabled`
- persist via settings JSON

**Step 2: Add UI toggle**
- make it global and separate from Loudness Compensation

**Step 3: Wire UI changes to `AudioEngine`**
- follow the existing pattern used by Loudness Compensation

**Step 4: Run focused tests**
- settings encoding/decoding tests
- any UI-adjacent integration tests already present

**Step 5: Commit**
- Commit once persistence and propagation behave correctly.

### Task 9: Document the feature and run full verification

**Files:**
- Modify: `guide/iso226-2023-migration.md` only if cross-reference is useful
- Create: `guide/loudness-equalization.md`

**Step 1: Write feature notes**
- architecture summary
- parameter defaults
- explain distinction from Loudness Compensation
- describe current MVP tradeoffs

**Step 2: Run full verification**
- Run: `xcodebuild test -scheme FineTune -destination "platform=macOS" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO -only-testing:FineTuneTests`
- Expected: PASS

**Step 3: Smoke-check app build**
- Run: `xcodebuild -scheme FineTune -configuration Debug -destination "platform=macOS" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build`
- Expected: BUILD SUCCEEDED

**Step 4: Record any known limitations**
- note that the final limiter is still the existing global `SoftLimiter`
- note future improvement path toward a better limiter

**Step 5: Commit**
- `git add` modified files and commit once verification is green.
