# Liquid Glass Design Implementation Plan

> **For Antigravity:** REQUIRED WORKFLOW: Use `.agent/workflows/execute-plan.md` to execute this plan in single-flow mode.

**Goal:** Update the app UI and interface so it has Liquid Glass design on newer macOS versions (macOS 26.0+) using SwiftUI's native `.glassEffect()` API.

**Architecture:** We will update `VisualEffectBackground.swift` to introduce new conditional modifiers `glassStyle()` and `menuGlassStyle()`, and update `darkGlassBackground()`. These will conditionally apply the new `.glassEffect()` modifier on macOS 26.0+ and fall back to the existing materials/borders on older macOS versions. We will then refactor all components that currently use manual regular/thin materials to use these new helpers, and update `GlassButtonStyleModifier` to support interactive glass.

**Tech Stack:** Swift, SwiftUI, AppKit

---

### Task 1: Implement custom conditional glass modifiers in VisualEffectBackground.swift

**Files:**
- Create: `FineTuneTests/LiquidGlassTests.swift`
- Modify: `FineTune/Views/DesignSystem/VisualEffectBackground.swift:41-59`

**Step 1: Write the failing test**

Create `FineTuneTests/LiquidGlassTests.swift`:
```swift
// FineTuneTests/LiquidGlassTests.swift
import Testing
import SwiftUI
@testable import FineTune

@Suite("Liquid Glass Design Extensions")
struct LiquidGlassTests {
    @Test("Custom glass view modifiers compile and return valid views")
    @MainActor
    func testGlassModifiers() {
        let text = Text("Test View")
        
        let darkGlass = text.darkGlassBackground()
        #expect(darkGlass != nil)
        
        let glassStyleView = text.glassStyle()
        #expect(glassStyleView != nil)
        
        let menuGlassView = text.menuGlassStyle()
        #expect(menuGlassView != nil)
    }
}
```

**Step 2: Run test to verify it fails**

Run: `rtk xcodebuild test -project FineTune.xcodeproj -scheme FineTune -configuration Debug -skip-testing:FineTuneUITests CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO`
Expected: Compilation failure because `glassStyle` and `menuGlassStyle` are not defined.

**Step 3: Write minimal implementation**

Modify `FineTune/Views/DesignSystem/VisualEffectBackground.swift` (around line 41) to implement the modifiers and update `darkGlassBackground()`:
```swift
extension View {
    /// Applies the popup's translucent glass background. Adapts to light and
    /// dark via DesignTokens; the underlying NSVisualEffectView uses the
    /// `.popover` material so it tracks system appearance natively.
    /// On macOS 26.0+, uses SwiftUI's native Liquid Glass `.glassEffect()`.
    func darkGlassBackground() -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: .rect(cornerRadius: DesignTokens.Dimensions.cornerRadius))
        } else {
            self
                .background(Color.popupBackgroundOverlay)
                .background(VisualEffectBackground(material: .popover, blendingMode: .behindWindow))
        }
    }

    /// Applies a glass effect style suitable for cards, panels, or HUDs.
    /// On macOS 26.0+, uses native Liquid Glass `.glassEffect()`.
    /// On older versions, falls back to a `.regularMaterial` fill background with optional border.
    func glassStyle(
        cornerRadius: CGFloat = DesignTokens.Dimensions.cornerRadius,
        borderColor: Color? = nil,
        borderWidth: CGFloat = 0.5
    ) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            self
                .background {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(.regularMaterial)
                }
                .overlay {
                    if let borderColor {
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .strokeBorder(borderColor, lineWidth: borderWidth)
                    }
                }
        }
    }

    /// Applies a glass effect style suitable for dropdown popover menus.
    /// On macOS 26.0+, uses native Liquid Glass `.glassEffect()`.
    /// On older versions, falls back to `.menu` visual effect view background with a border.
    func menuGlassStyle(
        cornerRadius: CGFloat = 8,
        borderColor: Color = DesignTokens.Colors.glassBorder
    ) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            self
                .background(
                    VisualEffectBackground(material: .menu, blendingMode: .behindWindow)
                        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                )
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .strokeBorder(borderColor, lineWidth: 0.5)
                }
        }
    }
}
```

