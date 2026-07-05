# 4-Band AGC Design Document

This document defines the architecture and implementation details for upgrading the Loudness Equalizer (multiband Auto Gain Control) from 3 bands to a premium **4-band layout**, matching the Hans van Zutphen / Stereo Tool preset **DutchChocolateMooseHot**.

---

## Crossover & Settings Layout

We configure the settings in `LoudnessEqualizerSettings.swift` to match the exact values from the screenshots:

### 1. Band Frequency Boundaries
* **Crossover Frequencies (`crossoverFrequenciesHz`)**: `[24.0, 923.0, 1143.0]` (splits the spectrum into 4 bands).
* **Bands**:
  * **Band 0 (Subsonic/Sub-bass)**: 0 – 24 Hz (isolates infrasonic rumble).
  * **Band 1 (Low-mid)**: 24 – 923 Hz (vocals, bass harmonics, main instrumentation).
  * **Band 2 (Mid-high)**: 923 – 1143 Hz (critical voice and presence transition).
  * **Band 3 (High)**: 1143 – 24,000 Hz (treble, sibilance, and high-frequency presence).

### 2. Per-Band Level and Speed Settings
* **Target Levels (`bandTargetLevelsDb`)**: `[-2.0, -1.0, -3.0, -6.0]` dB.
* **Attack Times (`attackTimesMs`)**: `[250.0, 122.0, 122.0, 122.0]` ms.
* **Release Times (`releaseTimesMs`)**: `[2000.0, 2000.0, 2010.0, 2010.0]` ms.

### 3. Crossover Windows and Linking
* **AGC Window dead zones (`agcWindowDb`)**: `[2.0, 2.0, 3.0, 3.0]` dB (full-width: dead zone where gain is frozen).
* **Channel Linking differences (`channelLinkDb`)**: `[3.0, 4.0, 5.0, 6.0]` dB (maximum allowed difference between adjacent bands: link 1->0 is 4.0 dB, link 2->1 is 5.0 dB, link 3->2 is 6.0 dB. The first value `linkDb[0] = 3.0` is unused).

### 4. Global Settings & Protection Defaults
* **Sudden Jump Protection**: `false` (disabled by default, matching the preset).
* **Sudden Drop Protection**: `true` (global flag).
  * Threshold: `12.0` dB.
  * Speedup: `2.5` multiplier.

---

## 4-Band Crossover Math (`LinkwitzRileyCrossover.swift`)

The crossover splits the audio using a symmetric tree structure of 4th-order Linkwitz-Riley filters. To compensate for the phase shifts introduced by the cascading splits, we apply parallel Linkwitz-Riley low-pass and high-pass filters as allpass compensators:

```
                           ┌─→ [LP4 @ f1] ──→ Band 0 (0–24 Hz)
            ┌─→ [AP @ f3] ─┤
            │              └─→ [HP4 @ f1] ──→ Band 1 (24–923 Hz)
input ──────┼─→ [LP4 @ f2]
            │              ┌─→ [LP4 @ f3] ──→ Band 2 (923–1143 Hz)
            └─→ [HP4 @ f2] ─┤
            │              └─→ [HP4 @ f3] ──→ Band 3 (1143–24000 Hz)
            └─→ [AP @ f1] ─┘
```

* **Low branch split at `f2` (923 Hz)** is compensated with **`AP_f3`** (which runs `LP4_f3 + HP4_f3`) before being split at `f1` (24 Hz).
* **High branch split at `f2` (923 Hz)** is compensated with **`AP_f1`** (which runs `LP4_f1 + HP4_f1`) before being split at `f3` (1143 Hz).

This guarantees that the sum of all 4 bands reconstructs the original signal with flat frequency magnitude response and no phase misalignment around the crossover regions.

---

## AGC Processing & Band Coupling (`LoudnessEqualizer.swift`)

In the stereo processing path:
1. We run **4 per-band processors** (`AgcBandProcessor`).
2. **Master Band Coupling**: Band 1 (Low-mid: 24–923 Hz) acts as the master. The slave bands (0, 2, 3) couple their gains using a coupling factor of `0.7`:
   ```swift
   let masterGain = gains[1]
   let couplingFactor: Float = 0.7
   for i in [0, 2, 3] {
       let blended = masterGain + couplingFactor * (gains[i] - masterGain)
       gains[i] = min(gains[i], blended)
   }
   ```
3. **Channel Linking**: We clamp differences between adjacent bands:
   * Difference between Band 1 and 0 is clamped by `channelLinkDb[1]` (4.0 dB).
   * Difference between Band 2 and 1 is clamped by `channelLinkDb[2]` (5.0 dB).
   * Difference between Band 3 and 2 is clamped by `channelLinkDb[3]` (6.0 dB).
