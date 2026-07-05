# AGC Overload and Output Level Meter Design

## Problem Description
1. **AGC Overload/Clipping**: Currently, the per-app volume gain is applied *before* the AGC/LoudnessEqualizer. When the user sets the app volume slider low, the AGC receives a very quiet input signal and boosts it up to +23 dB (Drive), fighting the volume slider. This causes extreme clipping and overload distortion on transient peaks, which the post-AGC compressor cannot fully catch.
2. **Missing Level/Clip Indication**: The user wants real-time visualization of the output level and a "clip" indicator next to the AGC toggle to monitor when the post-AGC compressor is active.

## Proposed Design

### 1. Signal Chain Refactoring
We will re-order the signal processing chain in `ProcessTapController.processMappedBuffers`:
* **Input Stage**: Channel mapping is performed at unity gain (1.0).
* **Effects Stage**: `EQ`, `AutoEQ`, `LoudnessEqualizer` (AGC), and `PostAgcCompressor` process the signal at its original full-scale level.
* **Volume/Crossfade Stage**: Apply application volume scaling and crossfade ramps *after* the compressor.
* **Output Stage**: `LoudnessCompensator` (loudness contour) and `SoftLimiter` are applied to the final output signal.

### 2. Output Level & Clip Monitoring (RT Thread)
* **Output Peak Tracking**: Inside `ProcessTapController.swift`, after the `SoftLimiter` processes the output buffer, we will measure the max absolute sample value and smooth it as `_outputPeakLevel` (for primary) and `_secondaryOutputPeakLevel` (for secondary) using `levelSmoothingFactor`.
* **Compression Detection**: Expose `currentGainReductionDb` from `PostAgcCompressor.swift`. In `ProcessTapController.swift`, we will check if the active compressor is reducing gain by more than `0.1 dB` (i.e. `currentGainReductionDb < -0.1`).
* **AudioEngine Aggregation**: Add properties to `AudioEngine.swift` to retrieve the maximum output level (`maxOutputLevel`) and whether any tap is currently compressing (`isPostAgcCompressing`).

### 3. SwiftUI UI Features (AudioTab.swift)
* Add a small horizontal `VUMeter` and a red "clip" indicator dot (circular LED) next to the Auto Gain Control toggle.
* Use a polling task to query levels and compression state at 30Hz.
* Implement a 500ms hold time for the clip indicator using a SwiftUI `Task` to make short transient clipping events clearly visible to the user.
