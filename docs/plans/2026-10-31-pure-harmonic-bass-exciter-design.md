# Pure Harmonic Bass Exciter (MaxxBass Architecture) Design

**Date:** 2026-10-31  
**Status:** Approved  
**Author:** Antigravity & User  

---

## 1. Problem Statement & Motivation

The existing bass exciter in `LoudnessCompensator.swift` suffers from architectural and psychoacoustic issues:

1. **Hard-Clipping with 1.4 Input Drive:**
   `let c = max(-1.0, min(1.0, x * 1.4))` causes any bass signal above -3 dBFS ($1.0 / 1.4 \approx 0.71$) to be abruptly hard-clipped at $\pm 1.0$, creating aliasing artifacts and harsh higher-order odd harmonics.
2. **Duplication of the Fundamental ($f_0$):**
   The polynomial $c - 0.25c^2 - 0.15c^3 + 0.10c^4 - 0.05c^5$ begins with the linear term $c$ ($1.4 \cdot x$). It functions primarily as a parallel linear booster with gain 1.4 rather than a pure harmonic exciter.
3. **Flawed Post-HPF Frequency (25 Hz):**
   Instead of filtering out the fundamental $f_0$ below the crossover frequency, the post-HPF was placed at 25 Hz solely as a DC blocker, leaving the duplicate fundamental intact.
4. **Phase Cancellation & Smearing:**
   Summing the phase-shifted, filtered, and saturated duplicate fundamental back into `x` caused comb-filtering in the 30–70 Hz sub-bass band.
5. **Preamp Over-Attenuation:**
   Because the exciter duplicated the fundamental at $1.4 \times$, `updateHeadroom` assumed a massive peak expansion (`Double(_lowExciterWet) * 1.4 * 1.55`), causing the preamp to suppress the entire master audio signal by up to -20 dB.

---

## 2. Target Architecture

The new implementation adopts a true **Missing Fundamental** psychoacoustic architecture (MaxxBass principle):

```
Main Audio Stream x(t) ────────────────────────────────────────────────────────(+)──► Output
   │                                                                            ▲
   │ (Parallel Sidechain)                                                       │
   ▼                                                                            │
1. Crossover LPF (fc = 70–80 Hz, Butterworth Q=0.707)                           │
   ▼                                                                            │
2. Smooth Sigmoid (s = x / sqrt(1 + x^2)) [Zero hard-clipping]                  │
   ▼                                                                            │
3. Pure Harmonic Series (No linear term x)                                      │
   h(s) = 0.35*s^2 + 0.12*s^3 + 0.04*s^4 + 0.01*s^5                            │
   ▼                                                                            │
4. Post-HPF at Crossover fc (70–80 Hz) [Strips fundamental & DC offset]         │
   ▼                                                                            │
5. Post-LPF at 280 Hz [Prevents mud in 250–350 Hz lower mids]                   │
   ▼                                                                            │
6. Wet Mix Gain (_lowExciterWet) ───────────────────────────────────────────────┘
```

### Key Guarantees
* **Main Bass Intact:** The dry audio signal is **never** high-passed or stripped of sub-bass. Real deep sub-bass (20–60 Hz) passes through untouched and receives authentic ISO 226 low-shelf EQ boost.
* **Pure Harmonics Only:** The sidechain produces **only** the 2nd, 3rd, 4th, and 5th harmonics ($2f_0, 3f_0, 4f_0, 5f_0$) spanning 80–280 Hz.
* **No Musical Dissonance:** Harmonics follow a steep decaying series ($w_2=0.35, w_3=0.12, w_4=0.04, w_5=0.01$), keeping the 5th harmonic (major third) negligible to avoid clashing with minor keys.
* **No Hard Clipping:** Sigmoid saturation guarantees $C^\infty$ smooth compression without hard edges.

---

## 3. Detailed DSP Specifications

### 3.1 Input Compression (Sigmoid)
```swift
@inline(__always)
private func smoothCompress(_ x: Float) -> Float {
    x / sqrt(1.0 + x * x)
}
```
* Asymptotes to $\pm 1.0$ smoothly as $x \to \pm \infty$.
* Taylor expansion at $0$: $x - \frac{1}{2}x^3 + \dots$, maintaining linearity for quiet signals.

### 3.2 Harmonic Generator (Zero Fundamental)
```swift
@inline(__always)
private func generateBassHarmonics(_ s: Float) -> Float {
    let s2 = s * s
    let s3 = s2 * s
    let s4 = s3 * s
    let s5 = s4 * s
    // Pure harmonic expansion with steep decay (no linear s term):
    return 0.35 * s2 + 0.12 * s3 + 0.04 * s4 + 0.01 * s5
}
```

### 3.3 Post Filtering (Bandpass [fc ... 280 Hz])
Two biquad states per channel:
1. `_lowPostHPFL` / `_lowPostHPFR`: High-Pass at `_bassCrossoverFrequency` (default 70–80 Hz, Q = 0.707).
2. `_lowPostLPFL` / `_lowPostLPFR`: Low-Pass at 280.0 Hz (Q = 0.707).

### 3.4 Headroom & Preamp Recalibration
In `updateHeadroom`:
The peak harmonic output of $h(s)$ for $|s| \le 1.0$ is bounded by $\sum |w_i| = 0.35 + 0.12 + 0.04 + 0.01 = 0.52$.
```swift
let harmonicMaxGain = 0.52
let wetGain = 1.0 + Double(_lowExciterWet) * harmonicMaxGain
    + Double(_highExciterWet) * 1.1 * 1.36
_peakGainDB = max(0, peak) + 20 * log10(wetGain)
```
This reduces unnecessary master attenuation by ~10–15 dB compared to the legacy budget.

---

## 4. Verification Plan

1. **Unit Tests in `ISO226ContoursTests.swift` / New Suite:**
   * **Fundamental Suppression Test:** Feed pure 40 Hz sine wave into sidechain; confirm that at the output of the sidechain filter, energy at 40 Hz is suppressed by $\ge 24\text{ dB}$ relative to the 2nd harmonic (80 Hz).
   * **DC Offset Test:** Confirm DC offset $< 10^{-4}$ on steady-state sine wave.
   * **Harmonic Decay Hierarchy:** Confirm $H_2 > H_3 > H_4 > H_5$.
   * **Headroom Sanity Test:** Verify `_preampGain` remains $\ge 0.75$ (-2.5 dB) at standard listening levels.
2. **Build and Test Verification:**
   * Execute full test suite via `swift test`.
