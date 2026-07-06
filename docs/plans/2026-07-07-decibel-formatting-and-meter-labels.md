# Decibel Formatting and Volume Meter Theme-Awareness Implementation Plan

> **For Antigravity:** REQUIRED WORKFLOW: Use `.agent/workflows/execute-plan.md` to execute this plan in single-flow mode.

**Goal:** Append "dB" to log-scale volume and EQ slider values when displayed in decibels, and render volume meter scale labels in a theme-aware color (white on dark theme, black on light theme).

**Architecture:** Add a dynamic color token and update dimensions in `DesignTokens.swift`. Update `EditablePercentage` and `EQSliderView` formatting logic. Update `OutputLevelMeter` to use the new dynamic color token. Add unit tests for the color token resolution.

**Tech Stack:** Swift, SwiftUI, AppKit, Swift Testing

---

### Task 1: Update Design Tokens and Add Dynamic Color Tests

**Files:**
- Modify: `FineTune/Views/DesignSystem/DesignTokens.swift:260-266`
- Modify: `FineTune/Views/DesignSystem/DesignTokens.swift:440-442`
- Modify: `FineTuneTests/DesignTokensDynamicResolutionTests.swift:238-241`

**Step 1: Write the failing test**
Add a test in `FineTuneTests/DesignTokensDynamicResolutionTests.swift` to verify `vuScaleLabel` dynamic color resolves correctly.
Code to add:
```swift
    @Test("vuScaleLabel resolves correctly in light and dark")
    func vuScaleLabel() {
        expectColor(DesignTokens.Colors.vuScaleLabel,
                    equals: NSColor.black,
                    in: Self.aqua)
        expectColor(DesignTokens.Colors.vuScaleLabel,
                    equals: NSColor.white,
                    in: Self.darkAqua)
    }
```

**Step 2: Run test to verify it fails**
Run: `xcodebuild -scheme FineTune -destination 'platform=macOS' test -only-testing:FineTuneTests CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO`
Expected: FAIL (Compilation error: `vuScaleLabel` is not defined on `DesignTokens.Colors`)

**Step 3: Write minimal implementation**
Modify `FineTune/Views/DesignSystem/DesignTokens.swift` to add `vuScaleLabel` and update `decibelsWidth` from `44` to `56`.

In `DesignTokens.swift` (Colors):
```swift
        /// Volume meter scale labels color. White in dark mode, black in light mode.
        static let vuScaleLabel = dynamicColor(
            name: "vuScaleLabel",
            light: NSColor.black,
            dark: NSColor.white
        )
```

In `DesignTokens.swift` (Dimensions):
```swift
        /// Decibels text width (fixed to prevent layout shift)
        static let decibelsWidth: CGFloat = 56
```

**Step 4: Run test to verify it passes**
Run: `xcodebuild -scheme FineTune -destination 'platform=macOS' test -only-testing:FineTuneTests CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO`
Expected: PASS

**Step 5: Commit**
```bash
git add FineTune/Views/DesignSystem/DesignTokens.swift FineTuneTests/DesignTokensDynamicResolutionTests.swift
git commit -m "feat: add vuScaleLabel dynamic color and increase decibelsWidth"
```

---

### Task 2: Format Volume Decibel Sliders with "dB" Suffix

**Files:**
- Modify: `FineTune/Views/Components/EditablePercentage.swift:58-62`
- Modify: `FineTune/Views/Components/EditablePercentage.swift:64-105`
- Modify: `FineTune/Views/Components/EditablePercentage.swift:188-201`

**Step 1: Write implementation changes**
Update text views to show "dB" next to the numbers in both edit and display modes when `useLogScale` is true. Clean "dB" case-insensitively in `parseValue`.

