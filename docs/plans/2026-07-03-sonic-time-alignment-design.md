# Design Specification: Sonic Time Alignment (BBE Group Delay Alignment)

## Overview
Implements a 3-band time-alignment processor based on BBE Sound's US Patent 4,482,866 to compensate for loudspeaker voice coil inductance and physical cone inertia.

## Physics & Psychoacoustics
Physical speaker drivers inherently delay high frequencies due to voice coil inductance. By pre-delaying low and mid frequencies in software before reaching the speaker:
- **High Frequencies (HF > 3000 Hz)**: **0.0 ms delay** (emitted immediately).
- **Mid Frequencies (70 Hz < MF < 3000 Hz)**: **0.5 ms delay** (~24 samples at 48 kHz).
- **Low Frequencies (LF < 70 Hz)**: **2.5 ms delay** (~120 samples at 48 kHz).

When played through physical speakers, the physical speaker inertia aligns all 3 bands at the listener's ear, preventing low-frequency acoustic masking and restoring transient clarity.

## Architecture

### 1. Settings Persistence (SettingsManager.swift)
- Dictionary `deviceSonicAlignmentEnabled: [String: Bool]` (default `false`).
- `getSonicAlignmentEnabled(for deviceUID: String) -> Bool`
- `setSonicAlignmentEnabled(for deviceUID: String, to enabled: Bool)`

### 2. Real-Time DSP Processor (SonicAlignmentProcessor.swift)
- Filter bank splits audio into LF (sub-70 Hz), MF (70-3000 Hz), and HF (above 3000 Hz).
- Circular ring buffers for LF delay (2.5 ms) and MF delay (0.5 ms).
- Recombines output buffers sample-by-sample with zero allocation during audio callback.

### 3. UI (DeviceDetailSheet.swift)
- Toggle switch for **«Акустическое выравнивание фазы (Sonic Alignment)»**.
- Dynamic subtext explaining the BBE US4482866 group delay compensation mechanism.
