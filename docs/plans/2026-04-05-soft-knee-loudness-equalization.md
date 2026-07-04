# Soft-Knee Loudness Equalization Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add one transparent default loudness-equalization mode that keeps upward leveling for quiet material and adds gentle soft-knee downward compression for louder passages.

**Architecture:** Extend `LoudnessEqualizerSettings` with safe default compression parameters, update `GainComputer` to combine the existing upward boost path with a soft-knee downward path, and cover the new behavior with focused unit tests. Keep the existing mono loudness detector, shared stereo gain, and final limiter unchanged.

**Tech Stack:** Swift, Swift Testing, real-time audio DSP helpers already in `FineTune/Audio/Loudness`

---

### Task 1: Add failing tests for the new gain-computer behavior

**Files:**
- Modify: `FineTuneTests/LoudnessEqualizerTests.swift`

**Step 1: Write the failing test**
- Replace the upward-only expectation with tests that verify:
  - quiet material still boosts toward target,
  - loud material now receives negative gain,
  - levels inside the knee receive only partial cut,
  - loud overshoots clamp at `maxCutDb`.

**Step 2: Run test to verify it fails**

Run: `xcodebuild test -project FineTune.xcodeproj -scheme FineTune -destination "platform=macOS" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO -only-testing:FineTuneTests/LoudnessEqualizerTests`

Expected: FAIL because `GainComputer` still implements upward-only behavior.

### Task 2: Implement the single soft-knee compression mode

**Files:**
- Modify: `FineTune/Audio/Loudness/LoudnessEqualizerSettings.swift`
- Modify: `FineTune/Audio/Loudness/GainComputer.swift`

**Step 1: Add default compression parameters**
- Keep the one-mode design internal to defaults.
- Add threshold offset / ratio / knee defaults that bias toward transparent night-mode behavior.

**Step 2: Update the gain computer**
- Preserve upward boost below target with noise-floor protection.
- Add a soft-knee downward curve for loud material above the compression threshold.
- Clamp downward gain by `maxCutDb`.

**Step 3: Run targeted verification**

Run: `xcodebuild test -project FineTune.xcodeproj -scheme FineTune -destination "platform=macOS" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO -only-testing:FineTuneTests/LoudnessEqualizerTests`

Expected: PASS

### Task 3: Verify no broader regressions in the loudness path

**Files:**
- Test: `FineTuneTests/LoudnessEqualizerTests.swift`

**Step 1: Run the full loudness test file again**
- Confirm the stereo-image and passthrough tests still pass with the new defaults.

**Step 2: Inspect defaults that are constructed in engine code**
- Ensure new settings remain safe when `LoudnessEqualizerSettings()` is created in `AudioEngine`.
