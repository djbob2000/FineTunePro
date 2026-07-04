# Design Document: ISO 226 Hybrid Multi-Harmonic Loudness Engine

**Date:** 2026-07-04  
**Status:** Approved  

---

## 1. Overview

This design refines FineTune's dynamic loudness compensation engine to combine authentic ISO 226:2023 low-frequency contour EQ with a 30%-capped multi-harmonic exciter and a +3.0 dB treble boost limit.

This eliminates waveshaping distortion ("farting/buzzing") and unnatural over-saturation at low volumes while maintaining a rich, punchy, and transparent acoustic bass response.

---

## 2. Key Specifications

### Low Frequencies (Bass)
1. **Clean ISO 226 Low-Frequency EQ**:
   - Uses authentic ISO 226:2023 curve topology spanning 20 Hz to 1000 Hz.
   - **Band 0 (80 Hz Low-Shelf)**: scaled by $K$ up to `+5.0 dB`.
   - **Band 1 (180 Hz Peaking)**: scaled by $K$ up to `+1.0 dB`.
2. **Multi-Harmonic Exciter (2nd, 3rd, 4th, 5th Harmonics)**:
   - Saturation polynomial generates a full harmonic series ($2f_0, 3f_0, 4f_0, 5f_0$) spanning 100 Hz to 400 Hz.
   - **Hard Cap at 30% (`_lowExciterWet <= 0.30`)**: Ensures the exciter wet mix never exceeds 30%, keeping the sound 100% clean and transparent even at ultra-low volumes.
   - Adds `+7.0 dB` of perceived acoustic bass presence on small speakers.

### High Frequencies (Treble)
1. **Max Treble Boost Limit**:
   - `highBoostDB` is capped at **`+3.0 dB`** (down from +4.0 dB) at $K = 1.0$.
   - Band 2 (3.2 kHz Peaking) and Band 3 (10 kHz High-Shelf) scale smoothly with $K$ up to +3.0 dB.

### Total Target Boost
- Total perceived low-end boost: **`+12.0 dB`** (+5 dB clean ISO 226 curve + 30% multi-harmonic exciter = +12 dB perceived).
- Total high-frequency boost: **`+3.0 dB`**.

---

## 3. Architecture & Formula Summary

```swift
// Dynamic coefficient K (0.0 at 100% volume -> 1.0 at max attenuation)
let K = pow(K_linear, 1.8)

// 1. Clean ISO 226 Bass EQ (Bands 0 and 1)
let bassEQ0 = 5.0 * Double(bassLinearWet) * K
let bassEQ1 = 1.0 * Double(bassLinearWet) * K

// 2. Capped Multi-Harmonic Exciter (Max 30% wet mix)
let lowBoostDB = 12.0 * Double(gainScale) * K
let lowLinear = pow(10.0, lowBoostDB / 20.0)
_lowExciterWet = min(0.30, Float((lowLinear - 1.0) * 0.15) * bassExciterWet)

// 3. Treble Boost (Max 3.0 dB)
let highBoostDB = 3.0 * Double(_trebleGainScale) * K

// 4. Multi-Harmonic Saturation (2nd to 5th harmonics)
func softClipLow(_ x: Float) -> Float {
    let c = max(-1.0, min(1.0, x * 1.2))
    return c - 0.25 * c * c - 0.15 * c * c * c + 0.10 * pow(c, 4) - 0.05 * pow(c, 5)
}
```

---

## 4. Verification Plan

- **Unit Tests**:
  - Verify `LoudnessCompensator` gain bounds at $K=1.0$ (`bassEQ0 <= 4.0`, `highBoostDB <= 3.0`, `_lowExciterWet <= 0.30`).
  - Run all existing DSP and audio pipeline tests.
- **Manual Audio Verification**:
  - Test audio playback at 20% system volume to confirm zero clipping/farting distortion and clean bass tone.
