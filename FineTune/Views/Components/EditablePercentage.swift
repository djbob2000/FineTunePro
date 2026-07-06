// FineTune/Views/Components/EditablePercentage.swift
import SwiftUI
import AppKit

/// A percentage/dB display that can be clicked to edit the value directly
/// Features a refined edit state with subtle visual feedback
struct EditablePercentage: View {
    @Binding var sliderValue: Double
    let range: ClosedRange<Double>
    let useLogScale: Bool
    var onCommit: ((Double) -> Void)? = nil
    /// True when this row is the popup's keyboard selection (gates keyboard entry).
    var isRowFocused: Bool = false

    init(
        sliderValue: Binding<Double>,
        range: ClosedRange<Double> = 0...1,
        useLogScale: Bool = false,
        onCommit: ((Double) -> Void)? = nil,
        isRowFocused: Bool = false
    ) {
        self._sliderValue = sliderValue
        self.range = range
        self.useLogScale = useLogScale
        self.onCommit = onCommit
        self.isRowFocused = isRowFocused
    }

    @State private var isEditing = false
    @State private var inputText = ""
    @State private var isHovered = false
    @FocusState private var isFocused: Bool
    @State private var coordinator = ClickOutsideCoordinator()
    @State private var componentFrame: CGRect = .zero
    @Environment(PopupTextEntryCoordinator.self) private var textEntry: PopupTextEntryCoordinator?

    /// Popup-owned keyboard entry, so first responder never leaves the nav anchor.
    private var keyboardBuffer: String? {
        isRowFocused ? textEntry?.buffer : nil
    }
    private var isVisuallyEditing: Bool { isEditing || keyboardBuffer != nil }

    /// Text color adapts to state: accent when editing, secondary otherwise
    private var textColor: Color {
        isVisuallyEditing ? DesignTokens.Colors.accentPrimary : DesignTokens.Colors.textSecondary
    }

    private var width: CGFloat {
        if useLogScale {
            DesignTokens.Dimensions.decibelsWidth
        } else {
            DesignTokens.Dimensions.percentageWidth
        }
    }

    private var percentage: Int { Int(round(sliderValue * 100)) }

    private var decibels: String {
        let gain = VolumeMapping.sliderToGain(sliderValue, logScale: useLogScale)
        let db = VolumeMapping.gainToDecibels(gain)
        return String(format: "%0.1f", db)
    }

    var body: some View {
        HStack(spacing: 0) {
            if let buffer = keyboardBuffer {
                // No TextField for keyboard entry, so first responder stays on the nav anchor.
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
                    .fixedSize()  // Size to content

                Text(useLogScale ? "dB" : "%")
                    .font(DesignTokens.Typography.percentage)
                    .foregroundStyle(textColor)
            } else {
                // Display mode: tappable percentage
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
        }
        .padding(.horizontal, isVisuallyEditing ? 6 : 4)
        .padding(.vertical, isVisuallyEditing ? 2 : 1)
        .background {
            GeometryReader { geo in
                Color.clear
                    .preference(key: FramePreferenceKey.self, value: geo.frame(in: .global))
            }
        }
        .onPreferenceChange(FramePreferenceKey.self) { frame in
            updateScreenFrame(from: frame)
        }
        .background {
            if isVisuallyEditing {
                // Subtle pill background when editing
                RoundedRectangle(cornerRadius: 4)
                    .fill(DesignTokens.Colors.accentPrimary.opacity(0.12))
                    .overlay {
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(DesignTokens.Colors.accentPrimary.opacity(0.4), lineWidth: 1)
                    }
            } else if isHovered {
                // Subtle hover background to indicate clickability
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.primary.opacity(0.08))
            }
        }
        .frame(minWidth: width, alignment: .trailing)
        .contentShape(Rectangle())
        .onTapGesture { if !isEditing { startEditing() } }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(L10n.string("Edit volume percentage"))
        .onHover { hovering in
            isHovered = hovering
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
        .onChange(of: isEditing) { _, editing in
            if !editing {
                coordinator.removeMonitors()
                // Mouse edit released first responder; ask the popup to refocus the nav anchor.
                textEntry?.navRestoreNonce += 1
            }
        }
        .onChange(of: textEntry?.commitNonce) { _, _ in
            guard isRowFocused, let te = textEntry, let buffer = te.buffer else { return }
            if let value = parseValue(buffer), range.contains(value) {
                sliderValue = value
                onCommit?(value)
            }
            te.buffer = nil
        }
        .animation(.easeOut(duration: 0.15), value: isEditing)
        .animation(.easeOut(duration: 0.1), value: isHovered)
    }

    private func startEditing() {
        // A mouse edit supersedes any in-progress keyboard entry on this row.
        textEntry?.buffer = nil
        if useLogScale {
            inputText = decibels
        } else {
            inputText = "\(percentage)"
        }
        isEditing = true

        // Install monitors via coordinator (handles local, global, and app deactivation)
        coordinator.install(
            excludingFrame: componentFrame,
            onClickOutside: { [self] in
                commit()
            }
        )

        // Delay focus to next runloop to ensure TextField is rendered
        Task { @MainActor in
            isFocused = true
        }
    }

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

    private func commit() {
        if let value = parseValue(inputText), range.contains(value) {
            sliderValue = value
            onCommit?(value)
        }
        isEditing = false
    }

    private func cancel() {
        isEditing = false
    }

    private func updateScreenFrame(from globalFrame: CGRect) {
        componentFrame = screenFrame(from: globalFrame)
    }
}

// MARK: - Preference Key for Frame Tracking

private struct FramePreferenceKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

// MARK: - Keyboard Entry Coordinator

/// Shared between the menu-bar popup and its rows. The popup owns keyboard percentage
/// entry — first responder never leaves the nav anchor — and writes `buffer`; the
/// keyboard-focused row's field renders it and commits when `commitNonce` changes. A
/// field raises `navRestoreNonce` when a *mouse* edit ends so the popup refocuses the anchor.
@MainActor
@Observable
final class PopupTextEntryCoordinator {
    var buffer: String? = nil
    var commitNonce: Int = 0
    var navRestoreNonce: Int = 0
}
