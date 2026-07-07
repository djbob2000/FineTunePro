// FineTune/Views/Sheets/DeviceDetailSheet.swift
import SwiftUI
import os

@MainActor
struct DeviceDetailSheet: View {
    let device: AudioDevice
    let transportType: TransportType
    let autoDetectedTier: VolumeControlTier
    let currentOverride: VolumeControlTier?
    let onOverrideChange: (VolumeControlTier?) -> Void
    let isLoudnessCompensationEnabled: Bool
    let onLoudnessCompensationToggle: (Bool) -> Void
    let loudnessReferencePhon: Double
    let onLoudnessReferencePhonChange: (Double) -> Void
    let loudnessMaxDB: Double
    let onLoudnessMaxDBChange: (Double) -> Void
    let loudnessGainScale: Double
    let onLoudnessGainScaleChange: (Double) -> Void
    let loudnessTrebleGainScale: Double
    let onLoudnessTrebleGainScaleChange: (Double) -> Void
    let loudnessBassLinearWet: Double
    let onLoudnessBassLinearWetChange: (Double) -> Void
    let onDismiss: () -> Void

    @State private var viewModel: DeviceInspectorViewModel
    @State private var showAdvanced: Bool = false
    @State private var isMaxDBExpanded: Bool = false

    private static let logger = Logger(subsystem: "com.finetuneapp.FineTune", category: "DeviceDetailSheet")

    init(
        device: AudioDevice,
        transportType: TransportType,
        autoDetectedTier: VolumeControlTier,
        currentOverride: VolumeControlTier?,
        onOverrideChange: @escaping (VolumeControlTier?) -> Void,
        isLoudnessCompensationEnabled: Bool,
        onLoudnessCompensationToggle: @escaping (Bool) -> Void,
        loudnessReferencePhon: Double,
        onLoudnessReferencePhonChange: @escaping (Double) -> Void,
        loudnessMaxDB: Double = -30.0,
        onLoudnessMaxDBChange: @escaping (Double) -> Void = { _ in },
        loudnessGainScale: Double = 1.0,
        onLoudnessGainScaleChange: @escaping (Double) -> Void = { _ in },
        loudnessTrebleGainScale: Double = 1.0,
        onLoudnessTrebleGainScaleChange: @escaping (Double) -> Void = { _ in },
        loudnessBassLinearWet: Double = 1.0,
        onLoudnessBassLinearWetChange: @escaping (Double) -> Void = { _ in },
        onDismiss: @escaping () -> Void
    ) {
        self.device = device
        self.transportType = transportType
        self.autoDetectedTier = autoDetectedTier
        self.currentOverride = currentOverride
        self.onOverrideChange = onOverrideChange
        self.isLoudnessCompensationEnabled = isLoudnessCompensationEnabled
        self.onLoudnessCompensationToggle = onLoudnessCompensationToggle
        self.loudnessReferencePhon = loudnessReferencePhon
        self.onLoudnessReferencePhonChange = onLoudnessReferencePhonChange
        self.loudnessMaxDB = loudnessMaxDB
        self.onLoudnessMaxDBChange = onLoudnessMaxDBChange
        self.loudnessGainScale = loudnessGainScale
        self.onLoudnessGainScaleChange = onLoudnessGainScaleChange
        self.loudnessTrebleGainScale = loudnessTrebleGainScale
        self.onLoudnessTrebleGainScaleChange = onLoudnessTrebleGainScaleChange
        self.loudnessBassLinearWet = loudnessBassLinearWet
        self.onLoudnessBassLinearWetChange = onLoudnessBassLinearWetChange
        self.onDismiss = onDismiss
        self._viewModel = State(
            initialValue: DeviceInspectorViewModel(
                deviceID: device.id,
                uid: device.uid,
                transportType: transportType
            )
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            DeviceInspectorInfoGrid(
                info: viewModel.info,
                onSampleRateSelected: { rate in
                    viewModel.selectSampleRate(rate)
                }
            )

            if let error = viewModel.sampleRateError {
                errorBanner(error)
            }

            if let hogLine = DeviceInspectorInfo.formatHogModeOwner(
                viewModel.info.hogModeOwner,
                processName: viewModel.hogModeOwnerName
            ) {
                separator
                hogModeRow(hogLine)
            }

            if Self.shouldShowToggle(autoTier: autoDetectedTier) {
                separator
                softwareToggle
                calloutText
            }

            separator
            loudnessCompensationToggle
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background {
            RoundedRectangle(cornerRadius: 10)
                .fill(DesignTokens.Colors.recessedBackground)
        }
        .padding(.horizontal, 2)
        .padding(.top, DesignTokens.Spacing.xs)
        .padding(.bottom, DesignTokens.Spacing.xs)
        .onAppear { viewModel.start() }
        .onDisappear { viewModel.stop() }
    }

    // MARK: - Auto badge

    private var autoBadge: some View {
        Text(L10n.format("Auto: %@", Self.tierDisplayName(autoDetectedTier)))
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(DesignTokens.Colors.textSecondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(DesignTokens.Colors.glassFillStrong)
            )
            .accessibilityLabel(L10n.format("Auto-detected volume control: %@", Self.tierDisplayName(autoDetectedTier)))
    }

    // MARK: - Separator

    private var separator: some View {
        Rectangle()
            .fill(DesignTokens.Colors.separator)
            .frame(height: 0.5)
    }

    // MARK: - Hog mode row

    private func hogModeRow(_ text: String) -> some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            Image(systemName: "lock.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(DesignTokens.Colors.textSecondary)
            Text(text)
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Colors.textSecondary)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
    }

