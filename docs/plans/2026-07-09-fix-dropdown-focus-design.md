# Design Doc - Fix Dropdown Menu Focus Resignation

**Status:** Approved

## Problem
In commit `6fbd40d`, a refactor introduced an optimization to pause VU meter polling when the main popup window is not visible. This was implemented by listening to `NSWindow.didResignKeyNotification` and setting `isPopupVisible = false`. 

However, since all custom pickers (e.g. `EQPresetPicker`, `DevicePicker`, `AUPluginPickerMenu`) are implemented as borderless child panels (`PopoverHost`), they must become key (`makeKeyAndOrderFront`) to receive keyboard focus. This focus transition triggers a `didResignKeyNotification` on the parent window, causing the main layout to switch away from `TimelineView` (which destroys the SwiftUI hierarchy, deallocates `PopoverHost`, and instantly closes the dropdown).

## Proposed Solution

### 1. Fix Window Focus Resignation Loop
In [MenuBarPopupView.swift](file:///Users/air/develop/FineTuneFork/FineTune/Views/MenuBarPopupView.swift), modify the `didResignKeyNotification` handler to check if the new key window is a child of the parent window. If a child window of the parent has focus, we ignore the key resignation event.

```swift
.onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { notification in
    guard let window = notification.object as? NSWindow,
          String(describing: type(of: window)).contains("FluidMenuBarExtra")
    else { return }
    
    // Ignore key resignation if focus is transferred to a child window (dropdown/popover)
    if let keyWindow = NSApp.keyWindow, window.childWindows?.contains(keyWindow) == true {
        return
    }
    if window.childWindows?.contains(where: { $0.isKeyWindow }) == true {
        return
    }
    
    isPopupVisible = false
    popupVisibility.isVisible = false
    hasKeyboardEngaged = false
    selectedRow = nil
}
```

### 2. Fix Dropdown Opacity and Lack of Frosted Glass
In [VisualEffectBackground.swift](file:///Users/air/develop/FineTuneFork/FineTune/Views/DesignSystem/VisualEffectBackground.swift), update `menuGlassStyle` to use the native `VisualEffectBackground(material: .popover, blendingMode: .behindWindow)` for macOS < 26.0, instead of just a 6% opacity color fill without blur.

```swift
    func menuGlassStyle(
        cornerRadius: CGFloat = 8,
        borderColor: Color = DesignTokens.Colors.glassBorder
    ) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.clear, in: .rect(cornerRadius: cornerRadius))
        } else {
            self
                .background(Color.primary.opacity(0.06))
                .background(VisualEffectBackground(material: .popover, blendingMode: .behindWindow))
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .strokeBorder(borderColor, lineWidth: 0.5)
                }
        }
    }
```

## Impact / Risks
Extremely low risk. Uses Apple's standard AppKit and SwiftUI APIs to align popover translucency and focus management with macOS platform standards.