**Step 4: Run test to verify it passes**

Run: `rtk xcodebuild test -project FineTune.xcodeproj -scheme FineTune -configuration Debug -skip-testing:FineTuneUITests CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO`
Expected: PASS

**Step 5: Commit**

```bash
git add FineTuneTests/LiquidGlassTests.swift FineTune/Views/DesignSystem/VisualEffectBackground.swift
git commit -m "feat: implement conditional Liquid Glass modifiers"
```

---

### Task 2: Apply glassStyle to HUD components

**Files:**
- Modify: `FineTune/Views/HUD/ClassicStyleHUD.swift:66-73`
- Modify: `FineTune/Views/HUD/TahoeStyleHUD.swift:113-120`
- Modify: `FineTune/Views/HUD/HUDWindowController.swift:522-529`

**Step 1: Write the failing test**

We verify compilation fails if we make syntax errors or misuse modifiers. No failing unit test is required for this refactor task, but we will run build verification.

**Step 2: Run test to verify clean build**

Ensure the project builds cleanly before making the change.

**Step 3: Write minimal implementation**

Modify `FineTune/Views/HUD/ClassicStyleHUD.swift`:
```swift
        .frame(width: Self.frameSize, height: Self.frameSize)
        .glassStyle(cornerRadius: Self.cornerRadius, borderColor: DesignTokens.Colors.hudBorder, borderWidth: 1)
```

Modify `FineTune/Views/HUD/TahoeStyleHUD.swift`:
```swift
        .frame(width: Self.frameWidth, height: Self.frameHeight)
        .glassStyle(cornerRadius: Self.cornerRadius, borderColor: DesignTokens.Colors.hudBorder, borderWidth: 1)
```

Modify `FineTune/Views/HUD/HUDWindowController.swift` (HUDDeviceCell):
```swift
        .frame(width: Self.frameWidth, height: Self.frameHeight)
        .glassStyle(cornerRadius: Self.cornerRadius, borderColor: DesignTokens.Colors.hudBorder, borderWidth: 1)
```

**Step 4: Run test to verify it passes**

Run: `rtk xcodebuild test -project FineTune.xcodeproj -scheme FineTune -configuration Debug -skip-testing:FineTuneUITests CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO`
Expected: PASS

**Step 5: Commit**

```bash
git add FineTune/Views/HUD/ClassicStyleHUD.swift FineTune/Views/HUD/TahoeStyleHUD.swift FineTune/Views/HUD/HUDWindowController.swift
git commit -m "style: apply conditional glassStyle to HUD components"
```

---

### Task 3: Apply glassStyle and menuGlassStyle to drop downs, pickers, and toggles

**Files:**
- Modify: `FineTune/Views/Components/ModeToggle.swift:21-28`
- Modify: `FineTune/Views/Components/DropdownMenu.swift:68-78`, `147-154`, `248-258`, `342-349`
- Modify: `FineTune/Views/Components/DevicePicker.swift:242-252`, `326-333`
- Modify: `FineTune/Views/Components/AutoEQPicker.swift:116-123`
- Modify: `FineTune/Views/Components/AUPluginPickerMenu.swift:155-162`

**Step 1: Write the failing test**

None needed. We will verify using compilation and test suite run.

**Step 2: Run test to verify clean build**

Ensure the project builds cleanly before making the change.

**Step 3: Write minimal implementation**

Modify `FineTune/Views/Components/ModeToggle.swift`:
```swift
        .glassStyle(cornerRadius: DesignTokens.Dimensions.buttonRadius, borderColor: DesignTokens.Colors.glassBorder, borderWidth: 0.5)
```

