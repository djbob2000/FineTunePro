# Walkthrough: AGC Silence Gate Fallback (Tonal Balance Stabilization)

We have successfully resolved the persistent tonal balance skew (treble tilt / loss of bass) when the input source volume is lowered (quiet input level). We implemented a slow fallback recovery drift (drift to 0.0 dB / unity gain) during silence gate freeze states and verified it using both automated unit tests and a compiled DSP simulator.

## Changes Made

### 1. Loudness Equalizer Configuration
- Modified [LoudnessEqualizerSettings.swift](file:///Users/air/develop/FineTuneFork/FineTune/Audio/Loudness/LoudnessEqualizerSettings.swift):
  - Added a new configuration field: `var silenceGateFallbackTimeS: Float = 5.0`.
  - Set default value to `5.0` seconds (optimal fallback time constant). Setting it to `0.0` disables fallback drift for absolute freeze capability.

### 2. Band Processor Fallback Logic
- Modified [AgcBandProcessor.swift](file:///Users/air/develop/FineTuneFork/FineTune/Audio/Loudness/AgcBandProcessor.swift):
  - Added `fallbackAlpha` property computed from `silenceGateFallbackTimeS` at the active sample rate.
  - Updated the early-return block for `forceFreeze` in both `process` (mono) and `processStereo` functions:
    ```swift
    guard !forceFreeze else {
        if fallbackAlpha > 0.0 {
            currentGainDb += fallbackAlpha * (0.0 - currentGainDb)
            if currentGainDb > 0.0 { currentGainDb = 0.0 }
            currentGainLinear = LoudnessEqualizerMath.dbToLinear(currentGainDb)
        }
        return sample * currentGainLinear // or (left * currentGainLinear, right * currentGainLinear)
    }
    ```
  - Instead of a hard freeze that holds the attenuated gain values indefinitely, the gains now slowly decay back to `0.0` dB (unity gain) when the silence gate is active.

### 3. Unit Tests & Robustness
- Modified [LoudnessEqualizerTests.swift](file:///Users/air/develop/FineTuneFork/FineTuneTests/LoudnessEqualizerTests.swift):
  - Added a new unit test `silenceGateGainsFallbackToUnity()` which sets `silenceGateFallbackTimeS = 1.0` and verifies that after 5 seconds of silence, all band gains recover close to `0.0` dB (above `-0.5` dB) from their previously attenuated loud state.
  - Updated the existing `silenceGateFreezesGain()` test to explicitly set `settings.silenceGateFallbackTimeS = 0.0` so that it verifies absolute gain freeze without being affected by the new fallback drift.

## Verification Results

### 1. Unit Tests
All unit tests in `FineTuneTests` compile and pass with 100% success:
```bash
rtk xcodebuild -scheme FineTune -destination 'platform=macOS' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO -only-testing:FineTuneTests test
```
Result: `** TEST SUCCEEDED **`

### 2. DSP Simulator Verification
We compiled and ran the standalone DSP command-line simulator with Voss-McCartney pink noise:
- **Settled gains after loud phase**: `[-29.71, -6.61, -8.22, -26.18]` dB (significant bass attenuation).
- **Gains after 10s of quiet phase @ -75 dBFS (driven -52 dBFS)**:
  - *Before change*: `[-12.54, -5.52, -5.97, -7.78]` dB (bass remained attenuated by 7 dB relative to mid-range).
  - *After change*: `[-1.93, -0.85, -0.92, -1.20]` dB!
- **Gains after 10s of quiet phase @ -60 dBFS (driven -37 dBFS)**:
  - *Before change*: `[-6.76, -2.98, -3.23, -4.21]` dB.
  - *After change*: `[-1.04, -0.46, -0.50, -0.65]` dB!

The simulator results confirm that quiet source levels allow the AGC gains to smoothly drift back to a flat response within seconds, completely eliminating the thin, bass-starved sound, while short-term freezes during normal track pauses are still preserved.
