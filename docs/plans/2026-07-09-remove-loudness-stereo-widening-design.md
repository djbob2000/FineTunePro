# Design: Remove Loudness Compensator Stereo Base Expansion

We are removing the stereo base widening (expansion) processing step from the Loudness Compensator pipeline in the FineTune project to keep processing lean, accurate, and aligned with YAGNI principles.

## Target Changes

### LoudnessCompensator.swift
1. **Remove Properties & Constants**:
   - `_sideHPF` state biquad.
   - `stereoSideBoost` static constant.
2. **Remove Helper Methods**:
   - `applyStereoBoost(output:frameCount:)`
3. **Update Setup & Lifecycle**:
   - Remove `sideHPFCoeffs`, updates, and resets for `_sideHPF` in `updateCrossoverCoefficients()`.
4. **Update Process Loop**:
   - Modify the fallback path in `process(input:output:frameCount:)` to not call `applyStereoBoost`.
   - Modify the processing frame loop in `process(input:output:frameCount:)` to write values directly to `output[idxL]` and `output[idxR]` rather than computing mid, side, filtering side, boosting side, and reconstructing stereo channels.

### LoudnessEqualizerTests.swift
1. **Remove Obsolete Tests**:
   - Delete the `LoudnessCompensatorStereoWidenerTests` test suite which tests the specific filtering and boosting behavior of the side channel.

## Verification
- Compile and run all unit tests in the `FineTuneTests` target using `xcodebuild`.
- Confirm all tests pass.
