# Horizontal VU Meter Redesign

This document describes the design for the high-resolution, horizontal VU meter in the Audio settings tab. It displays real-time RMS levels with a floating peak-hold indicator, matching the visual style of professional hardware.

## Features
1. **High Resolution**: Increased segment count from 16 to 35 discrete bars.
2. **Fixed-Width Layout**: Elements do not stretch to fit; instead, they have a fixed width of 6 points with 2 points spacing to form a total width of 278 points, visually aligning with the 280-point volume sliders.
3. **Dual Metering (RMS + Peak Hold)**:
   - The solid bar graph displays the RMS level.
   - A single segment shows the peak-hold level, which remains static for 0.5 seconds and then decays smoothly down to the current RMS level.
4. **Professional Color-Coding**:
   - **Green** (Safe, indices 0-19, up to -10 dBFS).
   - **Yellow/Orange** (Caution, indices 20-29, -9 to -2.5 dBFS).
   - **Red** (Clip warning, indices 30-34, -2 to 0 dBFS).

## Component Structure & Math

### 1. dB Threshold Mapping
A logarithmic distribution spanning `-45.0` to `0.0` dBFS:
```swift
private static let dbThresholds: [Float] = [
    -45.0, -43.0, -41.0, -39.0, -37.0, -35.0, -33.0, -31.0, -29.0, -27.0,
    -25.0, -23.0, -21.0, -19.0, -17.0, -15.0, -13.0, -12.0, -11.0, -10.0,
    -9.0, -8.0, -7.0, -6.0, -5.0, -4.5, -4.0, -3.5, -3.0, -2.5,
    -2.0, -1.5, -1.0, -0.5, 0.0
]
```

### 2. Peak Hold & Decay Logic
- `@State private var heldPeakLevel: Float = 0.0`
- Whenever `peakLevel` changes (via `.onChange(of: peakLevel)`):
  - If `newPeak >= heldPeakLevel`, reset `heldPeakLevel = newPeak` and reschedule a `0.5` second hold task.
  - If the hold task expires, decay `heldPeakLevel` towards `level` (RMS) at a rate of `0.015` linear units per frame at 30Hz.

### 3. Rendering in SwiftUI
- Render `35` rounded rectangles with a width of `6` and height of `8`.
- Lit condition: `level >= threshold` OR `index == peakBarIndex` where `peakBarIndex` matches the position of `heldPeakLevel`.
