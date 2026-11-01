# Design: PopoverHost Screen Bounds Position Adjuster

## Goal

Ensure that all dropdown menus/popover panels spawned via `PopoverHost` on macOS adjust their position dynamically to stay within the screen's visible frame boundaries. This prevents menus from being cut off on the right or bottom edges of the screen.

## Proposed Changes

### [FineTune/Views/Components/PopoverHost.swift](file:///Users/air/develop/FineTuneFork/FineTune/Views/Components/PopoverHost.swift)

1. Introduce a helper method `positionPanel(from parentView: NSView)` in `PopoverHost.Coordinator` to centralize window positioning.
2. In `positionPanel`:
   - Compute the default target position (below the trigger button, left-aligned).
   - Resolve the active `NSScreen` for the parent window.
   - Clamp the horizontal coordinate (`x`) so that the window does not extend beyond `visibleFrame.maxX` or `visibleFrame.minX`.
   - If the window extends below `visibleFrame.minY` (the bottom of the usable screen area), attempt to flip it above the trigger button (`screenFrame.maxY + 4`). If it still doesn't fit above, clamp it to `visibleFrame.minY`.
3. Update `showPanel` to call `positionPanel(from: parentView)`.
4. Update `updateContent` to accept the `parentView` parameter and call `positionPanel(from: parentView)` after checking/resizing the panel.
5. Update `updateNSView` to pass `nsView` into `updateContent`.

## Verification Plan

### Manual Verification
1. Run FineTune and open the menu extra.
2. Position the menu window close to the right edge of the screen, or near the bottom edge.
3. Open an app's audio option picker (System Audio dropdown).
4. Verify that:
   - The dropdown shifts to the left to remain fully visible within the screen.
   - The dropdown opens above the trigger if it would otherwise extend off the bottom of the screen.
