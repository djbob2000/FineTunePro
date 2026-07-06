// FineTune/Views/Components/VUMeter.swift
import SwiftUI

/// A vertical VU meter visualization for audio levels
/// Shows 8 bars that light up based on audio level with peak hold
struct VUMeter: View {
    let level: Float
    var isMuted: Bool = false

    @State private var peakLevel: Float = 0
    @State private var decayTask: Task<Void, Never>?

    private let barCount = DesignTokens.Dimensions.vuMeterBarCount

    var body: some View {
        VStack(spacing: 1) {
            ForEach((0..<barCount).reversed(), id: \.self) { index in
                VUMeterBar(
                    index: index,
                    level: level,
                    peakLevel: peakLevel,
                    barCount: barCount,
                    isMuted: isMuted
                )
            }
        }
        .frame(width: 10, height: DesignTokens.Dimensions.rowContentHeight - 4)
        .onChange(of: level) { _, newLevel in
            if newLevel > peakLevel {
                peakLevel = newLevel
                scheduleDecay()
            } else if peakLevel > newLevel && decayTask == nil {
                scheduleDecay()
            }
        }
        .onDisappear {
            stopDecay()
        }
    }

    /// Hold peak briefly, then decay at 30fps until peak reaches current level
    private func scheduleDecay() {
        stopDecay()
        decayTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(DesignTokens.Timing.vuMeterPeakHold))
            guard !Task.isCancelled else { return }

            // Decay ~24dB over 2.8 seconds (BBC PPM standard)
            // At 30fps: ~84 frames, decay rate ≈ 0.012 per frame
            let decayRate: Float = 0.012
            while !Task.isCancelled, peakLevel > level {
                try? await Task.sleep(for: .seconds(1.0 / 30.0))
                guard !Task.isCancelled else { return }
                withAnimation(DesignTokens.Animation.vuMeterLevel) {
                    peakLevel = max(level, peakLevel - decayRate)
                }
            }
        }
    }

    private func stopDecay() {
        decayTask?.cancel()
        decayTask = nil
    }
}

/// Individual bar in the VU meter
private struct VUMeterBar: View {
    let index: Int
    let level: Float
    let peakLevel: Float
    let barCount: Int
    var isMuted: Bool = false

    /// dB thresholds for 8 bars covering 40dB range
    /// Matches professional audio meter standards (logarithmic scale)
    private static let dbThresholds: [Float] = [-40, -30, -20, -14, -10, -6, -3, 0]

    /// Threshold for this bar (0-1) using dB scale
    /// Converts dB to linear: 10^(dB/20)
    private var threshold: Float {
        let db = Self.dbThresholds[min(index, Self.dbThresholds.count - 1)]
        return powf(10, db / 20)
    }

    /// Whether this bar should be lit based on current level
    private var isLit: Bool {
        level >= threshold
    }

    /// Whether this bar is the peak indicator
    private var isPeakIndicator: Bool {
        // Find which bar the peak level falls into using dB thresholds
        var peakBarIndex = 0
        for i in 0..<Self.dbThresholds.count {
            let thresh = powf(10, Self.dbThresholds[i] / 20)
            if peakLevel >= thresh {
                peakBarIndex = i
            }
        }
        return index == peakBarIndex && peakLevel > level
    }

    /// Color for this bar based on its position and mute state
    /// Split: 4 green (0-3), 2 yellow (4-5), 1 orange (6), 1 red (7)
    private var barColor: Color {
        // When muted, show gray to indicate "app is active but muted"
        if isMuted {
            return DesignTokens.Colors.vuMuted
        }
        if index < 4 {
            return DesignTokens.Colors.vuGreen
        } else if index < 6 {
            return DesignTokens.Colors.vuYellow
        } else if index < 7 {
            return DesignTokens.Colors.vuOrange
        } else {
            return DesignTokens.Colors.vuRed
        }
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 0.5)
            .fill(isLit || isPeakIndicator ? barColor : DesignTokens.Colors.vuUnlit)
            .animation(DesignTokens.Animation.vuMeterLevel, value: isLit)
    }
}

/// Horizontal output meter for the popup header.
/// Red segments show over-0 dBFS peaks; limiter state is shown by the LED.
struct OutputLevelMeter: View {
    let level: Float
    var channelLevels: [Float]? = nil
    let limiterIntensity: Float

    static let segmentCount = 81
    static let minDB: Float = -24
    static let maxDB: Float = 0
    static let firstRedSegmentIndex = 80
    static let holdSeconds = 0.05
    private static let holdDuration: Duration = .milliseconds(50)
    static let peakHoldFrames = 30
    static let peakDecayRate: Float = 0.03
    static let releaseCoefficient: Float = 0.22
    static let scaleExponent: Float = 1.8

