# AGC Frequency Response Measurement Design

## Goal
Measure the frequency response of the `LoudnessEqualizer` (multiband AGC) when enabled vs disabled. Determine if there is a frequency response coloration or high-frequency boost when the AGC is disabled.

## Approach
A standalone Swift CLI utility compiles the required DSP sources directly alongside a measurement script. The script generates sine sweeps (20 Hz - 20 kHz), runs them through the processor with a warmup period to allow the dynamic envelopes to stabilize, and measures the RMS input/output ratios.

## Measurement Conditions
1. **AGC Disabled**: Pure linear path, expected to be completely flat.
2. **AGC Enabled, Low Input Level (-40 dBFS)**: Verification of crossover and static band offsets without active compression.
3. **AGC Enabled, High Input Level (-10 dBFS)**: Shows active compression shape.

## Verification
- ASCII tables showing absolute gain and relative gain to 1 kHz.
- Output saved to `scratch/output.txt`.
