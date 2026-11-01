# Design: VU & Output Meter Stereo Fix and 30 FPS Upgrade

**Date**: 2026-07-08
**Topic**: Meter Stereo & FPS Upgrade

## 1. Problem Description

1. **Mono meter for stereo output**: When playing stereo sound (e.g., YouTube in a web browser), the output peak level meter displays only a single channel/bar (mono). This occurs because `AudioEngine.getOutputMeterSnapshot` aggregates all taps and collapses the entire snapshot to mono if *any* tap returns a channel count other than 2. Silent or inactive taps default to 1 channel (as initialized), causing the entire meter to degrade to mono.
2. **Meter update rate**: The meters currently refresh at 15 FPS. We want to upgrade this to 30 FPS to make the visual feedback smoother and measure/analyze the CPU usage implications.

## 2. Proposed Changes

### Component 1: `AudioEngine` (Core Engine)
- **File**: `FineTune/Audio/Engine/AudioEngine.swift`
- **Method**: `getOutputMeterSnapshot(for:)`
- **Logic**:
  - Filter taps for the specified device.
  - Determine if a stereo tap exists (`tap.outputChannelLevels.count == 2`).
  - If a stereo tap exists, or if there are no taps at all, set `isStereo = true` (defaulting to stereo on silence).
  - Aggregate levels:
    - If `isStereo` is true, map 2-channel taps directly and copy mono taps' level to both left and right channels.
    - If `isStereo` is false (e.g. mono or multichannel device), return a 2-channel level array `[maxLevel, maxLevel]` containing the maximum peak level replicated to both channels.

### Component 2: `DesignTokens` (UI Timing)
- **File**: `FineTune/Views/DesignSystem/DesignTokens.swift`
- **Constants**:
  - Change `Timing.vuMeterUpdateInterval` to `1.0 / 30.0`.
  - Change `Timing.outputMeterUpdateInterval` to `1.0 / 30.0`.

### Component 3: `DesignTokensTests` (Unit Tests)
- **File**: `FineTuneTests/DesignTokensTests.swift`
- **Asserts**: Update expected intervals to `1.0 / 30.0`.

## 3. Verification Plan

### Automated Tests
- Run `xcodebuild` unit tests (specifically `DesignTokensTests` and `AudioEngineTapInitialStateTests`) to ensure all assertions pass.

### Manual Verification
- Launch the application, play stereo sound in a browser, and confirm that both channels render separate levels.
- Confirm that the refresh rate feels smoother.
