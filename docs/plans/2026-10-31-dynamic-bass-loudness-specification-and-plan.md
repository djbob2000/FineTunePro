# Dynamic Bass Loudness Compensation (Path 2) Specification & Implementation Plan

> **For Antigravity:** REQUIRED WORKFLOW: Use `.agent/workflows/execute-plan.md` to execute this plan in single-flow mode.

**Goal:** Eliminate the global -4 dB midrange attenuation in Loudness Compensation while preventing low-frequency clipping via band-limited dynamic bass soft-limiting and leveling.

**Architecture:** Keep midrange and high frequencies (everything above ~110 Hz, including vocals, speech, and guitars) at bit-exact unity gain ($0.0\text{ dB}$, $\text{gain} = 1.0$). Route the ISO 226 low-shelf boost and R-Bass multi-harmonics into a dedicated low-band dynamic leveler and soft-knee limiter ($f < f_c \approx 110\text{ Hz}$). On quiet to moderate listening levels, full bass boost is applied without compression; on loud 0 dBFS bass transients, only the low band is dynamically controlled to never exceed $1.0$ ($0\text{ dBFS}$), with zero ducking or muffling of the vocals.

**Tech Stack:** Swift 6, Accelerate (`vDSP`), Real-time CoreAudio DSP (RT-safe, zero allocations, SIMD math), Swift Testing.

---

## 1. Technical Specification (Design Document)

### 1.1 Problem Statement
1. **The Midrange Drop Bug:**  
   In current versions of FineTune, when Loudness Compensation is turned ON, `_preampGain` calculates a global attenuation based on the peak of the bass shelf:
   $$\text{cutDB} = \max(0, \text{peakGainDB} - \text{availableDB})$$
   Because the macOS application slider is at $1.0$ ($100\%$), $\text{availableDB} = -20 \log_{10}(1.0) = 0\text{ dB}$.  
   Consequently, `preProcess` attenuates the **entire audio buffer** by $-4\text{ to } -7\text{ dB}$.  
   The output peak/RMS indicator drops by $\approx 4\text{ dB}$, and the vocal/midrange energy is significantly muffled and pushed back.

2. **The Hardware Volume Reality:**  
   The user correctly identified that the macOS volume slider (e.g. 35%) controls the hardware DAC/amplifier voltage gain. The digital signal entering FineTune from audio players is always normalized up to $0\text{ dBFS}$ ($[-1.0, 1.0]$).  
   Simply removing `_preampGain` while keeping a static $+7.7\text{ dB}$ linear bass shelf would push full-scale 50 Hz sine waves to $+7.7\text{ dBFS}$ ($2.43$ in float), resulting in hard clipping or aggressive brickwall limiter distortion on loud kicks.

### 1.2 Path 2 Solution: Band-Limited Dynamic Bass Architecture

Instead of applying a global preamp cut that damages the entire frequency spectrum, we isolate the dynamic control strictly to the low-frequency band:

```
Input Signal x(t) [0 dBFS]
       │
       ├────────────────────────────────────────┐
       ▼                                        ▼
  Low-Pass Filter (fc ≈ 110 Hz)          High-Pass Residual
           x_low(t)                       x_midHigh(t) = x(t) - x_low(t)
       │                                        │
       ▼                                        │
  Loudness Bass Processing:                     │ (100% UNTOUCHED: 0.0 dB unity gain)
  1. Linear Shelf Boost (G_bass)                │ (Vocals, 1 kHz mids, speech stay at
  2. Waves R-Bass Harmonics (2f0..5f0)          │  exact original volume; no -4 dB drop)
           s_low(t)                             │
       │                                        │
       ▼                                        │
  Low-Band Dynamic Soft-Limiter / Leveler:      │
  - For |s_low| <= 0.75: Linear (100% boost)    │
  - For |s_low| > 0.75: Smooth Soft-Knee        │
    Asymptote <= 1.0 (0 dBFS ceiling)           │
       │                                        │
       ▼                                        │
    s_low_limited(t)                            ▼
       │                                 Treble Exciter Sidechain (x_high * wet)
       │                                        │
       └──────────────────┬─────────────────────┘
                          ▼
             Output y(t) = x_midHigh(t) + s_low_limited(t) + x_treble_exciter(t)
                          │
                          ▼
             Downstream BrickwallLimiter (final safety guard)
```

### 1.3 Key Mathematical Formulas

1. **Midrange / High Band Preservation:**
   $$\text{midHighL} = xL - \text{lowL}$$
   By definition, $\text{lowL} + (xL - \text{lowL}) \equiv xL$. When no bass limiting is occurring, the sum is bit-for-bit identical to the original signal.  
   Frequencies above $110\text{ Hz}$ experience **$0.00\text{ dB}$ attenuation**. The vocal level NEVER drops when Loudness is enabled.

2. **Total Bass Candidate:**
   $$\text{rawBassL} = \text{lowL} \cdot G_{\text{bass}} + (\text{harmLowL} \cdot \text{lowWet})$$
   where $G_{\text{bass}} = 10^{\text{bassEQ0DB} / 20}$ is the ISO 226 loudness gain target (up to $+7.7\text{ dB}$ at 35% volume).

