import AudioToolbox
import Foundation

/// RT-safe look-ahead safety limiter for final app output.
///
/// This is a protection limiter, not a mastering compressor. It uses one shared
/// gain envelope for every channel so stereo/surround imaging is not skewed.
final class BrickwallLimiter {
    private static let maxWindowSize = 2048
    private static let maxChannelCount = 64

    /// Legacy safety ceiling for the final output guard.
    static let ceiling: Float = 1.0

    private let delayBuffer: UnsafeMutablePointer<Float>
    private let peakBuffer: UnsafeMutablePointer<Float>
    private let dequeIndices: UnsafeMutablePointer<Int>

    // Pre-allocated buffers for channel mapping to avoid real-time heap allocations
    private let channelPointers: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>
    private let channelStrides: UnsafeMutablePointer<Int>
    private let channelOffsets: UnsafeMutablePointer<Int>

    private var bufferIndex = 0
    private var currentGain: Float = 1.0
    private var lastSampleRate: Double = 0.0
    private var windowSize = 96
    private var releaseCoeff: Float = 0.005

    private var dequeHead = 0
    private var dequeTail = 0
    private var frameCounter = 0

    private static let maxDequeCapacity = 4096
    private static let dequeMask = maxDequeCapacity - 1

    private let lookAheadMs = 2.0
    private let releaseTimeMs = 80.0

    init() {
        delayBuffer = UnsafeMutablePointer<Float>.allocate(capacity: Self.maxWindowSize * Self.maxChannelCount)
        peakBuffer = UnsafeMutablePointer<Float>.allocate(capacity: Self.maxWindowSize)
        dequeIndices = UnsafeMutablePointer<Int>.allocate(capacity: Self.maxDequeCapacity)

        channelPointers = UnsafeMutablePointer<UnsafeMutablePointer<Float>?>.allocate(capacity: Self.maxChannelCount)
        channelStrides = UnsafeMutablePointer<Int>.allocate(capacity: Self.maxChannelCount)
        channelOffsets = UnsafeMutablePointer<Int>.allocate(capacity: Self.maxChannelCount)

        delayBuffer.initialize(repeating: 0.0, count: Self.maxWindowSize * Self.maxChannelCount)
        peakBuffer.initialize(repeating: 0.0, count: Self.maxWindowSize)
        dequeIndices.initialize(repeating: 0, count: Self.maxDequeCapacity)

        channelPointers.initialize(repeating: nil, count: Self.maxChannelCount)
        channelStrides.initialize(repeating: 0, count: Self.maxChannelCount)
        channelOffsets.initialize(repeating: 0, count: Self.maxChannelCount)
    }

    deinit {
        delayBuffer.deallocate()
        peakBuffer.deallocate()
        dequeIndices.deallocate()
        channelPointers.deallocate()
        channelStrides.deallocate()
        channelOffsets.deallocate()
    }


    func reset() {
        delayBuffer.update(repeating: 0.0, count: Self.maxWindowSize * Self.maxChannelCount)
        peakBuffer.update(repeating: 0.0, count: Self.maxWindowSize)
        bufferIndex = 0
        currentGain = 1.0
        frameCounter = 0
        dequeHead = 0
        dequeTail = 0
    }

