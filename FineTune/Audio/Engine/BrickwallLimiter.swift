// FineTune/Audio/Engine/BrickwallLimiter.swift
import Foundation

/// RT-safe look-ahead safety limiter for final app output.
///
/// This is a protection limiter, not a mastering compressor. It uses one shared
/// gain envelope for every channel so stereo/surround imaging is not skewed.
final class BrickwallLimiter {
    private static let maxWindowSize = 2048
    private static let maxChannelCount = 64

    /// Legacy safety ceiling, now enforced against the true-peak sidechain.
    static let ceiling: Float = 0.98

    private let delayBuffer: UnsafeMutablePointer<Float>
    private let peakBuffer: UnsafeMutablePointer<Float>
    private var truePeakSidechain = TruePeakSidechain()

    private var bufferIndex = 0
    private var currentGain: Float = 1.0
    private var lastSampleRate: Double = 0.0
    private var windowSize = 96
    private var releaseCoeff: Float = 0.005

    private let lookAheadMs = 2.0
    private let releaseTimeMs = 80.0

    init() {
        delayBuffer = UnsafeMutablePointer<Float>.allocate(capacity: Self.maxWindowSize * Self.maxChannelCount)
        peakBuffer = UnsafeMutablePointer<Float>.allocate(capacity: Self.maxWindowSize)

        delayBuffer.initialize(repeating: 0.0, count: Self.maxWindowSize * Self.maxChannelCount)
        peakBuffer.initialize(repeating: 0.0, count: Self.maxWindowSize)
    }

    deinit {
        delayBuffer.deallocate()
        peakBuffer.deallocate()
    }

    func reset() {
        delayBuffer.initialize(repeating: 0.0, count: Self.maxWindowSize * Self.maxChannelCount)
        peakBuffer.initialize(repeating: 0.0, count: Self.maxWindowSize)
        truePeakSidechain.reset()
        bufferIndex = 0
        currentGain = 1.0
    }

    /// Process interleaved samples in-place.
    /// Guaranteed RT-safe for channel counts up to `maxChannelCount`.
    @inline(__always)
    func process(_ buffer: UnsafeMutablePointer<Float>, sampleCount: Int, channelCount: Int, sampleRate: Double) {
        guard channelCount > 0, channelCount <= Self.maxChannelCount else { return }
        let frames = sampleCount / channelCount
        guard frames > 0 else { return }

        configureIfNeeded(sampleRate: sampleRate)

        for frame in 0..<frames {
            let inputBase = frame * channelCount
            let delayBase = bufferIndex * Self.maxChannelCount

            var samplePeak: Float = 0.0
            for channel in 0..<channelCount {
                let sample = buffer[inputBase + channel]
                delayBuffer[delayBase + channel] = sample
                samplePeak = max(samplePeak, abs(sample))
            }

            let truePeak = truePeakSidechain.processFrame(
                buffer: buffer,
                frameBase: inputBase,
                channelCount: channelCount
            )
            peakBuffer[bufferIndex] = max(samplePeak, truePeak)

            var windowMaxPeak: Float = 0.0
            for i in 0..<windowSize {
                windowMaxPeak = max(windowMaxPeak, peakBuffer[i])
            }

            let targetGain = windowMaxPeak > Self.ceiling ? Self.ceiling / windowMaxPeak : 1.0
            if targetGain < currentGain {
                currentGain = targetGain
            } else {
                currentGain += (targetGain - currentGain) * releaseCoeff
            }

            let outputIndex = (bufferIndex + 1) % windowSize
            let outputBase = outputIndex * Self.maxChannelCount
            for channel in 0..<channelCount {
                buffer[inputBase + channel] = delayBuffer[outputBase + channel] * currentGain
            }

            bufferIndex = (bufferIndex + 1) % windowSize
        }
    }

