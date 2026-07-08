// FineTune/Views/Components/VUMeter.swift
import SwiftUI

/// A vertical peak/level meter visualization for audio levels.
/// Shows 8 bars that light up based on audio level with peak hold.
struct VUMeter: View {
    let level: Float
    var tick: Date = .now
    var isMuted: Bool = false

    @State private var peakLevel: Float = 0
    @State private var peakHoldTimer: Double = 0
    @State private var lastTickDate: Date? = nil

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
        .onAppear {
            lastTickDate = nil
            peakLevel = level
            peakHoldTimer = 0
        }
        .onDisappear {
            lastTickDate = nil
        }
        .onChange(of: tick) { _, newTick in
            let timeInterval = lastTickDate.map { newTick.timeIntervalSince($0) } ?? DesignTokens.Timing.vuMeterUpdateInterval
            lastTickDate = newTick

            if level > peakLevel {
                peakLevel = level
                peakHoldTimer = DesignTokens.Timing.vuMeterPeakHold // 0.5 seconds
            } else {
                if peakHoldTimer > 0 {
                    peakHoldTimer = max(0, peakHoldTimer - timeInterval)
                } else if peakLevel > level {
                    // Decay ~24dB over 2.8 seconds (BBC PPM standard)
                    // Linear decay rate: 1.0 / 2.8 per second
                    let decayPerSecond: Float = 1.0 / 2.8
                    let decayAmount = decayPerSecond * Float(timeInterval)
                    withAnimation(DesignTokens.Animation.vuMeterLevel) {
                        peakLevel = max(level, peakLevel - decayAmount)
                    }
                }
            }
        }
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

    /// Precomputed linear thresholds: 10^(dB/20)
    private static let linearThresholds: [Float] = dbThresholds.map { powf(10, $0 / 20) }

    /// Threshold for this bar (0-1) using dB scale
    private var threshold: Float {
        Self.linearThresholds[min(index, Self.linearThresholds.count - 1)]
    }

    /// Whether this bar should be lit based on current level
    private var isLit: Bool {
        level >= threshold
    }

    /// Whether this bar is the peak indicator
    private var isPeakIndicator: Bool {
        // Find which bar the peak level falls into using linear thresholds
        var peakBarIndex = 0
        for i in 0..<Self.linearThresholds.count {
            if peakLevel >= Self.linearThresholds[i] {
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
    let width: CGFloat
    let tick: Date

    static let minDB: Float = -30
    static let maxDB: Float = 0
    private static let holdDuration: Duration = .milliseconds(50)
    static let scaleExponent: Float = 1.8
    
    static let segmentWidth: CGFloat = 2.0
    static let segmentGap: CGFloat = 1.0

    @State private var displayLevels: [Float] = []
    @State private var displayPeakLevels: [Float] = []
    @State private var peakHoldTimers: [Double] = []
    @State private var lastTickDate: Date? = nil
    @State private var isLimiterHeld = false
    @State private var limiterHoldTask: Task<Void, Never>?
    @Environment(\.colorScheme) private var colorScheme

    static let labelDBs: [Float] = [-30, -20, -15, -10, -6, -3, 0]

    var segmentCount: Int {
        return Int((width + Self.segmentGap) / (Self.segmentWidth + Self.segmentGap))
    }

    var firstRedSegmentIndex: Int {
        segmentCount - 1
    }

    var segmentsWidth: CGFloat {
        CGFloat(CGFloat(segmentCount) * (Self.segmentWidth + Self.segmentGap) - Self.segmentGap)
    }

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
        VStack(spacing: 0) {
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
                    let x = xPosition(for: db)
                    Text(label(for: db))
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundStyle(DesignTokens.Colors.vuScaleLabel)
                        .position(x: x, y: 4.5)
                }
            }
            .frame(width: segmentsWidth, height: 9)
        }
        .frame(width: width)
        .accessibilityLabel("Output level")
        .onAppear {
            displayLevels = meterLevels
            displayPeakLevels = meterLevels
            peakHoldTimers = Array(repeating: 0.0, count: meterLevels.count)
            lastTickDate = nil
            updateLimiterHold(previous: 0, current: limiterIntensity)
        }
        .onChange(of: tick) { _, newTick in
            let timeInterval = lastTickDate.map { newTick.timeIntervalSince($0) } ?? DesignTokens.Timing.outputMeterUpdateInterval
            lastTickDate = newTick

            updateDisplayedLevels(meterLevels, timeInterval: timeInterval)
            updateLevelHold(meterLevels, timeInterval: timeInterval)
        }
        .onChange(of: limiterIntensity) { previous, current in
            updateLimiterHold(previous: previous, current: current)
        }
        .onDisappear {
            limiterHoldTask?.cancel()
            lastTickDate = nil
        }
    }