Modify `FineTune/Views/Components/DropdownMenu.swift`:
At lines 68-78 (triggerButton background) and lines 248-258:
```swift
        .glassStyle(
            cornerRadius: DesignTokens.Dimensions.buttonRadius,
            borderColor: isButtonHovered ? DesignTokens.Colors.glassRowBorderHover : DesignTokens.Colors.glassRowBorder,
            borderWidth: 0.5
        )
```
At lines 147-154 and lines 342-349:
```swift
        .menuGlassStyle(cornerRadius: cornerRadius)
```

Modify `FineTune/Views/Components/DevicePicker.swift`:
At lines 242-252 (fullTriggerButton background):
```swift
        .glassStyle(
            cornerRadius: DesignTokens.Dimensions.buttonRadius,
            borderColor: isButtonHovered ? DesignTokens.Colors.glassRowBorderHover : DesignTokens.Colors.glassRowBorder,
            borderWidth: 0.5
        )
```
At lines 326-333 (menu background):
```swift
        .menuGlassStyle(cornerRadius: cornerRadius)
```

Modify `FineTune/Views/Components/AutoEQPicker.swift` (at lines 116-123):
```swift
        .menuGlassStyle(cornerRadius: 8)
```

Modify `FineTune/Views/Components/AUPluginPickerMenu.swift` (at lines 155-162):
```swift
        .menuGlassStyle(cornerRadius: 8)
```

**Step 4: Run test to verify it passes**

Run: `rtk xcodebuild test -project FineTune.xcodeproj -scheme FineTune -configuration Debug -skip-testing:FineTuneUITests CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO`
Expected: PASS

**Step 5: Commit**

```bash
git add FineTune/Views/Components/ModeToggle.swift FineTune/Views/Components/DropdownMenu.swift FineTune/Views/Components/DevicePicker.swift FineTune/Views/Components/AutoEQPicker.swift FineTune/Views/Components/AUPluginPickerMenu.swift
git commit -m "style: apply conditional glassStyle and menuGlassStyle to picker and dropdown components"
```

---

### Task 4: Apply glassStyle to per-app/per-device components

**Files:**
- Modify: `FineTune/Views/EQPanelView.swift:258-265`, `349-356`
- Modify: `FineTune/Views/Rows/PairedDeviceRow.swift:55-62`
- Modify: `FineTune/Views/Rows/DeviceInspector/DeviceInspectorInfoGrid.swift:126-137`

**Step 1: Write the failing test**

None needed. We will verify using compilation and test suite run.

**Step 2: Run test to verify clean build**

Ensure the project builds cleanly before making the change.

**Step 3: Write minimal implementation**

Modify `FineTune/Views/EQPanelView.swift`:
At lines 258-265 and lines 349-356:
```swift
        .glassStyle(cornerRadius: DesignTokens.Dimensions.buttonRadius, borderColor: DesignTokens.Colors.menuBorderHover, borderWidth: 0.5)
```

Modify `FineTune/Views/Rows/PairedDeviceRow.swift` (at lines 55-62):
```swift
                .glassStyle(cornerRadius: DesignTokens.Dimensions.buttonRadius, borderColor: DesignTokens.Colors.glassRowBorder, borderWidth: 0.5)
```

