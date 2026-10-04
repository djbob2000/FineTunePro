import AudioToolbox
import Foundation

/// Preallocated broadcast renderer for a non-stacked multi-output aggregate.
/// The app's common DSP runs once; each device owns correction delay buffers and a
/// final safety limiter. HAL callbacks never allocate, query HAL, or acquire locks.
final class MirroredAudioRenderer: @unchecked Sendable {
    struct Output: Sendable {
        let uid: String
        let channelCount: Int
        let left: Int
        let right: Int
    }

    private final class Correction {
        let output: Output
        let processor: AutoEQProcessor
        let limiter = BrickwallLimiter()
        let samples: UnsafeMutablePointer<Float>
        let list: UnsafeMutablePointer<AudioBufferList>
        var gain: Float = 1
        var muted = false
        var currentGain: Float = 1

        init(output: Output, sampleRate: Double, capacity: Int) {
            self.output = output
            processor = AutoEQProcessor(sampleRate: sampleRate)
            samples = .allocate(capacity: capacity * 2)
            samples.initialize(repeating: 0, count: capacity * 2)
            list = .allocate(capacity: 1)
            list.initialize(to: AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                mNumberChannels: 2, mDataByteSize: 0, mData: samples)))
        }

        deinit {
            samples.deallocate()
            list.deinitialize(count: 1)
            list.deallocate()
        }
    }

    // Larger than every user-selectable buffer size; unexpected oversized HAL
    // buffers are silenced instead of overrunning scratch storage.
    static let capacity = 16384
    static let maxChannels = 256
    private let sampleRate: Double
    private let rampCoefficient: Float
    private let corrections: [Correction]
    private let commonSamples: UnsafeMutablePointer<Float>
    private let commonList: UnsafeMutablePointer<AudioBufferList>
    private let inputSamples: UnsafeMutablePointer<Float>
    private let inputList: UnsafeMutablePointer<AudioBufferList>
    private let channelPointers: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>
    private let channelStrides: UnsafeMutablePointer<Int>
    private let channelFrames: UnsafeMutablePointer<Int>

    init(outputs: [Output], sampleRate: Double, profiles: [String: AutoEQProfile], preampEnabled: Bool) {
        self.sampleRate = sampleRate
        rampCoefficient = 1 - exp(-1 / (Float(sampleRate) * 0.030))
        corrections = outputs.map { output in
            let correction = Correction(output: output, sampleRate: sampleRate, capacity: Self.capacity)
            correction.processor.setPreampEnabled(preampEnabled)
            correction.processor.updateProfile(profiles[output.uid])
            return correction
        }
        commonSamples = .allocate(capacity: Self.capacity * 2)
        commonSamples.initialize(repeating: 0, count: Self.capacity * 2)
        commonList = .allocate(capacity: 1)
        commonList.initialize(to: AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
            mNumberChannels: 2, mDataByteSize: 0, mData: commonSamples)))
        inputSamples = .allocate(capacity: Self.capacity * 2)
        inputSamples.initialize(repeating: 0, count: Self.capacity * 2)
        inputList = .allocate(capacity: 1)
        inputList.initialize(to: AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
            mNumberChannels: 2, mDataByteSize: 0, mData: inputSamples)))
        channelPointers = .allocate(capacity: Self.maxChannels)
        channelPointers.initialize(repeating: nil, count: Self.maxChannels)
        channelStrides = .allocate(capacity: Self.maxChannels)
        channelStrides.initialize(repeating: 0, count: Self.maxChannels)
        channelFrames = .allocate(capacity: Self.maxChannels)
        channelFrames.initialize(repeating: 0, count: Self.maxChannels)
    }

    deinit {
        commonSamples.deallocate()
        commonList.deinitialize(count: 1)
        commonList.deallocate()
        inputSamples.deallocate()
        inputList.deinitialize(count: 1)
        inputList.deallocate()
        channelPointers.deallocate()
        channelStrides.deallocate()
        channelFrames.deallocate()
    }

    func updateProfile(_ profile: AutoEQProfile?, for uid: String) {
        for correction in corrections where correction.output.uid == uid {
            correction.processor.updateProfile(profile)
        }
    }

    func setPreampEnabled(_ enabled: Bool) {
        for correction in corrections { correction.processor.setPreampEnabled(enabled) }
    }

    func setOutputGain(_ gain: Float, muted: Bool, for uid: String, seed: Bool = false) {
        for correction in corrections where correction.output.uid == uid {
            correction.gain = max(0, min(1, gain))
            correction.muted = muted
            if seed { correction.currentGain = correction.gain }
        }
    }

    /// Normalize the trailing process-tap stream to interleaved stereo; preceding
    /// hardware input buffers are never captured. The multi-output tap uses stereo mixdown.
    func prepareInput(_ buffers: UnsafeMutableAudioBufferListPointer, frameCount: Int) -> UnsafeMutableAudioBufferListPointer {
        let frames = max(0, min(Self.capacity, frameCount))
        inputList.pointee.mBuffers.mDataByteSize = UInt32(frames * 2 * MemoryLayout<Float>.size)
        inputSamples.update(repeating: 0, count: frames * 2)
        if buffers.count >= 2, buffers[buffers.count - 1].mNumberChannels == 1,
           buffers[buffers.count - 2].mNumberChannels == 1 {
            let left = buffers[buffers.count - 2]
            let right = buffers[buffers.count - 1]
            let leftSamples = left.mData?.assumingMemoryBound(to: Float.self)
            let rightSamples = right.mData?.assumingMemoryBound(to: Float.self)
            let available = min(frames, Int(min(left.mDataByteSize, right.mDataByteSize)) / MemoryLayout<Float>.size)
            for frame in 0..<available {
                inputSamples[2 * frame] = leftSamples?[frame] ?? 0
                inputSamples[2 * frame + 1] = rightSamples?[frame] ?? 0
            }
        } else if let last = buffers.last, let data = last.mData?.assumingMemoryBound(to: Float.self) {
            let channels = max(1, Int(last.mNumberChannels))
            let available = min(frames, Int(last.mDataByteSize) / (MemoryLayout<Float>.size * channels))
            for frame in 0..<available {
                inputSamples[2 * frame] = data[channels * frame]
                inputSamples[2 * frame + 1] = data[channels * frame + min(1, channels - 1)]
            }
        }
        return UnsafeMutableAudioBufferListPointer(inputList)
    }

    func commonOutput(frameCount: Int) -> UnsafeMutableAudioBufferListPointer {
        let frames = max(0, min(frameCount, Self.capacity))
        commonList.pointee.mBuffers.mDataByteSize = UInt32(frames * 2 * MemoryLayout<Float>.size)
        commonSamples.update(repeating: 0, count: frames * 2)
        return UnsafeMutableAudioBufferListPointer(commonList)
    }

    @discardableResult
    func render(outputBuffers: UnsafeMutableAudioBufferListPointer, frameCount: Int,
                processCommon: (UnsafeMutableAudioBufferListPointer) -> Void) -> (Float, Bool) {
        if frameCount > 0 && frameCount <= Self.capacity { processCommon(commonOutput(frameCount: frameCount)) }
        return renderProcessedCommon(outputBuffers: outputBuffers, frameCount: frameCount)
    }

    /// Supports separate device streams, a packed aggregate buffer and planar
    /// output. Channel ownership follows the aggregate's flattened sub-device order.
    /// The HAL callback calls this directly, with no capturing render closure.
    func renderProcessedCommon(outputBuffers: UnsafeMutableAudioBufferListPointer, frameCount: Int) -> (Float, Bool) {
        var channelCount = 0
        for buffer in outputBuffers {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
            channelCount += Int(buffer.mNumberChannels)
        }
        guard frameCount > 0, frameCount <= Self.capacity, channelCount <= Self.maxChannels else { return (0, false) }
        var channel = 0
        for buffer in outputBuffers {
            let count = Int(buffer.mNumberChannels)
            guard count > 0 else { continue }
            let available = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * count)
            for local in 0..<count {
                channelPointers[channel] = buffer.mData?.assumingMemoryBound(to: Float.self).advanced(by: local)
                channelStrides[channel] = count
                channelFrames[channel] = available
                channel += 1
            }
        }
        var channelOffset = 0
        var peak: Float = 0
        var limited = false
        for correction in corrections {
            let spec = correction.output
            defer { channelOffset += spec.channelCount }
            guard spec.channelCount > 0, channelOffset + spec.channelCount <= channelCount else { continue }
            let left = channelOffset + max(0, min(spec.channelCount - 1, spec.left))
            let right = channelOffset + max(0, min(spec.channelCount - 1, spec.right))
            guard let leftData = channelPointers[left], let rightData = channelPointers[right] else { continue }
            let frames = min(frameCount, channelFrames[left], channelFrames[right])
            guard frames > 0 else { continue }
            correction.samples.update(from: commonSamples, count: frames * 2)
            if correction.processor.isEnabled {
                correction.processor.process(input: correction.samples, output: correction.samples, frameCount: frames)
            }
            for frame in 0..<frames {
                correction.currentGain += (correction.gain - correction.currentGain) * rampCoefficient
                let gain: Float = correction.muted ? 0 : correction.currentGain
                for side in 0..<2 {
                    let index = frame * 2 + side
                    let value = correction.samples[index] * gain
                    correction.samples[index] = value.isFinite ? value : 0
                    peak = max(peak, abs(correction.samples[index]))
                    limited = limited || abs(correction.samples[index]) > BrickwallLimiter.ceiling
                }
            }
            correction.list.pointee.mBuffers.mDataByteSize = UInt32(frames * 2 * MemoryLayout<Float>.size)
            correction.limiter.process(UnsafeMutableAudioBufferListPointer(correction.list), frameCount: frames, sampleRate: sampleRate)
            for frame in 0..<frames {
                if left == right {
                    leftData[frame * channelStrides[left]] = (correction.samples[frame * 2] + correction.samples[frame * 2 + 1]) * 0.5
                } else {
                    leftData[frame * channelStrides[left]] = correction.samples[frame * 2]
                    rightData[frame * channelStrides[right]] = correction.samples[frame * 2 + 1]
                }
            }
        }
        return (peak, limited)
    }
}