    private var meterGradient: LinearGradient {
        let count = CGFloat(segmentCount)
        let yellowStart = CGFloat(peakSegmentIndex(forDB: -10) ?? 0)
        let orangeStart = CGFloat(peakSegmentIndex(forDB: -3) ?? 0)
        let redStart = CGFloat(firstRedSegmentIndex)

        let stops: [Gradient.Stop] = [
            .init(color: DesignTokens.Colors.vuGreen, location: 0.0),
            .init(color: DesignTokens.Colors.vuGreen, location: yellowStart / count),
            .init(color: DesignTokens.Colors.vuYellow, location: yellowStart / count),
            .init(color: DesignTokens.Colors.vuYellow, location: orangeStart / count),
            .init(color: DesignTokens.Colors.vuOrange, location: orangeStart / count),
            .init(color: DesignTokens.Colors.vuOrange, location: redStart / count),
            .init(color: DesignTokens.Colors.vuRed, location: redStart / count),
            .init(color: DesignTokens.Colors.vuRed, location: 1.0)
        ]
        return LinearGradient(stops: stops, startPoint: .leading, endPoint: .trailing)
    }

    private func activeWidth(for levelDB: Float) -> CGFloat {
        guard levelDB > Self.minDB else { return 0 }
        let index = segmentIndex(forDB: levelDB)
        return CGFloat(index + 1) * (Self.segmentWidth + Self.segmentGap) - Self.segmentGap
    }

    private func meterRow(level: Float, peakLevel: Float) -> some View {
        let channelDB = db(for: level)
        let peakDB = db(for: peakLevel)
        let litWidth = activeWidth(for: channelDB)

        return ZStack(alignment: .leading) {
            // Unlit background
            DesignTokens.Colors.vuUnlit
                .frame(width: segmentsWidth, height: 3)

            // Lit gradient overlay (stays full width, clipped to litWidth)
            meterGradient
                .frame(width: segmentsWidth, height: 3)
                .frame(width: litWidth, alignment: .leading)
                .clipped()

            // Peak segment indicator overlay
            if let peakIdx = peakSegmentIndex(forDB: peakDB), peakDB > channelDB {
                let peakX = CGFloat(peakIdx) * (Self.segmentWidth + Self.segmentGap)
                color(for: peakIdx, isLit: true)
                    .frame(width: Self.segmentWidth, height: 3)
                    .offset(x: peakX)
            }
        }
        .frame(width: segmentsWidth)
        .mask(
            SegmentedMaskShape(
                segmentWidth: Self.segmentWidth,
                segmentGap: Self.segmentGap
            )
        )
        .animation(DesignTokens.Animation.vuMeterLevel, value: channelDB)
    }

    private func db(for level: Float) -> Float {
        guard level > 0 else { return Self.minDB }
        return min(Self.maxDB, max(Self.minDB, 20 * log10f(level)))
    }

    private func isLit(_ index: Int, levelDB: Float) -> Bool {
        levelDB >= db(forSegment: index)
    }

    private func color(for index: Int, isLit: Bool) -> Color {
        guard isLit else { return DesignTokens.Colors.vuUnlit }

        if index >= firstRedSegmentIndex {
            return DesignTokens.Colors.vuRed
        } else if db(forSegment: index) >= -3 {
            return DesignTokens.Colors.vuOrange
        } else if db(forSegment: index) >= -10 {
            return DesignTokens.Colors.vuYellow
        } else {
            return DesignTokens.Colors.vuGreen
        }
    }