3. **Low-Band Dynamic Soft Limiting (Zero Distortion Below Threshold, Transparent Saturation Above):**
   $$T = 0.75 \quad (-2.5\text{ dBFS})$$
   $$\text{softLimitBass}(u) = \begin{cases} 
   u, & |u| \le T \\
   \operatorname{sgn}(u) \cdot \left( T + (1.0 - T) \cdot \frac{v}{\sqrt{1 + v^2}} \right), & |u| > T \quad \text{where } v = \frac{|u| - T}{1.0 - T}
   \end{cases}$$
   - When $|u| \le 0.75$ (normal/quiet listening levels): output is $100\%$ linear with zero harmonic distortion.
   - When $|u| \to \infty$ (extreme full-scale 808 sub drops or kick transients): output smoothly asymptotes to $\pm 1.000$ ($0\text{ dBFS}$). It is mathematically impossible for the low band to exceed $0\text{ dBFS}$.
   - Because saturation occurs ONLY below $110\text{ Hz}$, any saturation overtones generated fall directly into the low-mid bass range ($110\dots 280\text{ Hz}$), reinforcing the musical bass without creating harsh intermodulation splatter in the vocal range.

4. **Global Preamp Elimination:**
   `_preampGain` is locked to $1.0$ ($0\text{ dB}$).
   `updatePreamp()` no longer applies global cuts to the biquad processor.

---

## 2. Implementation Tasks

### Task 1: Update Test Suite for Path 2 (Unity Midrange & Band-Limited Bass Safety)

**Files:**
- Modify: `FineTuneTests/LoudnessHeadroomRegressionTests.swift`

**Step 1: Update existing tests that expected midrange attenuation**
In `FineTuneTests/LoudnessHeadroomRegressionTests.swift`:
- Update `existingDigitalHeadroomIsUsed` to assert that 1,000 Hz midrange gain is $0.00\text{ dB}$ ($\pm 0.05\text{ dB}$) across all volume levels.
- Add test `midrangeRemainsUnityAcrossAllVolumes` confirming 1 kHz gain is unaffected by Loudness activation.
- Add test `fullScaleBassSineIsSafelyBounded` verifying that a $0\text{ dBFS}$ ($1.0$ amplitude) 50 Hz sine wave with full $+10\text{ dB}$ loudness boost produces peak output $\le 1.001$ without triggering global midrange cuts.

**Step 2: Run test to verify failure**
```bash
xcodebuild test -project FineTune.xcodeproj -scheme FineTune -only-testing:FineTuneTests/LoudnessHeadroomRegressionTests -destination "platform=macOS" CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO
```
Expected: FAIL (because current code attenuates 1 kHz by -4 to -10 dB).

---

### Task 2: Implement Dynamic Low-Band Limiter & Eliminate Global Preamp Cut in LoudnessCompensator

**Files:**
- Modify: `FineTune/Audio/Loudness/LoudnessCompensator.swift`

**Step 1: Set `_preampGain` to 1.0 and bypass global attenuation**
- In `preProcess()`, keep `_preampGain = 1.0` so no global attenuation is applied to the buffer.
- In `updateHeadroom()`, retain headroom tracking for metrics/tests if needed, but do not set `_preampGain < 1.0`.

**Step 2: Implement Low-Band Dynamic Limiter in `process()`**
- Extract low-frequency component:
  ```swift
  let lowL = _lpL.process(xL)
  let lowR = _lpR.process(xR)
  ```
- Derive mid/high residual:
  ```swift
  let midHighL = xL - lowL
  let midHighR = xR - lowR
  ```
- Compute bass excitation and apply linear boost to the low band.
- Pass the combined low-band signal through `softLimitBass()`:
  ```swift
  @inline(__always)
  private func softLimitBass(_ u: Float) -> Float {
      let a = abs(u)
      let threshold: Float = 0.75
      if a <= threshold { return u }
      let margin = 1.0 - threshold
      let v = (a - threshold) / margin
      let shaped = threshold + margin * (v / sqrt(1.0 + v * v))
      return u < 0 ? -shaped : shaped
  }
  ```
- Recombine:
  ```swift
  let outL = midHighL + limitedBassL + (filteredSatHighL * effectiveHighWet)
  let outR = midHighR + limitedBassR + (filteredSatHighR * effectiveHighWet)
  ```

**Step 3: Run unit tests to verify passes**
```bash
xcodebuild test -project FineTune.xcodeproj -scheme FineTune -only-testing:FineTuneTests/LoudnessHeadroomRegressionTests -destination "platform=macOS" CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO
```
Expected: PASS.

---

### Task 3: Full Test Suite Verification

**Files:**
- Test: `FineTuneTests/ISO226ContoursTests.swift`
- Test: `FineTuneTests/LoudnessHeadroomRegressionTests.swift`
- Test: Full `FineTuneTests` target

**Step 1: Run all unit tests**
```bash
xcodebuild test -project FineTune.xcodeproj -scheme FineTune -only-testing:FineTuneTests -destination "platform=macOS" CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO
```
Expected: All tests pass with exit code 0.

---

### Task 4: Release Build, Codesign & Verification

**Files:**
- Build output: `build/FineTune.app`

**Step 1: Build release archive and extract app**
```bash
xcodebuild archive -project FineTune.xcodeproj -scheme FineTune -configuration Release -archivePath build/FineTune.xcarchive CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO
rm -rf build/FineTune.app
cp -R build/FineTune.xcarchive/Products/Applications/FineTune.app build/FineTune.app
codesign --force --deep --sign - build/FineTune.app
codesign --verify --deep --strict build/FineTune.app
```
Expected: Verified successfully.

**Step 2: Commit and push**
```bash
git add FineTune/Audio/Loudness/LoudnessCompensator.swift FineTuneTests/LoudnessHeadroomRegressionTests.swift FineTuneTests/ISO226ContoursTests.swift
git commit -m "feat(loudness): implement Path 2 dynamic bass soft-limiter and unity midrange preservation"
git push origin feat/pure-harmonic-bass-exciter
```

