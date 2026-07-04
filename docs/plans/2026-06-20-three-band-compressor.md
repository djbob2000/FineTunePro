# Implement Three-Band Post-AGC Compressor

> **For Antigravity:** REQUIRED WORKFLOW: Use `.agent/workflows/execute-plan.md` to execute this plan in single-flow mode.

This plan details the implementation of a phase-aligned three-band compressor to replace the single-band `PostAgcCompressor`. This isolates low-frequency peaks (0–77 Hz and 77–200 Hz) so that they do not trigger compressor gain reduction on midrange and high-frequency content (vocals, presence), eliminating distortion and volume pumping at the final `SoftLimiter`.

## User Review Required

> [!IMPORTANT]
> - Crossover frequencies are set to **`77 Hz`** and **`200 Hz`**, splitting the audio spectrum into:
>   1. Band 1: `0 – 77 Hz` (Sub-bass / Bass)
>   2. Band 2: `77 – 200 Hz` (Mid-bass / Upper bass)
>   3. Band 3: `200 – 20,000 Hz` (Midrange / Treble)
> - The baseline threshold is configured to **`0.0 dBFS`** (instead of `+0.9 dBFS`).
> - Per-band thresholds map relatively to `thresholdDb`:
>   - Band 1: `thresholdDb - 8.9` (Default: **`-8.9 dBFS`**)
>   - Band 2: `thresholdDb - 6.0` (Default: **`-6.0 dBFS`**)
>   - Band 3: `thresholdDb` (Default: **`0.0 dBFS`**)

---

## Open Questions

*No additional design decisions or open questions are outstanding as the relative ratios, ballistics, and thresholds mapped from Stereo Tool are approved.*

---

## Proposed Changes

### Audio Dynamics Components

#### [MODIFY] [PostAgcCompressorSettings.swift](file:///Users/air/develop/FineTuneFork/FineTune/Audio/Loudness/PostAgcCompressorSettings.swift)
- Change default settings in `PostAgcCompressorSettings`:
  - `thresholdDb` = `0.0`
  - `ratio` = `7.6`
  - `attackMs` = `2.9`
  - `releaseMs` = `11.6`

#### [MODIFY] [PostAgcCompressor.swift](file:///Users/air/develop/FineTuneFork/FineTune/Audio/Loudness/PostAgcCompressor.swift)
- Define a nested helper struct `CompressorBand` to manage envelope followers, thresholds, attack/release coefficients, and current `gainReductionDb` state.
- Add crossover states to `PostAgcCompressor`: `crossover200Hz: [LinkwitzRileyCrossover2]` and `crossover77Hz: [LinkwitzRileyCrossover2]`.
- Update `init` and `process` channel configuration to lazily allocate and reset crossovers.
- Replace processing loop in `process` to:
  1. Cascade crossovers per channel to split into three bands.
  2. Compute peaks for each band.
  3. Calculate gain reduction for each band.
  4. Sum the compressed outputs back together.

---

### Bite-Sized Implementation Tasks

#### Task 1: Update Default Compressor Settings
- **Files**:
  - Modify: `FineTune/Audio/Loudness/PostAgcCompressorSettings.swift`
  - Modify: `FineTuneTests/PostAgcCompressorTests.swift`
- **Step 1**: Update defaults assertions in `PostAgcCompressorTests.defaultSettings` to verify `thresholdDb == 0.0`, `ratio == 7.6`, and `attackMs == 2.9`.
- **Step 2**: Run tests to verify they fail.
  - Run: `rtk xcodebuild -scheme FineTune -destination 'platform=macOS' test CODE_SIGNING_ALLOWED=NO -only-testing:FineTuneTests/PostAgcCompressorTests/defaultSettings`
- **Step 3**: Update `PostAgcCompressorSettings.swift` with the new defaults.
- **Step 4**: Run tests to verify they pass.
- **Step 5**: Commit.

#### Task 2: Implement Crossovers and Compressor Band State
- **Files**:
  - Modify: `FineTune/Audio/Loudness/PostAgcCompressor.swift`
- **Step 1**: Declare `CompressorBand` struct and crossovers `crossover200Hz`/`crossover77Hz` inside `PostAgcCompressor`.
- **Step 2**: Initialize bands (`band1`, `band2`, `band3`) and crossovers in `init` and adjust dynamically on channel count mismatch.
- **Step 3**: Verify project builds successfully:
  - Run: `rtk xcodebuild -scheme FineTune -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO`
- **Step 4**: Commit.

#### Task 3: Implement 3-Band Processing and Summing
- **Files**:
  - Modify: `FineTune/Audio/Loudness/PostAgcCompressor.swift`
- **Step 1**: Replace the single-band peak detection and processing logic in `process` with 3-band LR4 crossover splits, peak detection per band, independent band gain reductions, and output summing.
- **Step 2**: Verify project builds successfully.
- **Step 3**: Commit.

#### Task 4: Fix and Align Unit Tests
- **Files**:
  - Modify: `FineTuneTests/PostAgcCompressorTests.swift`
- **Step 1**: Update unit tests in `PostAgcCompressorTests` (e.g., using 1000 Hz for mid/high compression, adding sub-bass 50 Hz and mid-bass 120 Hz test cases) to confirm that crossovers split frequencies correctly and each band applies gain reduction independently.
- **Step 2**: Run tests to verify they pass:
  - Run: `rtk xcodebuild -scheme FineTune -destination 'platform=macOS' test CODE_SIGNING_ALLOWED=NO -only-testing:FineTuneTests`
- **Step 3**: Commit.

---

## Verification Plan

### Automated Tests
Run unit tests to ensure the 3-band compressor builds, processes audio dynamically, and has no regression issues:
```bash
rtk xcodebuild -scheme FineTune -destination 'platform=macOS' test CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO -only-testing:FineTuneTests
```
