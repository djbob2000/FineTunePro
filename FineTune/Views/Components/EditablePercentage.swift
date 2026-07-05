// FineTune/Views/Components/EditablePercentage.swift
import SwiftUI
import AppKit

/// A percentage display that can be clicked to edit the value directly
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
    @State private var componentFrame: CGRect = .zero
    @FocusState private var isFocused: Bool

    @Environment(\.keyboardTextEntry) private var textEntry
    @StateObject private var coordinator = EditStateCoordinator()

    /// Visual edit state: either mouse-based textfield editing or active keyboard buffer on this row.
    private var isVisuallyEditing: Bool {
        isEditing || keyboardBuffer != nil
    }

    /// Keyboard entry buffer strictly scoped to this row when focused.
    private var keyboardBuffer: String? {
        guard isRowFocused, let te = textEntry, let buf = te.buffer, !buf.isEmpty else { return nil }
        return buf
    }

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
                Text("%")
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

                if !useLogScale {
                    Text("%")
                        .font(DesignTokens.Typography.percentage)
                        .foregroundStyle(textColor)
                }
            } else {
                // Display mode: tappable percentage
                if useLogScale {
                    Text(decibels)
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
                    .onAppear {
                        componentFrame = geo.frame(in: .global)
                    }
                    .onChange(of: geo.frame(in: .global)) { _, newFrame in
                        componentFrame = newFrame
                    }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isVisuallyEditing ? DesignTokens.Colors.surfaceHover : (isHovered ? DesignTokens.Colors.surfaceHover.opacity(0.5) : Color.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(isVisuallyEditing ? DesignTokens.Colors.accentPrimary.opacity(0.3) : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture {
            if !isEditing {
                startEditing()
            }
        }
        .frame(minWidth: width, alignment: .trailing)
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
                cancel()
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
        stopEditing()
    }

    private func cancel() {
        stopEditing()
    }

    private func stopEditing() {
        isEditing = false
        isFocused = false
        coordinator.remove()
    }
}
