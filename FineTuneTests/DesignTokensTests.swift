// FineTuneTests/DesignTokensTests.swift
// Tests that DesignTokens values are valid and consistent.
// No rendering — just value validation.

import Testing
import SwiftUI
@testable import FineTune

// MARK: - Spacing

@Suite("DesignTokens — Spacing scale")
struct DesignTokensSpacingTests {

    @Test("All spacing values are positive")
    func allPositive() {
        #expect(DesignTokens.Spacing.xxs > 0)
        #expect(DesignTokens.Spacing.xs > 0)
        #expect(DesignTokens.Spacing.sm > 0)
        #expect(DesignTokens.Spacing.md > 0)
        #expect(DesignTokens.Spacing.lg > 0)
        #expect(DesignTokens.Spacing.xl > 0)
        #expect(DesignTokens.Spacing.xxl > 0)
    }

    @Test("Spacing scale is strictly increasing")
    func strictlyIncreasing() {
        let scale: [CGFloat] = [
            DesignTokens.Spacing.xxs,
            DesignTokens.Spacing.xs,
            DesignTokens.Spacing.sm,
            DesignTokens.Spacing.md,
            DesignTokens.Spacing.lg,
            DesignTokens.Spacing.xl,
            DesignTokens.Spacing.xxl,
        ]
        for i in 1..<scale.count {
            #expect(scale[i] > scale[i - 1],
                    "Spacing[\(i)] (\(scale[i])) should be > spacing[\(i-1)] (\(scale[i-1]))")
        }
    }

    @Test("Spacing values are reasonable (2-24pt range)")
    func reasonableRange() {
        #expect(DesignTokens.Spacing.xxs == 2)
        #expect(DesignTokens.Spacing.xs == 4)
        #expect(DesignTokens.Spacing.sm == 8)
        #expect(DesignTokens.Spacing.md == 12)
        #expect(DesignTokens.Spacing.lg == 16)
        #expect(DesignTokens.Spacing.xl == 20)
        #expect(DesignTokens.Spacing.xxl == 24)
    }
}

// MARK: - Dimensions

@Suite("DesignTokens — Dimensions")
struct DesignTokensDimensionTests {

    @Test("Popup width is positive and reasonable")
    func popupWidth() {
        #expect(DesignTokens.Dimensions.popupWidth > 300)
        #expect(DesignTokens.Dimensions.popupWidth < 1000)
    }

    @Test("contentWidth is popupWidth minus double padding")
    func contentWidthFormula() {
        let expected = DesignTokens.Dimensions.popupWidth - (DesignTokens.Dimensions.contentPadding * 2)
        #expect(DesignTokens.Dimensions.contentWidth == expected)
    }

    @Test("Corner radii are positive")
    func cornerRadiiPositive() {
        #expect(DesignTokens.Dimensions.cornerRadius > 0)
        #expect(DesignTokens.Dimensions.rowRadius > 0)
        #expect(DesignTokens.Dimensions.buttonRadius > 0)
    }

    @Test("Slider dimensions are positive")
    func sliderDimensionsPositive() {
        #expect(DesignTokens.Dimensions.sliderTrackHeight > 0)
        #expect(DesignTokens.Dimensions.sliderThumbWidth > 0)
        #expect(DesignTokens.Dimensions.sliderThumbHeight > 0)
        #expect(DesignTokens.Dimensions.sliderThumbSize > 0)
    }

    @Test("Icon sizes are positive")
    func iconSizes() {
        #expect(DesignTokens.Dimensions.iconSize > 0)
        #expect(DesignTokens.Dimensions.iconSizeSmall > 0)
        #expect(DesignTokens.Dimensions.iconSizeSmall < DesignTokens.Dimensions.iconSize)
    }

    @Test("VU meter has 8 bars")
    func vuMeterBarCount() {
        #expect(DesignTokens.Dimensions.vuMeterBarCount == 8)
    }

    @Test("Output level meter red threshold is at 0 dB")
    func outputLevelMeterRedThresholds() {
        #expect(OutputLevelMeter.segmentCount == 81)
        #expect(OutputLevelMeter.maxDB == 0)
        #expect(OutputLevelMeter.labelDBs == [-24, -18, -12, -9, -6, -3, 0])
        #expect(abs(OutputLevelMeter.db(forSegment: OutputLevelMeter.firstRedSegmentIndex)) < 0.001)
        #expect(OutputLevelMeter.labelPositionFraction(for: 0) == 1)
        #expect(abs(OutputLevelMeter.labelPositionFraction(for: -24) - 0.0) < 0.001)
        #expect(abs(OutputLevelMeter.labelPositionFraction(for: -18) - 0.0825) < 0.001)
        #expect(abs(OutputLevelMeter.labelPositionFraction(for: -12) - 0.2872) < 0.001)
        #expect(abs(OutputLevelMeter.labelPositionFraction(for: -9) - 0.4285) < 0.001)
        #expect(abs(OutputLevelMeter.labelPositionFraction(for: -6) - 0.5960) < 0.001)
        #expect(abs(OutputLevelMeter.labelPositionFraction(for: -3) - 0.7863) < 0.001)
        #expect(OutputLevelMeter.peakHoldFrames == 30)
        #expect(OutputLevelMeter.peakDecayRate == 0.03)
        #expect(OutputLevelMeter.releaseCoefficient > 0)
        #expect(OutputLevelMeter.releaseCoefficient < 1)
        #expect(OutputLevelMeter.displayedLevel(previous: 0.2, current: 0.8) == 0.8)
        let decayed = OutputLevelMeter.displayedLevel(previous: 0.8, current: 0.2)
        #expect(decayed < 0.8)
        #expect(decayed > 0.2)
        #expect(OutputLevelMeter.peakSegmentIndex(forDB: -3) == 62)
        #expect(OutputLevelMeter.shouldStartLimiterHold(previous: 0.95, current: 0.90) == false)
        #expect(OutputLevelMeter.shouldStartLimiterHold(previous: 0.95, current: 1.0))
    }

    @Test("Min touch target is at least 16pt (Apple HIG minimum)")
    func minTouchTarget() {
        #expect(DesignTokens.Dimensions.minTouchTarget >= 16)
    }
}

// MARK: - Timing

@Suite("DesignTokens — Timing constants")
struct DesignTokensTimingTests {

    @Test("VU meter update interval is ~30fps")
    func vuMeterInterval() {
        let interval = DesignTokens.Timing.vuMeterUpdateInterval
        #expect(abs(interval - 1.0 / 30.0) < 0.001)
    }

    @Test("Output meter update interval is ~15fps")
    func outputMeterInterval() {
        let interval = DesignTokens.Timing.outputMeterUpdateInterval
        #expect(abs(interval - 1.0 / 15.0) < 0.001)
    }

    @Test("VU meter peak hold is positive")
    func vuMeterPeakHold() {
        #expect(DesignTokens.Timing.vuMeterPeakHold > 0)
    }
}
