# Remove Loudness Compensator Stereo Base Expansion Implementation Plan

> **For Antigravity:** REQUIRED WORKFLOW: Use `.agent/workflows/execute-plan.md` to execute this plan in single-flow mode.

**Goal:** Remove the stereo base expansion processing step from the Loudness Compensator pipeline in both implementation and tests.

**Architecture:** Delete `_sideHPF` state biquad, `stereoSideBoost` static constant, and the `applyStereoBoost` function. Simplify `process()` to directly write the Left and Right signals without Mid/Side encoding/decoding. Delete `LoudnessCompensatorStereoWidenerTests` suite.

**Tech Stack:** Swift, Accelerate (vDSP), xcodebuild

---

### Task 1: Clean Up LoudnessCompensator.swift

**Files:**
- Modify: `FineTune/Audio/Loudness/LoudnessCompensator.swift`

**Step 1: Write code changes to remove stereo widening state and logic**

Modify `FineTune/Audio/Loudness/LoudnessCompensator.swift` to:
1. Delete `private nonisolated(unsafe) var _sideHPF = BiquadState()` on line 80.
2. Delete `private static let stereoSideBoost: Float = 1.2` on line 90.
3. Modify `process(input:output:frameCount:)` to assign outputs directly instead of calling `applyStereoBoost` or performing Mid-Side calculations:
   - For bypassed/linear-only path:
     ```swift
     guard isEnabled, (lowWet > 0.0 || highWet > 0.0) else {
         // Apply linear correction headroom even if exciter is off
         if correction != 1.0 {
             var scale = correction
             vDSP_vsmul(output, 1, &scale, output, 1, vDSP_Length(frameCount * 2))
         }
         return
     }
     ```
   - For processed path:
     ```swift
     // Sum Dry + Wet and apply gain correction factor
     let outL = (xL + (filteredSatLowL * lowWet) + (filteredSatHighL * effectiveHighWet)) * correction
     let outR = (xR + (filteredSatLowR * lowWet) + (filteredSatHighR * effectiveHighWet)) * correction
     output[idxL] = outL
     output[idxR] = outR
     ```
4. Delete `applyStereoBoost` function entirely.
5. In `updateCrossoverCoefficients()`, delete the `sideHPFCoeffs` local variable, `_sideHPF.updateCoefficients(...)` and `_sideHPF.reset()` calls.

**Step 2: Run test to verify compilation error**

Run: `xcodebuild test -project FineTune.xcodeproj -scheme FineTune -destination 'platform=macOS' -only-testing:FineTuneTests CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO`
Expected: Compiler errors in `FineTuneTests/LoudnessEqualizerTests.swift` because `LoudnessCompensatorStereoWidenerTests` references deleted behaviors.

---

### Task 2: Clean Up Obsolete Unit Tests

**Files:**
- Modify: `FineTuneTests/LoudnessEqualizerTests.swift`

**Step 1: Delete LoudnessCompensatorStereoWidenerTests suite**

Delete the lines containing `LoudnessCompensatorStereoWidenerTests` and all its test methods from `FineTuneTests/LoudnessEqualizerTests.swift` (lines 1478–1551).

**Step 2: Run test to verify success**

Run: `xcodebuild test -project FineTune.xcodeproj -scheme FineTune -destination 'platform=macOS' -only-testing:FineTuneTests CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO`
Expected: `** TEST SUCCEEDED **`

**Step 3: Commit**

Run:
```bash
git add FineTune/Audio/Loudness/LoudnessCompensator.swift FineTuneTests/LoudnessEqualizerTests.swift docs/plans/
git commit -m "refactor: remove stereo base widening from LoudnessCompensator"
```