    // MARK: - Error banner

    private func errorBanner(_ text: String) -> some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(DesignTokens.Colors.mutedIndicator)
            Text(text)
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Colors.textSecondary)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
    }

    // MARK: - Software Toggle

    @ViewBuilder
    private var softwareToggle: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            autoBadge

            Text(L10n.string("Use FineTune's software volume"))
                .font(DesignTokens.Typography.pickerText)
                .foregroundStyle(DesignTokens.Colors.textPrimary)

            Spacer(minLength: DesignTokens.Spacing.sm)

            Toggle("", isOn: useSoftwareBinding)
                .toggleStyle(.switch)
                .scaleEffect(0.8)
                .labelsHidden()
        }
    }

    /// OFF writes `nil` (clears the pin, re-runs auto-detect); ON pins `.software`.
    private var useSoftwareBinding: Binding<Bool> {
        Binding(
            get: { currentOverride == .some(.software) },
            set: { newValue in
                Self.logger.debug("Toggle flipped: uid=\(device.uid, privacy: .public) useSoftware=\(newValue, privacy: .public)")
                onOverrideChange(newValue ? .some(.software) : nil)
            }
        )
    }

    // MARK: - Callout

    private var calloutText: some View {
        Text(L10n.string("Turn on only if the volume slider doesn't work. FineTune remembers this for each device."))
            .font(DesignTokens.Typography.caption)
            .foregroundStyle(DesignTokens.Colors.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }


    // MARK: - Loudness Compensation Toggle

    @ViewBuilder
    private var loudnessCompensationToggle: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: DesignTokens.Spacing.xs) {
                Text("Loudness Compensation")
                    .font(DesignTokens.Typography.pickerText)
                    .foregroundStyle(DesignTokens.Colors.textPrimary)

                Spacer(minLength: DesignTokens.Spacing.sm)

                Toggle("", isOn: Binding(
                    get: { transportType == .builtIn ? false : isLoudnessCompensationEnabled },
                    set: { onLoudnessCompensationToggle($0) }
                ))
                .toggleStyle(.switch)
                .scaleEffect(0.8)
                .labelsHidden()
                .disabled(transportType == .builtIn)
            }
            Text(transportType == .builtIn
                 ? "Loudness compensation is unavailable for built-in speakers as macOS already applies custom DSP tuning to them."
                 : "Boost low frequencies at low volumes for this device.")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            if isLoudnessCompensationEnabled && transportType != .builtIn {
                VStack(alignment: .leading, spacing: 4) {
                    let maxDBVal = (loudnessMaxDB >= -40.0 && loudnessMaxDB <= -20.0) ? loudnessMaxDB : -30.0
                    let maxPct = Int((1.0 + maxDBVal / 40.0) * 100)

                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            isMaxDBExpanded.toggle()
                        }
                    } label: {
                        HStack {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(DesignTokens.Colors.textSecondary)
                                .rotationEffect(.degrees(isMaxDBExpanded ? 90 : 0))

                            Text("Low Vol Ref")
                                .font(DesignTokens.Typography.caption)
                                .foregroundStyle(DesignTokens.Colors.textSecondary)

                            Spacer()

                            Text("\(maxPct)% volume (\(Int(maxDBVal))\u{200A}dB)")
                                .font(DesignTokens.Typography.caption)
                                .foregroundStyle(DesignTokens.Colors.textSecondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if isMaxDBExpanded {
                        Slider(
                            value: Binding(
                                get: { loudnessMaxDB },
                                set: { onLoudnessMaxDBChange($0) }
                            ),
                            in: -40...(-20),
                            step: 1
                        )
                        .controlSize(.mini)

                        Text("Volume level where max compensation is reached.")
                            .font(DesignTokens.Typography.caption)
                            .foregroundStyle(DesignTokens.Colors.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.leading, 14)
                .padding(.top, 2)
            }
        }
    }

    // MARK: - Helpers

    static func referenceLevelDisplayName(phon: Double, isExpanded: Bool) -> String {
        return "\(Int(phon))\u{200A}dB"
    }

    static func tierDisplayName(_ tier: VolumeControlTier) -> String {
        switch tier {
        case .hardware: return L10n.string("Hardware")
        case .ddc: return "DDC"
        case .software: return L10n.string("Software")
        }
    }

    /// Hidden when auto-tier is already `.software` — no alternative backend to switch to.
    static func shouldShowToggle(autoTier: VolumeControlTier) -> Bool {
        autoTier != .software
    }
}