    @State private var displayLevels: [Float] = []
    @State private var displayPeakLevels: [Float] = []
    @State private var peakHoldTimers: [Int] = []
    @State private var isLimiterHeld = false
    @State private var limiterHoldTask: Task<Void, Never>?

    static let labelDBs: [Float] = [-24, -18, -12, -9, -6, -3, 0]

    private var meterLevels: [Float] {
        channelLevels?.count == 2 ? channelLevels! : [level]
    }

    private var levelDB: Float {
        db(for: level)
    }

    private var limiterLEDOpacity: Double {
        isLimiterHeld ? 0.75 : 0.18
    }

    var body: some View {
        HStack(spacing: 8) {
            VStack(spacing: 2) {
                VStack(spacing: 3) {
                    ForEach(Array(meterLevels.enumerated()), id: \.offset) { index, channelLevel in
                        meterRow(
                            level: displayLevels.indices.contains(index) ? displayLevels[index] : channelLevel,
                            peakLevel: displayPeakLevels.indices.contains(index) ? displayPeakLevels[index] : channelLevel
                        )
                    }
                }
                .padding(.vertical, 2)

                GeometryReader { proxy in
                    ForEach(Self.labelDBs, id: \.self) { db in
                        Text(label(for: db))
                            .font(.system(size: 9, weight: .semibold, design: .rounded))
                            .foregroundStyle(DesignTokens.Colors.vuScaleLabel)
                            .position(x: xPosition(for: db, width: proxy.size.width), y: 5)
                    }
                }
                .frame(height: 10)
            }

            Circle()
                .fill(DesignTokens.Colors.vuRed.opacity(limiterLEDOpacity))
                .frame(width: 7, height: 7)
                .shadow(color: DesignTokens.Colors.vuRed.opacity(limiterLEDOpacity), radius: limiterLEDOpacity > 0.3 ? 3 : 0)
                .offset(y: -6)
                .animation(.linear(duration: 0.03), value: limiterIntensity)
        }
        .frame(width: 322)
        .accessibilityLabel("Output level")
        .onAppear {
            displayLevels = meterLevels
            displayPeakLevels = meterLevels
            peakHoldTimers = Array(repeating: 0, count: meterLevels.count)
            updateLimiterHold(previous: 0, current: limiterIntensity)
        }
        .onChange(of: meterLevels) { _, levels in
            updateDisplayedLevels(levels)
            updateLevelHold(levels)
        }
        .onChange(of: limiterIntensity) { previous, current in
            updateLimiterHold(previous: previous, current: current)
        }
        .onDisappear {
            limiterHoldTask?.cancel()
        }
    }

    private func meterRow(level: Float, peakLevel: Float) -> some View {
        let channelDB = db(for: level)
        let peakDB = db(for: peakLevel)
        let peakIndex = Self.peakSegmentIndex(forDB: peakDB)
        return HStack(spacing: 1.5) {
            ForEach(0..<Self.segmentCount, id: \.self) { index in
                let isLit = isLit(index, levelDB: channelDB)
                let isPeak = peakDB > channelDB && index == peakIndex
                RoundedRectangle(cornerRadius: 1)
                    .fill(color(for: index, isLit: isLit || isPeak))
                    .frame(maxWidth: .infinity)
                    .frame(height: 3)
            }
        }
        .animation(DesignTokens.Animation.vuMeterLevel, value: channelDB)
    }

    private func db(for level: Float) -> Float {
        guard level > 0 else { return Self.minDB }
        return min(Self.maxDB, max(Self.minDB, 20 * log10f(level)))
    }

    private func isLit(_ index: Int, levelDB: Float) -> Bool {
        levelDB >= Self.db(forSegment: index)
    }

    private func color(for index: Int, isLit: Bool) -> Color {
        guard isLit else { return DesignTokens.Colors.vuUnlit }

        if index >= Self.firstRedSegmentIndex {
            return DesignTokens.Colors.vuRed
        } else if Self.db(forSegment: index) >= -3 {
            return DesignTokens.Colors.vuOrange
        } else if Self.db(forSegment: index) >= -6 {
            return DesignTokens.Colors.vuYellow
        } else {
            return DesignTokens.Colors.vuGreen
        }
    }

    static func db(forSegment index: Int) -> Float {
        if index == firstRedSegmentIndex { return 0 }

        let fraction = Float(index) / Float(max(firstRedSegmentIndex, 1))
        // Power-based warping (exponent 1.8) maps index fraction to a non-linear dB scale.
        // This compresses the lower range (near -40 dB) and expands the upper range (near 0 dB).
        let warpedFraction = powf(fraction, 1.0 / scaleExponent)
        return minDB + (0 - minDB) * warpedFraction
    }

