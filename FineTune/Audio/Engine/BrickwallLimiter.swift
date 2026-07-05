// FineTune/Audio/Engine/BrickwallLimiter.swift
import Foundation

/// RT-safe look-ahead safety limiter for final app output.
///
/// This is a protection limiter, not a mastering compressor. It uses one shared
/// gain envelope for every channel so stereo/surround imaging is not skewed.
final class BrickwallLimiter {
    private static let maxWindowSize = 2048
    private static let maxChannelCount = 64

    /// Legacy safety ceiling for the final output guard.
    static let ceiling: Float = 0.98

    private let delayBuffer: UnsafeMutablePointer<Float>
    private let peakBuffer: UnsafeMutablePointer<Float>

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

            peakBuffer[bufferIndex] = samplePeak

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
