// FineTune/Views/DesignSystem/VisualEffectBackground.swift
import SwiftUI
import AppKit

/// A frosted glass background using NSVisualEffectView, Apple's documented
/// translucent material primitive. The default `.popover` material renders
/// as proper light/dark glass and matches the platform Control Center and
/// Notification Center surfaces.
struct VisualEffectBackground: NSViewRepresentable {
    /// Apple's documented material for popover and menu-bar panels. Renders
    /// vibrant translucency in both appearances. The previous `.hudWindow`
    /// default was designed for dark floating overlays and washed out badly
    /// in light mode.
    var material: NSVisualEffectView.Material = .popover
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

// MARK: - Colors

extension Color {
    /// Popup background overlay - uses theme-aware color from DesignTokens
    /// Darker than before for more contrast with floating glass rows
    static var popupBackgroundOverlay: Color { DesignTokens.Colors.popupOverlay }
}

// MARK: - View Extensions

extension View {
    /// Applies the popup's translucent glass background. Adapts to light and
    /// dark via DesignTokens; the underlying NSVisualEffectView uses the
    /// `.popover` material so it tracks system appearance natively.
    /// On macOS 26.0+, uses SwiftUI's native Liquid Glass `.glassEffect()`.
    @ViewBuilder
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
    @ViewBuilder
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
    /// On older versions, falls back to `.menu` visual effect view background and overlay border.
    @ViewBuilder
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

    /// Applies the lifted-card background used by the EQ panel.
    /// Light reads as a white card on the popup glass; dark reads as a
    /// translucent surface on the dark glass. Replaces the prior recessed
    /// treatment which read as a heavy gray block on whiter light glass.
    func eqCardBackground() -> some View {
        modifier(LiftedCardBackgroundModifier())
    }
}

// MARK: - Lifted Card Background Modifier (EQ panel)

/// Lifted-card background used by the EQ panel.
/// Light: opaque-ish white card on the popup glass with a hairline edge
/// and a soft shadow that lifts the card off the surface. Dark: translucent
/// white on the dark glass with a slightly stronger hairline. Tokens come
/// from `DesignTokens.Colors.eqCardBackground` and `eqCardBorder`.
///
/// The shadow uses a literal `Color.black.opacity(0.06)`. Shadows are a
/// depth cue, not a chromatic surface, and remain readable in both modes
/// without an appearance-aware token.
struct LiftedCardBackgroundModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: DesignTokens.Dimensions.rowRadius)
                    .fill(DesignTokens.Colors.eqCardBackground)
            }
            .overlay {
                RoundedRectangle(cornerRadius: DesignTokens.Dimensions.rowRadius)
                    .strokeBorder(DesignTokens.Colors.eqCardBorder, lineWidth: 0.5)
            }
            .shadow(
                color: Color.black.opacity(0.06),
                radius: 1.5,
                x: 0,
                y: 0.5
            )
    }
}

// MARK: - Previews

#Preview("Dark Glass Popup Background") {
    VStack(spacing: 16) {
        Text("OUTPUT DEVICES")
            .sectionHeaderStyle()
        Text("Dark frosted glass background")
            .foregroundStyle(.primary)
    }
    .padding(DesignTokens.Spacing.lg)
    .frame(width: 300)
    .darkGlassBackground()
    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Dimensions.cornerRadius))
    .environment(\.colorScheme, .dark)
}

#Preview("EQ Card - Lifted") {
    VStack(spacing: 8) {
        Text("EQ Card - Lifted")
            .foregroundStyle(.secondary)
        HStack {
            ForEach(0..<5) { _ in
                Rectangle()
                    .fill(.secondary.opacity(0.3))
                    .frame(width: 20, height: 60)
            }
        }
    }
    .padding()
    .eqCardBackground()
    .padding()
    .darkGlassBackground()
}
