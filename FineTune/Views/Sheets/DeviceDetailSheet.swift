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
    let loudnessMode: LoudnessMode
    let onLoudnessModeChange: (LoudnessMode) -> Void
    let loudnessGainScale: Double
    let onLoudnessGainScaleChange: (Double) -> Void
    let loudnessTrebleGainScale: Double
    let onLoudnessTrebleGainScaleChange: (Double) -> Void
    let loudnessBassExciterWet: Double
    let onLoudnessBassExciterWetChange: (Double) -> Void
    let loudnessBassLinearWet: Double
    let onLoudnessBassLinearWetChange: (Double) -> Void
    let getOutputAudioLevel: () -> Float
    let getLimiterIntensity: () -> Float
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
        loudnessMode: LoudnessMode,
        onLoudnessModeChange: @escaping (LoudnessMode) -> Void,
        loudnessGainScale: Double = 1.0,
        onLoudnessGainScaleChange: @escaping (Double) -> Void = { _ in },
        loudnessTrebleGainScale: Double = 1.0,
        onLoudnessTrebleGainScaleChange: @escaping (Double) -> Void = { _ in },
        loudnessBassExciterWet: Double = 0.20,
        onLoudnessBassExciterWetChange: @escaping (Double) -> Void = { _ in },
        loudnessBassLinearWet: Double = 1.0,
        onLoudnessBassLinearWetChange: @escaping (Double) -> Void = { _ in },
        getOutputAudioLevel: @escaping () -> Float = { 0.0 },
        getLimiterIntensity: @escaping () -> Float = { 0.0 },
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
        self.loudnessMode = loudnessMode
        self.onLoudnessModeChange = onLoudnessModeChange
        self.loudnessGainScale = loudnessGainScale
        self.onLoudnessGainScaleChange = onLoudnessGainScaleChange
        self.loudnessTrebleGainScale = loudnessTrebleGainScale
        self.onLoudnessTrebleGainScaleChange = onLoudnessTrebleGainScaleChange
        self.loudnessBassExciterWet = loudnessBassExciterWet
        self.onLoudnessBassExciterWetChange = onLoudnessBassExciterWetChange
        self.loudnessBassLinearWet = loudnessBassLinearWet
        self.onLoudnessBassLinearWetChange = onLoudnessBassLinearWetChange
        self.getOutputAudioLevel = getOutputAudioLevel
        self.getLimiterIntensity = getLimiterIntensity
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
        Text("Auto: \(Self.tierDisplayName(autoDetectedTier))")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(DesignTokens.Colors.textSecondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(DesignTokens.Colors.glassFillStrong)
            )
            .accessibilityLabel("Auto-detected volume control: \(Self.tierDisplayName(autoDetectedTier))")
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

            Text("Use FineTune's software volume")
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
        Text("Turn on only if the volume slider doesn't work. FineTune remembers this for each device.")
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
                    get: { isLoudnessCompensationEnabled },
                    set: { onLoudnessCompensationToggle($0) }
                ))
                .toggleStyle(.switch)
                .scaleEffect(0.8)
                .labelsHidden()
            }
            Text("Boost low frequencies at low volumes for this device.")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            if isLoudnessCompensationEnabled {
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

                            Text("\(maxPct)% volume (\(Int(maxDBVal)) dB)")
                                .font(DesignTokens.Typography.caption)
                                .foregroundStyle(DesignTokens.Colors.textSecondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if isMaxDBExpanded {
                        VStack(alignment: .leading, spacing: 6) {
                            VStack(alignment: .leading, spacing: 4) {
                                Slider(
                                    value: Binding(
                                        get: { maxDBVal },
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
                            .padding(.top, 4)

                            LoudnessDiagnosticsView(
                                getOutputAudioLevel: getOutputAudioLevel,
                                getLimiterIntensity: getLimiterIntensity
                            )
                            .padding(.top, 8)
                        }
                        .padding(.leading, 14)
                        .padding(.top, 2)
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    // MARK: - Helpers

    static func referenceLevelDisplayName(phon: Double, isExpanded: Bool) -> String {
        return "\(Int(phon)) dB"
    }

    static func tierDisplayName(_ tier: VolumeControlTier) -> String {
        switch tier {
        case .hardware: return "Hardware"
        case .ddc: return "DDC"
        case .software: return "Software"
        }
    }

    /// Hidden when auto-tier is already `.software` — no alternative backend to switch to.
    static func shouldShowToggle(autoTier: VolumeControlTier) -> Bool {
        autoTier != .software
    }
}

struct LoudnessDiagnosticsView: View {
    let getOutputAudioLevel: () -> Float
    let getLimiterIntensity: () -> Float
    
    @State private var outputLevel: Float = 0.0
    @State private var limiterIntensity: Float = 0.0
    
    // Slow peak tracker for the DB text display (PPM)
    @State private var displayPeakLevel: Float = 0.0
    @State private var peakHoldTimer: Int = 0
    
    @State private var timer: Timer? = nil
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Loudness Output Diagnostics")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(DesignTokens.Colors.textPrimary)
                Spacer()
                
                // LIMIT LED
                HStack(spacing: 4) {
                    Circle()
                        .fill(limiterIntensity > 0.05 ? Color.red : Color.gray.opacity(0.3))
                        .shadow(color: limiterIntensity > 0.05 ? Color.red.opacity(0.8) : Color.clear, radius: 4)
                        .frame(width: 8, height: 8)
                    
                    Text("LIMIT")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(limiterIntensity > 0.05 ? Color.red : DesignTokens.Colors.textTertiary)
                }
            }
            .padding(.bottom, 2)
            
            // Peak meter and scale
            VStack(alignment: .leading, spacing: 2) {
                GeometryReader { geo in
                    VStack(alignment: .leading, spacing: 0) {
                        // The Meter Bar
                        ZStack(alignment: .leading) {
                            // Background track
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(Color.black.opacity(0.4))
                                .frame(height: 8)
                            
                            // Colored Fill
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(meterColor(for: outputLevel))
                                .frame(width: geo.size.width * CGFloat(min(1.5, max(0.0, outputLevel)) / 1.5), height: 8)
                                .animation(.easeOut(duration: 0.05), value: outputLevel)
                        }
                        
                        // Ticks / Scale
                        ZStack {
                            let tickPositions: [(String, CGFloat)] = [
                                ("-20", 0.067),
                                ("-6", 0.334),
                                ("-3", 0.472),
                                ("0 dB", 0.667),
                                ("+3.5", 0.95)
                            ]
                            
                            ForEach(tickPositions, id: \.0) { label, pos in
                                Text(label)
                                    .font(.system(size: 8, design: .monospaced))
                                    .foregroundStyle(label == "0 dB" ? Color.yellow : (label == "+3.5" ? Color.red : DesignTokens.Colors.textTertiary))
                                    .position(x: geo.size.width * pos, y: 8)
                            }
                        }
                        .frame(height: 16)
                    }
                }
                .frame(height: 24)
            }
            
            // Smoothed Peak Text Readout
            HStack {
                Text("Max Peak:")
                    .font(.system(size: 9))
                    .foregroundStyle(DesignTokens.Colors.textTertiary)
                
                let dbVal = displayPeakLevel > 0.0 ? 20.0 * log10(displayPeakLevel) : -40.0
                Text(String(format: "%.1f dB", dbVal))
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(displayPeakLevel > 1.0 ? Color.red : (displayPeakLevel > 0.707 ? Color.yellow : Color.green))
                
                Spacer()
                
                if displayPeakLevel > 0.95 {
                    Text("ACTIVE LIMITING")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Color.red)
                }
            }
        }
        .padding(8)
        .background(Color.black.opacity(0.15))
        .cornerRadius(4)
        .onAppear {
            timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
                let currentLevel = getOutputAudioLevel()
                outputLevel = currentLevel
                limiterIntensity = getLimiterIntensity()
                
                // Peak Hold logic for display text
                if currentLevel > displayPeakLevel {
                    displayPeakLevel = currentLevel
                    peakHoldTimer = 30 // Hold for 1.5 seconds at 20fps
                } else {
                    if peakHoldTimer > 0 {
                        peakHoldTimer -= 1
                    } else {
                        // Slowly decay displayPeakLevel
                        displayPeakLevel = max(currentLevel, displayPeakLevel - 0.03)
                    }
                }
            }
        }
        .onDisappear {
            timer?.invalidate()
            timer = nil
        }
    }
    
    private func meterColor(for level: Float) -> Color {
        if level > 1.0 {
            return Color.red       // Over 0 dBFS (Clipping before limiter)
        } else if level > 0.707 {
            return Color.yellow    // Limiter zone / near clipping (-3 dB to 0 dB)
        } else {
            return Color.green     // Safe zone (< -3 dB)
        }
    }
}
