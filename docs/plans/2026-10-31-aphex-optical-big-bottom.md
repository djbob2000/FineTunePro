# Aphex Optical Big Bottom Implementation Plan

> **For Antigravity:** REQUIRED WORKFLOW: Use `.agent/workflows/execute-plan.md` to execute this plan in single-flow mode.

**Goal:** Implement true Aphex Optical Big Bottom DSP architecture in `LoudnessCompensator.swift` with optical dynamic sustain leveling, fundamental retention, soft saturation, and headroom protection.

**Architecture:** Split low band ($\le 110$ Hz) into a parallel sidechain; pass through an optical envelope detector ($\tau_{\text{att}} \approx 8$ ms, $\tau_{\text{rel}} \approx 80$ ms) controlling dynamic gain $1.25 / \sqrt{1 + 3 env^2}$; clamp peaks with `smoothCompress`; saturate via $y(s) = s + 0.15 s^2 - 0.05 s^3$; filter with 20 Hz HPF (DC removal) and 280 Hz LPF; parallel mix with dry signal with calibrated headroom.

**Tech Stack:** Swift, Accelerate (vDSP), macOS AudioUnit / AVFoundation, Swift Testing (`Testing`).

---

### Task 1: Update DSP Logic in `FineTune/Audio/Loudness/LoudnessCompensator.swift`

**Files:**
- Modify: `FineTune/Audio/Loudness/LoudnessCompensator.swift`

**Step 1: Update Transfer Function & Optical Gain**
- Replace `generateBassHarmonics` with Aphex Big Bottom transfer function:
  $$y(s) = s + 0.15 s^2 - 0.05 s^3$$
  which retains the compressed fundamental $s$ while adding warm 2nd harmonic overtone ($0.15 s^2$) and soft-limiting 3rd harmonic ($-0.05 s^3$).
- Set optical gain formula to:
  `let optoGain = 1.25 / sqrt(1.0 + _bassEnvelope * _bassEnvelope * 3.0)`
- In `updateHeadroom`:
  `let bassWetMultiplier = 1.0 + Double(_lowExciterWet) * 1.10`
  `let bassPeakDB = max(0.0, peak) + 20.0 * log10(bassWetMultiplier)`

**Step 2: Build verification**
- Run `swift build` or `xcodebuild -scheme FineTune -destination 'platform=macOS' build-for-testing` to verify clean compilation.

---

### Task 2: Update Unit Tests in `FineTuneTests/ISO226ContoursTests.swift`

**Files:**
- Modify: `FineTuneTests/ISO226ContoursTests.swift`

**Step 1: Write/Update Unit Tests for Big Bottom Behavior**
- Test 1: `bassExciterRetainsFundamentalAndGeneratesHarmonics`: Drive compensator with 50 Hz sine wave; verify output contains strong 50 Hz fundamental and 100 Hz 2nd harmonic.
- Test 2: `bassExciterOpticalCompressorPreventsClipping`: Drive compensator with 0 dBFS 50 Hz tone at 35% and 25% volume; verify output peak stays strictly $\le 1.0$.
- Test 3: `bassExciterPostHPFEliminatesDCOffset`: Verify mean DC offset is $< 10^{-4}$.

**Step 2: Run tests to verify they pass**
- Run: `xcodebuild test -project FineTune.xcodeproj -scheme FineTune -destination 'platform=macOS' -only-testing:FineTuneTests/ISO226ContoursTests`
- Expected: All pass (exit code 0).

---

### Task 3: Full Test Suite Verification

**Step 1: Run complete FineTune test suite**
- Run: `xcodebuild test -project FineTune.xcodeproj -scheme FineTune -destination 'platform=macOS' -only-testing:FineTuneTests`
- Expected: 100% tests pass.

---

### Task 4: Release Binary Build & Codesign

**Step 1: Archive Release Scheme**
- Run `xcodebuild -scheme FineTune -configuration Release archive -archivePath build/FineTune.xcarchive`
- Copy `build/FineTune.xcarchive/Products/Applications/FineTune.app` to `build/FineTune.app`
- Ad-hoc sign: `codesign --force --deep --sign - build/FineTune.app`
- Verify signature: `codesign --verify --deep --strict build/FineTune.app`

---

### Task 5: Live Task Tracker Update, Commit & Push

**Step 1: Update task.md**
- Mark Task 18 done in `docs/plans/task.md`.

**Step 2: Commit and push**
- `git add -A && git commit -m "feat(dsp): implement true Aphex Optical Big Bottom architecture"`
- `git push origin feat/pure-harmonic-bass-exciter`
