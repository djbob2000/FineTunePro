# AGC Frequency Response Measurement Implementation Plan

> **For Antigravity:** REQUIRED WORKFLOW: Use `.agent/workflows/execute-plan.md` to execute this plan in single-flow mode.

**Goal:** Compile a standalone command-line tool to measure the frequency response of the `LoudnessEqualizer` (multiband AGC) with AGC enabled and disabled.

**Architecture:** Modify the existing `scratch/measure_response.swift` script to define its own `@main` entrypoint, remove the Xcode framework/dynamic-library import, compile it directly with all required DSP Swift sources, and execute it to output results to a file.

**Tech Stack:** Swift, `swiftc` compiler

---

### Task 1: Update measurement script in scratch directory

**Files:**
- Modify: `scratch/measure_response.swift`

**Step 1: Write the updated measurement code**
Rewrite `scratch/measure_response.swift` to generate sine sweeps at specific frequencies, run through the `LoudnessEqualizer` with warmup and measurement periods, calculate relative responses, and print the output.

**Step 2: Save the file**
Write the code to `/Users/air/.gemini/antigravity-ide/brain/8ebcd157-4957-42ea-8d7f-27fab847a13d/scratch/measure_response.swift`.

---

### Task 2: Compile the measurement tool

**Files:**
- Output: `scratch/measure_response`

**Step 1: Compile command**
Run `swiftc` to compile `measure_response.swift` with the required DSP source files directly:
```bash
swiftc -O -o /Users/air/.gemini/antigravity-ide/brain/8ebcd157-4957-42ea-8d7f-27fab847a13d/scratch/measure_response \
  /Users/air/.gemini/antigravity-ide/brain/8ebcd157-4957-42ea-8d7f-27fab847a13d/scratch/measure_response.swift \
  FineTune/Audio/Loudness/LoudnessEqualizer.swift \
  FineTune/Audio/Loudness/LoudnessEqualizerSettings.swift \
  FineTune/Audio/Loudness/AgcBandProcessor.swift \
  FineTune/Audio/Loudness/LinkwitzRileyCrossover.swift \
  FineTune/Audio/Loudness/LoudnessEqualizerMath.swift \
  FineTune/Audio/Loudness/KWeightingFilter.swift \
  FineTune/Audio/EQ/BiquadMath.swift \
  FineTune/Models/EQSettings.swift \
  FineTune/Models/AutoEQProfile.swift
```

**Step 2: Verify compilation succeeds**
Check if the output binary is created and has execute permissions.

---

### Task 3: Execute sweeps and save output

**Files:**
- Output: `scratch/output.txt`

**Step 1: Run the binary**
Run the compiled `measure_response` tool and redirect output to `/Users/air/.gemini/antigravity-ide/brain/8ebcd157-4957-42ea-8d7f-27fab847a13d/scratch/output.txt`.

**Step 2: Read output**
Verify the output is generated and shows correct headers and values.
