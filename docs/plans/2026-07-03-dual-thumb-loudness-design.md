# Design Specification: Dual-Thumb Active Range Loudness Architecture

## Overview
Replaces single-reference loudness controls in FineTune with an intuitive **Dual-Thumb Range Slider** («Диапазон тонкомпенсации») allowing users to configure both the **Start Level** (High Vol Ref) and **Max Plateau Level** (Low Vol Ref).

## Key Design Principles

### 1. User Interface (DeviceDetailSheet)
- **Single Range Slider**: A custom dual-thumb SwiftUI slider for «Диапазон тонкомпенсации».
- **Right Thumb ("Старт")**: Controls `startDB` in range `[-12.0 dB ... 0.0 dB]` (default `0.0 dB`, i.e. 100% volume).
- **Left Thumb ("Максимум")**: Controls `maxDB` in range `[-40.0 dB ... -20.0 dB]` (default `-20.0 dB`, i.e. 50% volume).
- **Dynamic Help Text**: Below the slider, dynamic text updates as thumbs move:
  > *"Чистый звук выше 100% громкости. Максимальный подъем тише 50% громкости."*

### 2. DSP Mathematics (LoudnessCompensator)
Given system volume $V \in [0.0, 1.0]$:
1. System volume in decibels: `volDB = 40.0 * (V - 1.0)`.
2. Piecewise transition ratio $K \in [0.0, 1.0]$:
   - If `volDB >= startDB`: $K = 0.0$ (0% wet mix, 100% bit-perfect dry).
   - If `volDB <= maxDB`: $K = 1.0$ (100% wet mix, capped plateau).
   - If `maxDB < volDB < startDB`:
     $$K = \frac{\text{startDB} - \text{volDB}}{\text{startDB} - \text{maxDB}}$$
3. Bass & Treble Exciter Boost calculation:
   - `lowBoostDB = K * 12.0 * gainScale`
   - `highBoostDB = K * 12.0 * trebleGainScale`
   - `_lowExciterWet = (10^(lowBoostDB / 20) - 1) * 1.5`
   - `_highExciterWet = 10^(highBoostDB / 20) - 1`
4. Dynamic Headroom Normalizer:
   - `_outputGainCorrection = 1.0 / max(1.0, 1.0 + 0.4 * _lowExciterWet + 0.4 * _highExciterWet)`
   - Guarantees peak output amplitude never exceeds 0 dBFS (0% clipping/overload distortion).

### 3. Settings Persistence (SettingsManager)
- Reuses `deviceLoudnessReferencePhon` as `startDB` (range `[-12, 0]`, default `0`).
- Adds `deviceLoudnessMaxDB` dictionary for `maxDB` (range `[-40, -20]`, default `-20`).
