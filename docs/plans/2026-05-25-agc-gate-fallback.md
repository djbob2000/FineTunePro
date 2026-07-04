# AGC Silence Gate Fallback Implementation Plan

> **For Antigravity:** REQUIRED WORKFLOW: Use `/execute-plan` to execute this plan in single-flow mode.

**Goal:** Resolve the persistent tonal balance skew (thin sound/loss of bass) when the input source volume is lowered.

**Architecture:** When the input signal is quiet, the AGC's silence gate freezes the gain reduction values of each band (e.g., Band 0 is frozen at -29 dB while mid bands are at -6 dB), trapping the equalizer in a heavily bass-attenuated state indefinitely. We will add a slow fallback drift back to 0.0 dB (unity gain) with a configurable time constant (default 5.0 seconds) during freeze states. This allows the multiband gains to slowly and smoothly recover to flat when playback is quiet or paused, restoring natural tonal balance.

**Tech Stack:** Swift, Audio Processing (DSP).

---

## Proposed Changes

### Loudness Settings

#### [MODIFY] [LoudnessEqualizerSettings.swift](file:///Users/air/develop/FineTuneFork/FineTune/Audio/Loudness/LoudnessEqualizerSettings.swift)
* Add a configurable fallback recovery time:
  ```swift
  /// Silence gate fallback recovery time in seconds. When the silence gate is active
  /// (gated/frozen), the band gains will slowly drift back to 0.0 dB (unity gain)
  /// with this time constant. This ensures that quiet playback eventually recovers
  /// to a flat, uncolored tonal balance, rather than staying stuck in a bass-attenuated state.
  /// Value of 5.0 seconds.
  var silenceGateFallbackTimeS: Float = 5.0
  ```

### Band Processor

#### [MODIFY] [AgcBandProcessor.swift](file:///Users/air/develop/FineTuneFork/FineTune/Audio/Loudness/AgcBandProcessor.swift)
* Cache `fallbackAlpha` calculated from `settings.silenceGateFallbackTimeS`.
* Update the early-return block for `forceFreeze` to update `currentGainDb` and `currentGainLinear` by drifting towards 0.0 dB before returning.

### Unit Tests

#### [MODIFY] [LoudnessEqualizerTests.swift](file:///Users/air/develop/FineTuneFork/FineTuneTests/LoudnessEqualizerTests.swift)
* Add `testSilenceGateGainsFallbackToUnity` to verify that frozen gains slowly decay back to 0.0 dB under silence.
* Verify existing silence gate tests still pass or adapt them for the slow drift behavior.

---

## Verification Plan

### Automated Tests
Run the project unit tests using `xcodebuild`:
```bash
rtk xcodebuild -scheme FineTune -destination 'platform=macOS' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO -only-testing:FineTuneTests test
```
Verify that `testSilenceGateGainsFallbackToUnity` succeeds and no existing tests are broken.

### Simulator Verification
1. Re-compile `scratch/sim`.
2. Run it to inspect the gains after the quiet phases:
   ```bash
   /Users/air/.gemini/antigravity-ide/brain/8ebcd157-4957-42ea-8d7f-27fab847a13d/scratch/sim
   ```
3. Verify that after 10s of quiet phase @ -75 dBFS, the gains have recovered close to 0 dB instead of remaining stuck at `-12.5` / `-7.7` dB.
