# ISO 226 Hybrid Multi-Harmonic Loudness Implementation Plan

> **For Antigravity:** REQUIRED WORKFLOW: Use `.agent/workflows/execute-plan.md` to execute this plan in single-flow mode.

**Goal:** Implement the ISO 226 Hybrid Loudness Engine with 30%-capped multi-harmonic exciter and +3.0 dB treble ceiling.

**Architecture:** Update `LoudnessCompensator.swift` to generate 2nd to 5th harmonics in `softClipLow`, cap `_lowExciterWet` at `0.30`, cap `highBoostDB` at `3.0 dB`, and restore the clean ISO 226 low-end EQ section gains (+4.0 dB shelf / +0.8 dB peak).

**Tech Stack:** Swift, Accelerate (vDSP), XCTest.

---

### Task 1: Update LoudnessCompensator DSP Engine

**Files:**
- Modify: `FineTune/Audio/Loudness/LoudnessCompensator.swift:165-200,475-490`

**Step 1: Write minimal implementation in LoudnessCompensator.swift**

```swift
// 1. Clean ISO 226 Bass EQ (Bands 0 and 1)
let bassEQ0 = 5.0 * Double(bassLinearWet) * K
let bassEQ1 = 1.0 * Double(bassLinearWet) * K

eqGains = [
    bassEQ0,
    bassEQ1,
    Double(scaledGains[2] * Float(K)),
    Double(scaledGains[3] * Float(K))
]

// 2. Multi-Harmonic Exciter capped at 30%
let lowBoostDB = 12.0 * Double(gainScale) * K
let lowLinear = pow(10.0, lowBoostDB / 20.0)
_lowExciterWet = min(0.30, Float((lowLinear - 1.0) * 0.15) * bassExciterWet)

// 3. Treble boost capped at 3.0 dB
let highBoostDB = 3.0 * Double(_trebleGainScale) * K
let highLinear = pow(10.0, highBoostDB / 20.0)
_highExciterWet = Float(highLinear - 1.0) * 0.05

// 4. Multi-Harmonic Saturation (2nd to 5th harmonics)
@inline(__always)
private func softClipLow(_ x: Float) -> Float {
    let c = max(-1.0, min(1.0, x * 1.2))
    let c2 = c * c
    let c3 = c2 * c
    let c4 = c3 * c
    let c5 = c4 * c
    return c - 0.25 * c2 - 0.15 * c3 + 0.10 * c4 - 0.05 * c5
}
```

**Step 2: Run unit tests**

Run: `xcodebuild test -project FineTune.xcodeproj -scheme FineTune -destination 'platform=macOS' -only-testing:FineTuneTests CODE_SIGNING_ALLOWED=NO`
Expected: PASS

**Step 3: Commit**

```bash
git add -f FineTune/Audio/Loudness/LoudnessCompensator.swift
git commit -m "feat: implement ISO 226 hybrid loudness engine with 30% exciter cap and +3 dB treble limit"
```
