# Design Document: Three-Band Post-AGC Compressor

This document details the architectural design for replacing the single-band `PostAgcCompressor` with a three-band compressor. This design prevents low-frequency signals (bass and kick drums), especially when boosted by the preceding EQ, from causing intermodulation distortion or aggressive pumping at the final `SoftLimiter`.

## Architecture & Signal Flow

To process audio in a phase-aligned, transparent manner, we split the stereo signal into three bands using a cascaded tree of 4th-order Linkwitz-Riley (LR4) crossovers. The bands are reconstructed at the output by summing the compressed band outputs.

### Signal Split & Sum Tree (per channel)

```text
                             ┌──> LR4 High (>= 200 Hz) ─────> Band 3 Compressor ──┐
Input ──> Crossover (200 Hz) ─┤                                                    ├──> Sum ──> Output
                             └──> LR4 Low (< 200 Hz) ──> Crossover (77 Hz) ─┐      │
                                                            ├──> LP (0-77 Hz)  ──> Band 1 ─┤
                                                            └──> HP (77-200 Hz) ─> Band 2 ─┘
```

The crossovers are configured as follows:
- **Crossover 1**: LR4 at 200 Hz. High-pass output maps to Band 3. Low-pass output feeds Crossover 2.
- **Crossover 2**: LR4 at 77 Hz. Low-pass output maps to Band 1 (Sub-bass). High-pass output maps to Band 2 (Mid-bass).

---

## Band Settings & Dynamics Mapping

To preserve the relative compression ratios and balance modeled in Stereo Tool's "Studio One" preset, we translate the relative offsets between band thresholds to our digital full-scale (`dBFS`) domain, referencing the user-configurable global threshold `thresholdDb` (which defaults to `0.0 dBFS`):

### Band 1: Sub-bass (0 – 77 Hz)
- **Threshold**: `thresholdDb - 8.9` (Default: **`-8.9 dBFS`**)
- **Ratio**: `4.0` (4:1)
- **Attack Time**: `67.0 ms`
- **Release Time**: `1080.0 ms`
- **Knee**: `0.1 dB`

### Band 2: Mid-bass (77 – 200 Hz)
- **Threshold**: `thresholdDb - 6.0` (Default: **`-6.0 dBFS`**)
- **Ratio**: `4.0` (4:1)
- **Attack Time**: `52.0 ms`
- **Release Time**: `599.0 ms`
- **Knee**: `0.1 dB`

### Band 3: Mid/High (200 – 20,000 Hz)
- **Threshold**: `thresholdDb` (Default: **`0.0 dBFS`**)
- **Ratio**: `settings.ratio` (Default: `7.6` / 7.6:1)
- **Attack Time**: `settings.attackMs` (Default: `2.9 ms`)
- **Release Time**: `settings.releaseMs` (Default: `11.6 ms`)
- **Knee**: `settings.kneeDb` (Default: `0.1 dB`)

All three bands share the same:
- **Exponential Release Factor**: `0.8` (release slows down as gain reduction approaches 0 dB).
- **Max Release Speed Limit**: `settings.maxReleaseSpeed` (Default: `0.502502918`).

---

## Real-Time Safety & Implementation Details

To conform to the **RT-safety contract** of the audio thread:
1. **Zero Heap Allocations in Audio Loop**: The crossover filter banks (`LinkwitzRileyCrossover2` arrays) are pre-allocated during initialization or dynamic channel count changes. Temporary frame buffers are allocated on the stack (using fixed-size local variables or pre-allocated structures).
2. **Independent Envelope Followers**: Each band maintains its own peak level history and current gain reduction state (`gainReductionDb`) per processor instance.
3. **Phase Summation**: Because Linkwitz-Riley 4th-order filters sum to flat amplitude and phase (360-degree phase shift at crossover points), summing the three bands back together results in a perfectly flat frequency and phase response when no compression is occurring.