    private func xPosition(for db: Float, width: CGFloat) -> CGFloat {
        let fraction = CGFloat(Self.labelPositionFraction(for: db))
        return min(width - 6, max(6, width * fraction))
    }

    static func labelPositionFraction(for db: Float) -> Float {
        let linearFraction = (db - minDB) / (0 - minDB)
        return powf(max(0, min(1, linearFraction)), scaleExponent)
    }

    static func peakSegmentIndex(forDB db: Float) -> Int? {
        guard db >= minDB else { return nil }
        if db >= 0 { return firstRedSegmentIndex }

        let linearFraction = (db - minDB) / (0 - minDB)
        let warpedFraction = powf(linearFraction, scaleExponent)
        return min(firstRedSegmentIndex - 1, max(0, Int(floor(warpedFraction * Float(firstRedSegmentIndex)))))
    }

    static func shouldStartLimiterHold(previous: Float, current: Float) -> Bool {
        previous < 0.99 && current >= 0.99
    }

    static func displayedLevel(previous: Float, current: Float) -> Float {
        current >= previous ? current : previous + (current - previous) * releaseCoefficient
    }

    private func label(for db: Float) -> String {
        "\(Int(db))"
    }

    private func updateLevelHold(_ levels: [Float]) {
        var peaks = normalized(displayPeakLevels, count: levels.count, fallback: 0)
        var timers = normalized(peakHoldTimers, count: levels.count, fallback: 0)

        for index in levels.indices {
            let currentLevel = levels[index]
            if currentLevel > peaks[index] {
                peaks[index] = currentLevel
                timers[index] = Self.peakHoldFrames
            } else if timers[index] > 0 {
                timers[index] -= 1
            } else {
                peaks[index] = max(currentLevel, peaks[index] - Self.peakDecayRate)
            }
        }

        displayPeakLevels = peaks
        peakHoldTimers = timers
    }

    private func updateDisplayedLevels(_ levels: [Float]) {
        let previous = normalized(displayLevels, count: levels.count, fallback: 0)
        displayLevels = levels.indices.map { index in
            Self.displayedLevel(previous: previous[index], current: levels[index])
        }
    }

    private func normalized<T>(_ values: [T], count: Int, fallback: T) -> [T] {
        (0..<count).map { values.indices.contains($0) ? values[$0] : fallback }
    }

    private func updateLimiterHold(previous: Float, current: Float) {
        guard Self.shouldStartLimiterHold(previous: previous, current: current) else { return }
        isLimiterHeld = true
        limiterHoldTask?.cancel()
        limiterHoldTask = Task { @MainActor in
            try? await Task.sleep(for: Self.holdDuration)
            guard !Task.isCancelled else { return }
            withAnimation(.linear(duration: 0.05)) {
                isLimiterHeld = false
            }
        }
    }
}

// MARK: - Previews

#Preview("VU Meter - Vertical") {
    ComponentPreviewContainer {
        VStack(spacing: DesignTokens.Spacing.md) {
            HStack {
                Text("0%")
                    .font(.caption)
                VUMeter(level: 0)
            }

            HStack {
                Text("25%")
                    .font(.caption)
                VUMeter(level: 0.25)
            }

            HStack {
                Text("50%")
                    .font(.caption)
                VUMeter(level: 0.5)
            }

            HStack {
                Text("75%")
                    .font(.caption)
                VUMeter(level: 0.75)
            }

            HStack {
                Text("100%")
                    .font(.caption)
                VUMeter(level: 1.0)
            }
        }
    }
}

#Preview("Output Level Meter") {
    ComponentPreviewContainer {
        VStack(spacing: DesignTokens.Spacing.md) {
            OutputLevelMeter(level: 0.05, limiterIntensity: 0)
            OutputLevelMeter(level: 0.45, channelLevels: [0.35, 0.45], limiterIntensity: 0)
            OutputLevelMeter(level: 0.98, limiterIntensity: 0)
            OutputLevelMeter(level: 0.42, limiterIntensity: 1)
            OutputLevelMeter(level: 1.12, limiterIntensity: 0)
        }
        .padding()
    }
}

#Preview("VU Meter - Animated") {
    struct AnimatedPreview: View {
        @State private var level: Float = 0

        var body: some View {
            ComponentPreviewContainer {
                VStack(spacing: DesignTokens.Spacing.lg) {
                    VUMeter(level: level)

                    Slider(value: Binding(
                        get: { Double(level) },
                        set: { level = Float($0) }
                    ))
                }
            }
        }
    }
    return AnimatedPreview()
}