    func db(forSegment index: Int) -> Float {
        if index == firstRedSegmentIndex { return 0 }

        let fraction = Float(index) / Float(max(firstRedSegmentIndex, 1))
        let warpedFraction = powf(fraction, 1.0 / Self.scaleExponent)
        return Self.minDB + (0 - Self.minDB) * warpedFraction
    }

    func segmentIndex(forDB db: Float) -> Int {
        guard let index = peakSegmentIndex(forDB: db) else { return 0 }
        return index
    }

    func xPosition(for db: Float) -> CGFloat {
        let index = segmentIndex(forDB: db)
        return CGFloat(index) * (Self.segmentWidth + Self.segmentGap) + (Self.segmentWidth / 2.0)
    }

    func peakSegmentIndex(forDB db: Float) -> Int? {
        guard db >= Self.minDB else { return nil }
        if db >= 0 { return firstRedSegmentIndex }

        let linearFraction = (db - Self.minDB) / (0 - Self.minDB)
        let warpedFraction = powf(linearFraction, Self.scaleExponent)
        return min(firstRedSegmentIndex - 1, max(0, Int(floor(warpedFraction * Float(firstRedSegmentIndex)))))
    }

    static func shouldStartLimiterHold(previous: Float, current: Float) -> Bool {
        previous < 0.99 && current >= 0.99
    }

    private func label(for db: Float) -> String {
        if db == 0 {
            return "0\u{200A}dB"
        } else {
            return "\(Int(db))"
        }
    }

    private func updateLevelHold(_ levels: [Float], timeInterval: Double) {
        var peaks = normalized(displayPeakLevels, count: levels.count, fallback: 0)
        var timers = normalized(peakHoldTimers, count: levels.count, fallback: 0.0)

        for index in levels.indices {
            let currentLevel = levels[index]
            if currentLevel > peaks[index] {
                peaks[index] = currentLevel
                timers[index] = 1.0 // Peak hold 1.0 seconds
            } else if timers[index] > 0 {
                timers[index] = max(0, timers[index] - timeInterval)
            } else {
                // Decay ~24dB over 2.8 seconds (BBC PPM standard)
                // Linear decay rate: 1.0 / 2.8 per second
                let decayPerSecond: Float = 1.0 / 2.8
                let decayAmount = decayPerSecond * Float(timeInterval)
                peaks[index] = max(currentLevel, peaks[index] - decayAmount)
            }
        }

        displayPeakLevels = peaks
        peakHoldTimers = timers
      }

    private func updateDisplayedLevels(_ levels: [Float], timeInterval: Double) {
        let previous = normalized(displayLevels, count: levels.count, fallback: 0)
        displayLevels = levels.indices.map { index in
            let cur = levels[index]
            let prev = previous[index]
            if cur >= prev {
                return cur
            } else {
                // Decay ~24dB over 2.8 seconds (BBC PPM standard)
                // Linear decay rate: 1.0 / 2.8 per second
                let decayPerSecond: Float = 1.0 / 2.8
                let decayAmount = decayPerSecond * Float(timeInterval)
                let smoothed = max(cur, prev - decayAmount)
                return smoothed < 0.001 ? 0 : smoothed
            }
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
            OutputLevelMeter(level: 0.05, limiterIntensity: 0, width: 322, tick: .now)
            OutputLevelMeter(level: 0.45, channelLevels: [0.35, 0.45], limiterIntensity: 0, width: 322, tick: .now)
            OutputLevelMeter(level: 0.98, limiterIntensity: 0, width: 322, tick: .now)
            OutputLevelMeter(level: 0.42, limiterIntensity: 1, width: 322, tick: .now)
            OutputLevelMeter(level: 1.12, limiterIntensity: 0, width: 322, tick: .now)
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

/// Custom Shape generating a segmented repeating path (width + gap) for masking gradients.
struct SegmentedMaskShape: Shape {
    let segmentWidth: CGFloat
    let segmentGap: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let step = segmentWidth + segmentGap
        let count = Int((rect.width + segmentGap) / step)
        for i in 0..<count {
            let x = CGFloat(i) * step
            path.addRect(CGRect(x: x, y: 0, width: segmentWidth, height: rect.height))
        }
        return path
    }
}