    /// Test hook for the true-peak sidechain. Production processing uses the same code path.
    static func estimateTruePeakForTesting(_ samples: [Float], channelCount: Int) -> Float {
        guard channelCount > 0, !samples.isEmpty else { return 0 }
        var detector = TruePeakSidechain()
        var mutable = samples
        var peak: Float = 0.0
        mutable.withUnsafeMutableBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return }
            let frames = ptr.count / channelCount
            for frame in 0..<frames {
                peak = max(peak, detector.processFrame(
                    buffer: base,
                    frameBase: frame * channelCount,
                    channelCount: channelCount
                ))
            }
        }
        return peak
    }

    @inline(__always)
    private func configureIfNeeded(sampleRate: Double) {
        guard sampleRate != lastSampleRate else { return }

        lastSampleRate = sampleRate
        let samples = Int((lookAheadMs / 1000.0) * sampleRate)
        windowSize = min(Self.maxWindowSize, max(1, samples))

        let releaseTimeSec = releaseTimeMs / 1000.0
        releaseCoeff = Float(1.0 - exp(-1.0 / (sampleRate * releaseTimeSec)))

        reset()
    }
}

private struct TruePeakSidechain {
    private static let tapCount = 12
    private static let maxChannelCount = 64

    // ITU-R BS.1770-5 Annex 2, order-48, 4-phase FIR interpolating coefficients.
    private static let phaseCoefficients: [[Float]] = [
        [
            0.0017089843750,
            0.0109863281250,
            -0.0196533203125,
            0.0332031250000,
            -0.0594482421875,
            0.1373291015625,
            0.9721679687500,
            -0.1022949218750,
            0.0476074218750,
            -0.0266113281250,
            0.0148925781250,
            -0.0083007812500,
        ],
        [
            -0.0291748046875,
            0.0292968750000,
            -0.0517578125000,
            0.0891113281250,
            -0.1665039062500,
            0.4650878906250,
            0.7797851562500,
            -0.2003173828125,
            0.1015625000000,
            -0.0582275390625,
            0.0330810546875,
            -0.0189208984375,
        ],
        [
            -0.0189208984375,
            0.0330810546875,
            -0.0582275390625,
            0.1015625000000,
            -0.2003173828125,
            0.7797851562500,
            0.4650878906250,
            -0.1665039062500,
            0.0891113281250,
            -0.0517578125000,
            0.0292968750000,
            -0.0291748046875,
        ],
        [
            -0.0083007812500,
            0.0148925781250,
            -0.0266113281250,
            0.0476074218750,
            -0.1022949218750,
            0.9721679687500,
            0.1373291015625,
            -0.0594482421875,
            0.0332031250000,
            -0.0196533203125,
            0.0109863281250,
            0.0017089843750,
        ],
    ]

    private var history: [Float]
    private var historyIndex = 0

    init() {
        history = [Float](repeating: 0.0, count: Self.tapCount * Self.maxChannelCount)
    }

    mutating func reset() {
        for i in history.indices {
            history[i] = 0.0
        }
        historyIndex = 0
    }

    @inline(__always)
    mutating func processFrame(buffer: UnsafePointer<Float>, frameBase: Int, channelCount: Int) -> Float {
        guard channelCount > 0, channelCount <= Self.maxChannelCount else { return 0 }

        let historyBase = historyIndex * Self.maxChannelCount
        for channel in 0..<channelCount {
            history[historyBase + channel] = buffer[frameBase + channel]
        }

        var peak: Float = 0.0
        for channel in 0..<channelCount {
            for phase in 0..<4 {
                var interpolated: Float = 0.0
                var readIndex = historyIndex
                for tap in 0..<Self.tapCount {
                    interpolated += history[readIndex * Self.maxChannelCount + channel] * Self.phaseCoefficients[phase][tap]
                    readIndex -= 1
                    if readIndex < 0 {
                        readIndex = Self.tapCount - 1
                    }
                }
                peak = max(peak, abs(interpolated))
            }
        }

        historyIndex += 1
        if historyIndex == Self.tapCount {
            historyIndex = 0
        }

        return peak
    }
}