Modify `FineTune/Views/Rows/DeviceInspector/DeviceInspectorInfoGrid.swift` (at lines 126-137):
Modify `pickerBackground` to apply the background glass:
```swift
    private var pickerBackground: some View {
        EmptyView()
    }
```
Wait! Since the picker background and border were split in `DeviceInspectorInfoGrid.swift`:
```swift
    private var pickerBackground: some View {
        RoundedRectangle(cornerRadius: DesignTokens.Dimensions.buttonRadius)
            .fill(.regularMaterial)
    }

    private var pickerBorder: some View {
        RoundedRectangle(cornerRadius: DesignTokens.Dimensions.buttonRadius)
            .strokeBorder(
                isHovered ? DesignTokens.Colors.glassRowBorderHover : DesignTokens.Colors.glassRowBorder,
                lineWidth: 0.5
            )
    }
```
We should refactor how they are applied. Let's find where they are referenced in `DeviceInspectorInfoGrid.swift`.
Wait! Let's search `DeviceInspectorInfoGrid.swift` for `pickerBackground` to see how it is used.
It is typically applied like `.background(pickerBackground).overlay(pickerBorder)`.
So we can replace that with:
```swift
    .glassStyle(
        cornerRadius: DesignTokens.Dimensions.buttonRadius,
        borderColor: isHovered ? DesignTokens.Colors.glassRowBorderHover : DesignTokens.Colors.glassRowBorder,
        borderWidth: 0.5
    )
```
Let's see: we can define:
```swift
    // Remove pickerBackground and pickerBorder, and replace their usage with .glassStyle(...)
```

**Step 4: Run test to verify it passes**

Run: `rtk xcodebuild test -project FineTune.xcodeproj -scheme FineTune -configuration Debug -skip-testing:FineTuneUITests CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO`
Expected: PASS

**Step 5: Commit**

```bash
git add FineTune/Views/EQPanelView.swift FineTune/Views/Rows/PairedDeviceRow.swift FineTune/Views/Rows/DeviceInspector/DeviceInspectorInfoGrid.swift
git commit -m "style: apply conditional glassStyle to EQ and device detail subcomponents"
```

---

### Task 5: Modify GlassButtonStyleModifier to use native interactive glass

**Files:**
- Modify: `FineTune/Views/DesignSystem/ViewModifiers.swift:84-110`

**Step 1: Write the failing test**

None needed. We will verify using compilation and test suite run.

**Step 2: Run test to verify clean build**

Ensure the project builds cleanly before making the change.

**Step 3: Write minimal implementation**

Modify `FineTune/Views/DesignSystem/ViewModifiers.swift`:
```swift
struct GlassButtonStyleModifier: ViewModifier {
    @State private var isHovered = false
    @State private var isPressed = false

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .padding(.horizontal, DesignTokens.Spacing.sm)
                .padding(.vertical, DesignTokens.Spacing.xs)
                .glassEffect(.regular.interactive(), in: .capsule)
                .scaleEffect(isPressed ? 0.97 : (isHovered ? 1.02 : 1.0))
                .onHover { hovering in
                    isHovered = hovering
                }
                .animation(DesignTokens.Animation.hover, value: isHovered)
                .animation(DesignTokens.Animation.quick, value: isPressed)
        } else {
            content
                .padding(.horizontal, DesignTokens.Spacing.sm)
                .padding(.vertical, DesignTokens.Spacing.xs)
                .background {
                    Capsule()
                        .fill(.ultraThinMaterial)
                }
                .overlay {
                    Capsule()
                        .strokeBorder(
                            isHovered ? DesignTokens.Colors.glassBorderHover : DesignTokens.Colors.glassBorder,
                            lineWidth: 0.5
                        )
                }
                .scaleEffect(isPressed ? 0.97 : (isHovered ? 1.02 : 1.0))
                .onHover { hovering in
                    isHovered = hovering
                }
                .animation(DesignTokens.Animation.hover, value: isHovered)
                .animation(DesignTokens.Animation.quick, value: isPressed)
        }
    }
}
```

**Step 4: Run test to verify it passes**

Run: `rtk xcodebuild test -project FineTune.xcodeproj -scheme FineTune -configuration Debug -skip-testing:FineTuneUITests CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO`
Expected: PASS

**Step 5: Commit**

```bash
git add FineTune/Views/DesignSystem/ViewModifiers.swift
git commit -m "style: update GlassButtonStyleModifier to use native interactive glass on macOS 26.0+"
```
