# VU Meter Masked Gradient Implementation Plan

> **For Antigravity:** REQUIRED WORKFLOW: Use `.agent/workflows/execute-plan.md` to execute this plan in single-flow mode.

**Goal:** Fix the VU meter gradient scaling issue by drawing a static-width gradient masked by the active level width.

**Architecture:** Instead of framing the `LinearGradient` to the active level width (which squashes the gradient), we keep the gradient at the full `segmentsWidth` and mask it with a leading-aligned rectangle of the active level width.

**Tech Stack:** SwiftUI

---

### Task 1: Update VUMeter.swift

**Files:**
- Modify: `FineTune/Views/Components/VUMeter.swift`

**Step 1: Write the updated implementation in VUMeter.swift**

Update `meterRow(level:peakLevel:)` to mask `meterGradient` using a leading-aligned rectangle of width `litWidth`:

```swift
    private func meterRow(level: Float, peakLevel: Float) -> some View {
        let channelDB = db(for: level)
        let peakDB = db(for: peakLevel)
        let litWidth = activeWidth(for: channelDB)

        return ZStack(alignment: .leading) {
            // Unlit background
            DesignTokens.Colors.vuUnlit
                .frame(width: segmentsWidth, height: 3)

            // Lit gradient overlay (stays full width, masked to litWidth)
            meterGradient
                .frame(width: segmentsWidth, height: 3)
                .mask(
                    HStack(spacing: 0) {
                        Rectangle()
                            .frame(width: litWidth)
                        Spacer(minLength: 0)
                    }
                    .frame(width: segmentsWidth, alignment: .leading)
                )

            // Peak segment indicator overlay
            if let peakIdx = peakSegmentIndex(forDB: peakDB), peakDB > channelDB {
                let peakX = CGFloat(peakIdx) * (Self.segmentWidth + Self.segmentGap)
                color(for: peakIdx, isLit: true)
                    .frame(width: Self.segmentWidth, height: 3)
                    .offset(x: peakX)
            }
        }
        .frame(width: segmentsWidth)
        .mask(
            SegmentedMaskShape(
                segmentWidth: Self.segmentWidth,
                segmentGap: Self.segmentGap
            )
        )
        .animation(DesignTokens.Animation.vuMeterLevel, value: channelDB)
    }
```

**Step 2: Verify tests compile and pass**

Run: `xcodebuild test -scheme FineTune -destination 'platform=macOS' -only-testing FineTuneTests CODE_SIGNING_ALLOWED=NO`
Expected: PASS

**Step 3: Commit**

```bash
git add FineTune/Views/Components/VUMeter.swift
git commit -m "perf: mask gradient in VUMeter to prevent color scaling"
```