In `EditablePercentage.swift` lines 64-105:
```swift
            if let buffer = keyboardBuffer {
                Text(buffer)
                    .font(DesignTokens.Typography.percentage)
                    .foregroundStyle(textColor)
                    .multilineTextAlignment(.trailing)
                Text(useLogScale ? "dB" : "%")
                    .font(DesignTokens.Typography.percentage)
                    .foregroundStyle(textColor)
            } else if isEditing {
                TextField("", text: $inputText)
                    .textFieldStyle(.plain)
                    .font(DesignTokens.Typography.percentage)
                    .foregroundStyle(textColor)
                    .multilineTextAlignment(.trailing)
                    .focused($isFocused)
                    .onSubmit { commit() }
                    .onExitCommand { cancel() }
                    .fixedSize()

                Text(useLogScale ? "dB" : "%")
                    .font(DesignTokens.Typography.percentage)
                    .foregroundStyle(textColor)
            } else {
                if useLogScale {
                    Text("\(decibels)dB")
                        .font(DesignTokens.Typography.percentage)
                        .foregroundStyle(isHovered ? DesignTokens.Colors.textPrimary : textColor)
                } else {
                    Text("\(percentage)%")
                        .font(DesignTokens.Typography.percentage)
                        .foregroundStyle(isHovered ? DesignTokens.Colors.textPrimary : textColor)
                }
            }
```

In `parseValue`:
```swift
    private func parseValue(_ input: String) -> Double? {
        let cleaned = input
            .replacing("%", with: "")
            .replacingOccurrences(of: "dB", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespaces)

        guard let newValue = Float(cleaned) else { return nil }

        if useLogScale {
            let gain = VolumeMapping.decibelsToGain(Double(newValue))
            return VolumeMapping.gainToSlider(gain, logScale: useLogScale)
        } else {
            return Double(newValue) / 100
        }
    }
```

**Step 2: Run tests to verify no regressions**
Run: `xcodebuild -scheme FineTune -destination 'platform=macOS' test -only-testing:FineTuneTests CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO`
Expected: PASS

**Step 3: Commit**
```bash
git add FineTune/Views/Components/EditablePercentage.swift
git commit -m "feat: append dB suffix and strip it case-insensitively in EditablePercentage"
```

---

### Task 3: Format EQ Gain Values with "dB" Suffix

**Files:**
- Modify: `FineTune/Views/EQSliderView.swift:30-33`

**Step 1: Write implementation changes**
Update `formatGainValue` in `EQSliderView.swift` to append "dB".

```swift
    private func formatGainValue(_ gain: Float) -> String {
        return String(format: "%+.1f", gain) + "dB"
    }
```

**Step 2: Run tests to verify no regressions**
Run: `xcodebuild -scheme FineTune -destination 'platform=macOS' test -only-testing:FineTuneTests CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO`
Expected: PASS

**Step 3: Commit**
```bash
git add FineTune/Views/EQSliderView.swift
git commit -m "feat: format EQ gain values with dB suffix in EQSliderView"
```

---

### Task 4: Make Volume Meter Scale Labels Theme-Aware

**Files:**
- Modify: `FineTune/Views/Components/VUMeter.swift:180-188`

**Step 1: Write implementation changes**
In `VUMeter.swift`, update `OutputLevelMeter` to use `vuScaleLabel` instead of `vuYellow`:

```swift
                GeometryReader { proxy in
                    ForEach(Self.labelDBs, id: \.self) { db in
                        Text(label(for: db))
                            .font(.system(size: 9, weight: .semibold, design: .rounded))
                            .foregroundStyle(DesignTokens.Colors.vuScaleLabel)
                            .position(x: xPosition(for: db, width: proxy.size.width), y: 5)
                    }
                }
```

**Step 2: Run tests to verify all tests pass**
Run: `xcodebuild -scheme FineTune -destination 'platform=macOS' test -only-testing:FineTuneTests CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO`
Expected: PASS

**Step 3: Commit**
```bash
git add FineTune/Views/Components/VUMeter.swift
git commit -m "feat: make OutputLevelMeter scale labels use theme-aware vuScaleLabel color"
```
