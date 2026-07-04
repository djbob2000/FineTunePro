# Design: Orban-Style Progressive Ratio and Silence Gate Fallback

This design document explores the implementation of an Orban-style progressive compression ratio for the Automatic Gain Control (AGC) in `LoudnessEqualizer`, and compares the Silence Gate and Fallback settings with Orban's real-world defaults.

---

## 1. Parameter Analysis: Orban vs. Our Current Implementation

| Parameter | Our Current Default | Orban Optimod Defaults / Range | Parity Verification |
| :--- | :--- | :--- | :--- |
| **Silence Gate Threshold** | `-40.0 dB` | `-40 dB` (adjustable between `-44` and `-15` dB) | **Full Parity**. -40 dB is the standard recommended gate threshold in Orban units. |
| **Fallback Target (Idle Gain)** | `0.0 dB` (unity gain) | Target gain reduction matching AGC Drive (typically around `-10 dB` or `-12 dB`, adjustable offset) | **Difference**. Currently, when gated, the gain drifts to `0 dB` (fully uncompressed). When audio resumes, this causes a brief volume pop/overshoot because the 24 dB static drive is unattenuated. In Orban, the gain drifts to a parked **Idle Gain** (typically `-10 dB` or `-12 dB`) to prevent initial pops. |
| **Fallback Recovery Time** | `5.0 seconds` | Slow (typically 5 to 10 seconds) | **Full Parity**. 5.0 seconds is a standard, natural time to return the gain to idle without audible pumping. |

### Proposed Improvement for Fallback
We will change the silence gate fallback target from `0.0 dB` to a configurable parameter:
*   `silenceGateIdleGainDb: Float = -10.0` (matching the classic Orban "Idle Gain" parking level).
*   During a silence gate trigger, the gain will drift toward `silenceGateIdleGainDb` rather than `0.0 dB`.

---

## 2. Proposed Approaches for Progressive Ratio

In the AGC, the overshoot is defined as the signal level above the window boundary:
$$\text{overshootDb} = \text{levelDb} - (\text{targetDb} + \text{halfWindow})$$

When the signal is above the window, the compression ratio $R$ dictates how much the signal is allowed to exceed the window. To make it progressive, the ratio $R(\text{overshootDb})$ should increase as the overshoot gets deeper ("when it gets deeper, it gets steeper").

### Approach A: Exponential Slope Interpolation (Recommended)
We interpolate the compression slope $S = 1/R$ exponentially from the threshold:
$$S(\text{overshootDb}) = S_{\text{max}} + (S_{\text{min}} - S_{\text{max}}) \times e^{-k \times \text{overshootDb}}$$

where:
*   `minRatio` = 2.0 (so $S_{\text{min}} = 0.5$)
*   `maxRatio` = $\infty$ (so $S_{\text{max}} = 0.0$)
*   $k$ = 0.15 (rate of progression per dB of overshoot)

**Trade-offs:**
*   **Pros:** Mathematically elegant, continuous, and infinitely smooth (no hard corners). Fits natural/analog compression curves. Works perfectly with `maxRatio = .infinity` (since $S_{\text{max}} = 0$).
*   **Cons:** Slightly more floating-point operations (`exp` calculation), but fully negligible on modern CPUs.

### Approach B: Linear Slope Interpolation
We interpolate the slope $S = 1/R$ linearly over a transition range:
$$S(\text{overshootDb}) = S_{\text{min}} + (S_{\text{max}} - S_{\text{min}}) \times \text{clamp}\left(\frac{\text{overshootDb}}{\text{progressiveWidthDb}}, 0.0, 1.0\right)$$

**Trade-offs:**
*   **Pros:** Marginally cheaper computationally (no exponential function).
*   **Cons:** Has a hard corner at `progressiveWidthDb` which can cause subtle discontinuity artifacts.

---

## 3. Mathematical Integration into AGC core

The target gain `targetGainDb` will be calculated as:
$$\text{targetGainDb} = -\text{halfWindow} - \text{overshootDb} \times (1 - S(\text{overshootDb}))$$

If progressive ratio is disabled or $R = \infty$, $S = 0$, giving:
$$\text{targetGainDb} = -\text{halfWindow} - \text{overshootDb} = -\text{delta}$$
which is exactly backward-compatible with our current brickwall logic!

---

## 4. User Review & Feedback

### Open Questions for User
1. **Default Idle Gain**: Do you want the default `silenceGateIdleGainDb` to be exactly `-10.0` dB (Orban recommended) or should it track the drive value dynamically (e.g. `-driveDb / 2`)?
2. **Progressive Ratio defaults**: Are you comfortable with `minRatio = 2.0`, `maxRatio = .infinity`, and `progressiveRate = 0.15` as our default settings? (These will be internal under-the-hood defaults to keep the settings UI clean, as requested).
