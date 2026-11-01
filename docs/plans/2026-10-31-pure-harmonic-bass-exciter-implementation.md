# Pure Harmonic Bass Exciter Implementation Plan

> **For Antigravity:** REQUIRED WORKFLOW: Use `.agent/workflows/execute-plan.md` to execute this plan in single-flow mode.

**Goal:** Implement the MaxxBass-inspired pure harmonic bass exciter in `LoudnessCompensator.swift` with smooth sigmoid compression, zero fundamental duplication, bandpass filtering [fc ... 280 Hz], and realistic headroom preamp calculation.

**Architecture:** Update `LoudnessCompensator.swift` DSP processing to replace the hard-clipped $1.4\times$ polynomial with a smooth sigmoid followed by a fundamental-free harmonic series. Update post-filter state to combine high-pass at the crossover frequency ($f_c$) with low-pass at 280 Hz. Recalibrate `updateHeadroom` to prevent master signal over-attenuation.

**Tech Stack:** Swift, Accelerate (`vDSP`), Custom Biquad DSP.

---

### Task 1: Update DSP State & Post-Filters in `LoudnessCompensator.swift`

**Files:**
- Modify: `FineTune/Audio/Loudness/LoudnessCompensator.swift`

**Step 1: Add Post-LPF filter states and update `updateCrossoverCoefficients`**
Add `_lowPostLPFL` and `_lowPostLPFR` biquad states. Configure `_lowPostHPFL/R` to use `_bassCrossoverFrequency` (instead of 25 Hz), and configure `_lowPostLPFL/R` to 280 Hz (Q = 0.707).

**Step 2: Verify build**
Run: `swift build`
Expected: Build succeeds.

---

### Task 2: Implement Smooth Sigmoid, Pure Harmonic Generator & Audio Process Loop

**Files:**
- Modify: `FineTune/Audio/Loudness/LoudnessCompensator.swift`

**Step 1: Replace `softClipLow` with `smoothCompress` and `generateBassHarmonics`**
Implement the fundamental-free harmonic polynomial:
$$h(s) = 0.35 s^2 + 0.12 s^3 + 0.04 s^4 + 0.01 s^5$$
Process through `_lowPostHPF` and `_lowPostLPF`.

**Step 2: Recalibrate `updateHeadroom`**
Update `wetGain` formula using bounded harmonic budget (0.52).

**Step 3: Verify build**
Run: `swift build`
Expected: Build succeeds.

---

### Task 3: Unit Tests for Harmonic Purity & Regression Safety

**Files:**
- Modify/Extend: `FineTuneTests/ISO226ContoursTests.swift`

**Step 1: Write tests for fundamental rejection, DC offset elimination, and headroom preservation**
Verify:
1. Low exciter output contains negligible energy at input fundamental frequency $f_0$.
2. DC offset after processing is zero ($< 10^{-5}$).
3. Preamp gain does not drop by more than -3.0 dB at maximum compensation.

**Step 2: Run all tests**
Run: `swift test --filter ISO226ContoursTests`
Expected: PASS.

---

### Task 4: Full Suite Verification & Final Commit

**Step 1: Run entire test suite**
Run: `swift test`
Expected: All tests pass.

**Step 2: Commit all changes**
Git commit with descriptive message.