    /// Process AudioBufferList in-place (handles interleaved, non-interleaved/planar and mixed formats).
    /// Guaranteed RT-safe.
    @inline(__always)
    func process(_ buffers: UnsafeMutableAudioBufferListPointer, frameCount: Int, sampleRate: Double) {
        guard frameCount > 0 else { return }

        // Populate channel mapping
        var channelCount = 0
        for buffer in buffers {
            guard let mData = buffer.mData else { continue }
            let ptr = mData.assumingMemoryBound(to: Float.self)
            let numChannels = max(1, Int(buffer.mNumberChannels))

            for ch in 0..<numChannels {
                if channelCount >= Self.maxChannelCount { break }
                channelPointers[channelCount] = ptr
                channelStrides[channelCount] = numChannels
                channelOffsets[channelCount] = ch
                channelCount += 1
            }
            if channelCount >= Self.maxChannelCount { break }
        }

        guard channelCount > 0 else { return }

        configureIfNeeded(sampleRate: sampleRate)

        for frame in 0..<frameCount {
            let delayBase = bufferIndex * Self.maxChannelCount

            var samplePeak: Float = 0.0
            for channel in 0..<channelCount {
                if let ptr = channelPointers[channel] {
                    let stride = channelStrides[channel]
                    let offset = channelOffsets[channel]
                    let sample = ptr[frame * stride + offset]
                    delayBuffer[delayBase + channel] = sample
                    samplePeak = max(samplePeak, abs(sample))
                }
            }

            peakBuffer[bufferIndex] = samplePeak

            // Pop expired front entries
            while dequeHead != dequeTail {
                let frontAbsIdx = dequeIndices[dequeHead & Self.dequeMask]
                if frameCounter - frontAbsIdx >= windowSize {
                    dequeHead += 1
                } else {
                    break
                }
            }

            // Pop back entries smaller than or equal to current peak
            while dequeHead != dequeTail {
                let backAbsIdx = dequeIndices[(dequeTail - 1) & Self.dequeMask]
                if peakBuffer[backAbsIdx % windowSize] <= samplePeak {
                    dequeTail -= 1
                } else {
                    break
                }
            }

            // Push current index
            dequeIndices[dequeTail & Self.dequeMask] = frameCounter
            dequeTail += 1

            // Front of deque is the window maximum
            let windowMaxPeak = peakBuffer[dequeIndices[dequeHead & Self.dequeMask] % windowSize]

            let targetGain = windowMaxPeak > Self.ceiling ? Self.ceiling / windowMaxPeak : 1.0
            if targetGain < currentGain {
                currentGain = targetGain
            } else {
                currentGain += (targetGain - currentGain) * releaseCoeff
            }

            let outputIndex = (bufferIndex + 1) % windowSize
            let outputBase = outputIndex * Self.maxChannelCount
            for channel in 0..<channelCount {
                if let ptr = channelPointers[channel] {
                    let stride = channelStrides[channel]
                    let offset = channelOffsets[channel]
                    ptr[frame * stride + offset] = delayBuffer[outputBase + channel] * currentGain
                }
            }

            bufferIndex = (bufferIndex + 1) % windowSize
            frameCounter += 1
        }
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

            // Pop expired front entries
            while dequeHead != dequeTail {
                let frontAbsIdx = dequeIndices[dequeHead & Self.dequeMask]
                if frameCounter - frontAbsIdx >= windowSize {
                    dequeHead += 1
                } else {
                    break
                }
            }

            // Pop back entries smaller than or equal to current peak
            while dequeHead != dequeTail {
                let backAbsIdx = dequeIndices[(dequeTail - 1) & Self.dequeMask]
                if peakBuffer[backAbsIdx % windowSize] <= samplePeak {
                    dequeTail -= 1
                } else {
                    break
                }
            }

            // Push current index
            dequeIndices[dequeTail & Self.dequeMask] = frameCounter
            dequeTail += 1

            // Front of deque is the window maximum
            let windowMaxPeak = peakBuffer[dequeIndices[dequeHead & Self.dequeMask] % windowSize]

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
            frameCounter += 1
        }
    }

    @inline(__always)
    private func configureIfNeeded(sampleRate: Double) {
        guard sampleRate != lastSampleRate else { return }

        lastSampleRate = sampleRate
        let samples = Int((lookAheadMs / 1000.0) * sampleRate)
        windowSize = min(Self.maxWindowSize, max(1, samples))
        assert(windowSize < Self.maxDequeCapacity, "windowSize must be less than maxDequeCapacity to prevent deque buffer overflow")

        let releaseTimeSec = releaseTimeMs / 1000.0
        releaseCoeff = Float(1.0 - exp(-1.0 / (sampleRate * releaseTimeSec)))

        reset()
    }
}
