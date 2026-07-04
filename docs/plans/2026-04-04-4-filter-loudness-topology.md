# 4-Filter Loudness Topology Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace the current 10-band graphic-style loudness approximation with a 4-filter shelf/bell topology that better matches the ISO-derived target at low runtime cost.

**Architecture:** Keep ISO 226:2023 contour math unchanged. Replace the loudness fitting layer in `LoudnessProcessor` with a fixed 4-section biquad topology (`low-shelf`, two `peaking`, `high-shelf`) whose gains are solved against the target compensation curve on a log-frequency grid. Preserve headroom calculation by measuring the true peak of the fitted cascade.

**Tech Stack:** Swift, Accelerate/vDSP biquads, Swift Testing

---

### Task 1: Lock in regression coverage for the current overshoot problem

**Files:**
- Modify: `FineTuneTests/ISO226ContoursTests.swift`
- Test: `FineTuneTests/ISO226ContoursTests.swift`

**Step 1: Write the failing test**
- Add a test that computes the target loudness curve and the realized fitted cascade response at 3% volume.
- Assert the new 4-filter design stays within a bounded low-frequency error relative to target and improves on the old behavior.

**Step 2: Run test to verify it fails**
- Run: `xcodebuild test -scheme FineTune -destination "platform=macOS" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO -only-testing:FineTuneTests/LoudnessProcessorHeadroomTests`
- Expected: FAIL because the current 10-band direct-mapping overshoots the target in bass.

**Step 3: Write minimal implementation**
- No production changes yet; this task only establishes the failing regression.

**Step 4: Run test to verify it still fails for the right reason**
- Confirm the reported failure is the bass overshoot assertion, not a test bug.

**Step 5: Commit**
- Commit after the implementation passes later; do not commit a knowingly failing branch.

### Task 2: Replace the loudness fitting topology

**Files:**
- Modify: `FineTune/Audio/Loudness/LoudnessProcessor.swift`
- Modify: `FineTune/Audio/EQ/BiquadMath.swift` only if a missing helper is needed

**Step 1: Implement fixed 4-filter topology metadata**
- Define the four loudness filter sections with fixed types, center frequencies, and Q/slope values.

**Step 2: Implement response-basis evaluation**
- Compute each section's per-dB response contribution on a dense log-frequency grid using existing RBJ biquad formulas.

**Step 3: Solve gains against the target curve**
- Use a small least-squares solve to fit section gains to the ISO-derived target response.
- Keep this work off the audio callback; it runs only during volume/sample-rate updates.

**Step 4: Build final coefficients and preamp**
- Generate coefficients for the fitted sections and preserve headroom computation from the realized cascade peak.

**Step 5: Re-run targeted tests**
- Run the loudness tests after the new fitting logic is in place.

### Task 3: Update docs and validate behavior

**Files:**
- Modify: `guide/iso226-2023-migration.md`

**Step 1: Document the new topology**
- Replace references to the 10-band peaking approximation with the 4-filter shelf/bell fitting layer.

**Step 2: Document why the change was made**
- Note the prior bass overshoot and that the new fitting better tracks the target with lower runtime cost.

**Step 3: Run full verification**
- Run: `xcodebuild test -scheme FineTune -destination "platform=macOS" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO -only-testing:FineTuneTests`
- Expected: PASS.

**Step 4: Record measured deltas**
- Capture target-vs-realized response snapshots for representative volumes (3%, 10%, 25%, 50%).

**Step 5: Commit**
- `git add` modified files and commit once tests are green.
