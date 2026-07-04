# Design Specification: RME-Style Loudness Architecture with Low Vol Ref (-40 dB to -20 dB)

## Overview
Implements a single, RME ADI-2 DAC inspired **Harmonic Exciter Loudness Processor** in FineTune with user-configurable **Low Vol Reference (Plateau Level)** from -40 dB to -20 dB.

## Key Design Principles
1. **Single Processing Mode (Modern Exciter Only)**:
   - All loudness processing is performed by non-linear harmonic excitation (softClipLow and softClipHigh with HF sibilant tamer).
2. **Fixed Acoustic Crossovers**:
   - **Bass Crossover**: `70 Hz` (harmonics 140 Hz, 210 Hz).
   - **Treble Crossover**: `3000 Hz` (harmonics 6 kHz, 9 kHz, 12 kHz).
3. **Low Vol Reference (Plateau Level: -40 dB to -20 dB)**:
   - User configures `Low Vol Ref` in the range `[-40 dB ... -20 dB]` (default `-20 dB`).
   - Attenuation in macOS CoreAudio: `volDB = 40.0 * (systemVolume - 1.0)`.
   - Transition factor `K = clamp(-volDB / abs(lowVolRefDB), 0.0, 1.0)`.
   - At system volume 100% (0 dB drop): `K = 0.0` (0% wet, 100% bit-perfect dry).
   - At volume equal to `LowVolRef` (e.g. -20 dB / 50% system volume): `K = 1.0` (100% wet, max boost reached).
   - Below `LowVolRef` (e.g. 5% system volume): `K = 1.0` (**Plateau**, boost stays fixed at max).
4. **Max Boost Ceilings & Controls**:
   - Bass boost ceiling: `+12.0 dB` scaled by `bassAmount` (default 0.65).
   - Treble boost ceiling: `+12.0 dB` scaled by `trebleAmount` (default 0.65).
5. **UI Controls in DeviceDetailSheet**:
   - `Bass Amount` (0% ... 100%, default 65%).
   - `Bass Crossover Freq` (40 Hz ... 150 Hz, default 70 Hz).
   - `Treble Amount` (0% ... 100%, default 65%).
   - `Treble Crossover Freq` (1000 Hz ... 6000 Hz, default 3000 Hz).
   - `Low Vol Reference (Plateau Level)` (-40 dB ... -20 dB, default -20 dB).
