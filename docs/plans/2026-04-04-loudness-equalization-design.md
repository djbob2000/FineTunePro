# Loudness Equalization Design

## Goal

Add a new real-time `Loudness Equalization` playback leveller for all routed apps on macOS. It must behave like consumer playback volume leveling or night mode:
- reduce sudden loud peaks,
- make quieter details more audible,
- preserve intelligibility,
- avoid obvious pumping and breathing,
- avoid aggressive noise-floor lifting,
- preserve stereo image.

This module is separate from the existing ISO 226-based `Loudness Compensation` feature.

## Placement In The Existing DSP Chain

The current app-controlled chain is:

`volume -> EQ -> AutoEQ -> Loudness Compensation -> SoftLimiter`

The new chain will be:

`volume -> EQ -> AutoEQ -> Loudness Equalization -> Loudness Compensation -> SoftLimiter`

Rationale:
- `Loudness Equalization` is a dynamics/leveling stage.
- `Loudness Compensation` is a static spectral contour stage driven by device volume.
- The final `SoftLimiter` remains the end-of-chain safety net for the whole DSP path.

## User-Facing Behavior

- This is a global feature for all routed apps.
- It will be controlled by a new global toggle in `AppSettings`.
- It will not replace `Loudness Compensation`.
- It will not apply different gain per channel.
- It will not use LUFS / BS.1770 as the live control loop.

## Core DSP Architecture

### Main Audio Path

`input -> shared gain stage -> output`

In MVP, the audible path only applies one shared gain equally to all channels. The final limiter remains outside the module at the global end of the app DSP chain.

### Analysis Sidechain

`input -> mono downmix -> K-weighting biquad pair -> short-window RMS -> detector smoothing -> gain computer -> gain smoothing`

The sidechain is analysis-only. The K-weighting filter is not audible EQ coloration.

## Analysis Downmix

- Stereo: `mono = 0.5 * (L + R)`
- Multichannel: average all routed channels with one shared normalization factor
- Analysis is mono only
- Final gain is applied equally to all channels

This preserves stereo image because the control signal is shared.

## Sidechain Weighting

Use a full K-weighting-style biquad pair in the analysis sidechain:
- high-pass stage to suppress very low-frequency overreaction,
- high-frequency shelving stage to make the detector more perceptual.

This is preferred over a simple compressor detector because it reduces leveller bias toward sub-bass energy without coloring the audible path.

## Loudness-Like Measurement

Use short, real-time-safe RMS windows:
- `analysisWindowMs = 20`
- `analysisHopMs = 10`

Per update:
- compute mean square over the current analysis window,
- compute RMS,
- convert to dB with epsilon protection.

This is a short loudness-like measure, not a full LUFS control loop.

## Detector Envelope

Raw RMS is too unstable to drive gain directly.

Use detector smoothing with separate coefficients:
- detector attack: `15 ms`
- detector release: `120 ms`

The coefficients must be derived from hop duration and sample rate, not hardcoded blend constants.

Behavior:
- rising level -> faster detector response,
- falling level -> slower decay.

## Gain Computer

Use:

`desiredGainDb = targetLoudnessDb - smoothedLevelDb`

Clamp:
- `maxBoostDb = 10`
- `maxCutDb = 12`

Noise floor protection:
- `noiseFloorThresholdDb = -55`
- `lowLevelMaxBoostDb = 4`

If the detector is below the threshold, upward gain is restricted.

## Gain Smoothing

Gain itself gets a second smoothing stage:
- gain attack: `30 ms`
- gain release: `700 ms`

Behavior:
- gain reduction reacts faster,
- gain recovery is slower.

This creates “fast clamp, slow recovery” and reduces pumping.

## Final Limiting

The existing global `SoftLimiter` remains the final stage in MVP.

This is slightly different from a fully self-contained module with its own internal limiter, but it better matches the current architecture:
- one global safety limiter,
- no double limiting in the same chain,
- minimal disruption to the existing processing model.

The new settings type will still include `limiterCeilingDb` so the API can evolve later toward a dedicated better limiter.

## Swift Types

### `LoudnessEqualizerSettings`

Global runtime-tunable config:
- target loudness,
- max boost / cut,
- analysis window / hop,
- detector attack / release,
- gain attack / release,
- noise floor threshold,
- low-level max boost,
- limiter ceiling placeholder,
- enabled flag.

### `KWeightingFilter`

- mono sidechain processor
- two biquad sections
- sample-rate aware coefficient setup
- resettable internal state

### `LoudnessDetector`

- preallocated window/ring-buffer state
- RMS measurement
- level conversion to dB
- detector smoothing

### `GainComputer`

- stateless desired gain mapping
- clamp + noise-floor rule

### `GainSmoother`

- smoothed current control gain
- fast cut / slow recovery behavior

### `LoudnessEqualizer`

- orchestrates sidechain analysis and audible shared-gain application
- real-time safe
- no per-buffer allocations

## Integration Points

### Settings

Add a new global toggle and configuration in:
- `SettingsManager.AppSettings`
- menu/settings UI
- `AudioEngine`

### Tap Controller

Add a new processor pair in `ProcessTapController`:
- primary `loudnessEqualizerProcessor`
- secondary `loudnessEqualizerProcessor` for crossfade/device-switch handling

Process order becomes:
- app volume mapping,
- EQ,
- AutoEQ,
- Loudness Equalization,
- Loudness Compensation,
- SoftLimiter.

### RT Safety

All processing must remain:
- allocation-free on the callback thread,
- lock-free,
- file/network/UI free,
- deterministic with preallocated analysis buffers and fixed filter state.

## Test Strategy

### Unit DSP Tests

- K-weighting filter stability and reset
- detector attack/release behavior
- gain clamp rules
- noise-floor protection
- gain smoother cut vs recovery timing
- silence / denormal / NaN safety

### Processor Tests

- shared gain remains identical across channels
- quiet input does not get unbounded boost
- loud transient causes gain reduction
- recovery is slower than clamp

### Integration Tests

- global toggle propagates to all routed taps
- effect order is before `Loudness Compensation`
- toggling on/off takes effect immediately without waiting for device-volume changes

## Non-Goals For MVP

- full LUFS / BS.1770 live control loop
- multiband processing
- per-channel gain control
- speech/music presets
- dedicated lookahead brick-wall limiter

## Future Improvements

- soft knee
- better limiter with lookahead
- optional long-term LUFS monitor
- optional multiband extension
- optional speech/music presets
