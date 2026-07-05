# Horizontal VU Meter Implementation Plan

> **For Antigravity:** REQUIRED WORKFLOW: Use `.agent/workflows/execute-plan.md` to execute this plan in single-flow mode.

**Goal:** Redesign the horizontal VU meter in the Audio settings tab to display real-time RMS levels with 35 fixed-width segments (6 points wide, 2 points spacing, total width 278 points) and a floating peak-hold indicator dot that decays smoothly after a 0.5-second hold.

**Architecture:**
1. Update `CompactHorizontalVUMeter` instantiation in `AudioTab.swift` to accept `outputRmsLevel` (for the bar graph fill) and `outputLevel` (for peak detection).
2. Set the frame width of the meter in `AudioTab.swift` to match the sliders (using the existing `280` or setting `.frame(width: 280)`).
3. Redesign `CompactHorizontalVUMeter` in `AudioTab.swift` to render `35` fixed-size rectangles.
4. Implement the `@State heldPeakLevel` tracking, hold timer, and smooth decay logic inside `CompactHorizontalVUMeter` using SwiftUI tasks.

---

### Task 1: Bind RMS and Peak Levels to CompactHorizontalVUMeter in AudioTab.swift

**Files:**
- Modify: [AudioTab.swift](file:///Users/air/develop/FineTuneFork/FineTune/Views/Settings/Tabs/AudioTab.swift)

**Step 1: Update calling site in AudioTab.swift**
Pass `outputRmsLevel` as the primary level (RMS) and `outputLevel` as the peak level. Remove the old `.frame(width: 120)` constraint and set it to `.frame(width: 280)` to align with the sliders.
```swift
CompactHorizontalVUMeter(level: outputRmsLevel, peakLevel: outputLevel)
    .frame(width: 280)
```

**Step 2: Commit**
```bash
rtk git add FineTune/Views/Settings/Tabs/AudioTab.swift
rtk git commit -m "ui: update VUMeter call to pass both RMS and Peak levels and set full width"
```

---

### Task 2: Redesign CompactHorizontalVUMeter View in AudioTab.swift

**Files:**
- Modify: [AudioTab.swift](file:///Users/air/develop/FineTuneFork/FineTune/Views/Settings/Tabs/AudioTab.swift)

**Step 1: Implement 35-bar layout, dbThresholds, and peak-hold logic**
Replace the old `CompactHorizontalVUMeter` struct definition:
- Set `barCount = 35`.
- Define `dbThresholds` for 35 bars covering `-45` to `0` dBFS.
- Implement `heldPeakLevel` and `decayTask` states.
- Implement the peak-hold scheduling and decay logic inside `CompactHorizontalVUMeter`.
- Define the color coding: Green, Yellow, Orange, Red (no cyan target zone or bottom bracket).
- Render `RoundedRectangle(cornerRadius: 1)` with a fixed width of `6` and height of `8`, arranged horizontally in `HStack(spacing: 2)`.

```swift
struct CompactHorizontalVUMeter: View {
    let level: Float
    let peakLevel: Float

    @State private var heldPeakLevel: Float = 0.0
    @State private var decayTask: Task<Void, Never>? = nil

    private let barCount = 35
    private static let dbThresholds: [Float] = [
        -45.0, -43.0, -41.0, -39.0, -37.0, -35.0, -33.0, -31.0, -29.0, -27.0,
        -25.0, -23.0, -21.0, -19.0, -17.0, -15.0, -13.0, -12.0, -11.0, -10.0,
        -9.0, -8.0, -7.0, -6.0, -5.0, -4.5, -4.0, -3.5, -3.0, -2.5,
        -2.0, -1.5, -1.0, -0.5, 0.0
    ]

    private func isLit(index: Int) -> Bool {
        let db = Self.dbThresholds[min(index, Self.dbThresholds.count - 1)]
        let threshold = powf(10.0, db / 20.0)
        return level >= threshold
    }

    private func isPeakIndicator(index: Int) -> Bool {
        var peakBarIndex = -1
        for i in 0..<Self.dbThresholds.count {
            let thresh = powf(10.0, Self.dbThresholds[i] / 20.0)
            if heldPeakLevel >= thresh {
                peakBarIndex = i
            }
        }
        return index == peakBarIndex && heldPeakLevel > level
    }

    private func barColor(index: Int) -> Color {
        if index < 20 {
            return DesignTokens.Colors.vuGreen
        } else if index < 28 {
            return DesignTokens.Colors.vuYellow
        } else if index < 30 {
            return DesignTokens.Colors.vuOrange
        } else {
            return DesignTokens.Colors.vuRed
        }
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<barCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(isLit(index: index) || isPeakIndicator(index: index) ? barColor(index: index) : DesignTokens.Colors.vuUnlit)
                    .frame(width: 6, height: 8)
            }
        }
        .onChange(of: peakLevel) { _, newPeak in
            if newPeak >= heldPeakLevel {
                heldPeakLevel = newPeak
                scheduleDecay()
            } else if heldPeakLevel > newPeak && decayTask == nil {
                scheduleDecay()
            }
        }
        .onDisappear {
            stopDecay()
        }
    }

    private func scheduleDecay() {
        stopDecay()
        decayTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(DesignTokens.Timing.vuMeterPeakHold))
            guard !Task.isCancelled else { return }

            let decayRate: Float = 0.015
            while !Task.isCancelled, heldPeakLevel > level {
                try? await Task.sleep(for: .seconds(1.0 / 30.0))
                guard !Task.isCancelled else { return }
                withAnimation(DesignTokens.Animation.vuMeterLevel) {
                    heldPeakLevel = max(level, heldPeakLevel - decayRate)
                }
            }
        }
    }

    private func stopDecay() {
        decayTask?.cancel()
        decayTask = nil
    }
}
```

**Step 2: Commit**
```bash
rtk git add FineTune/Views/Settings/Tabs/AudioTab.swift
rtk git commit -m "ui: implement 35-bar horizontal VU meter with Peak-Hold & smooth decay"
```

---

### Task 3: Verify & Test for Regressions

**Step 1: Run unit tests**
Run:
```bash
rtk xcodebuild -scheme FineTune -destination 'platform=macOS' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO -only-testing:FineTuneTests test
```
Expected: All 45 test groups pass successfully.
