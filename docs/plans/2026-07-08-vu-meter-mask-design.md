# Design - VU Meter Masked Gradient Optimization

We are optimizing the SwiftUI rendering path of the `OutputLevelMeter` view to eliminate layout diffing overhead of 200+ separate view nodes per frame, while keeping the colors of the level meter bands anchored in place (no scaling on level changes).

## Proposed Architecture

1. **Geometry Layout**:
   - Total width: `322px`
   - Segment width: `2px`, gap: `1px`, count: `107`.
   - Grid layout masked on the GPU using a single `SegmentedMaskShape` mask.

2. **Static Gradient Alignment**:
   - The `LinearGradient` spans the entire `segmentsWidth` with custom color stops mapped to exact DB color transitions:
     - Green: `0.0` to `51 / 107`
     - Yellow: `51 / 107` to `87 / 107`
     - Orange: `87 / 107` to `106 / 107`
     - Red: `106 / 107` to `1.0`
   - A secondary horizontal mask bounds the gradient representation to the active width (`litWidth`) using a leading-aligned container.

3. **Peak Hold**:
   - Rendered as a single overlay line at the peak index, avoiding full-loop checks.

## Verification
- Unit tests in `DesignTokensTests.swift` verify the correct math layout.
