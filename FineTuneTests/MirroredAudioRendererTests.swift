import AudioToolbox
import Testing
@testable import FineTune

@Suite("Mirrored per-device AutoEQ")
@MainActor
struct MirroredAudioRendererTests {
    private func profile(_ id: String, preamp: Float) -> AutoEQProfile {
        AutoEQProfile(id: id, name: id, source: .imported, preampDB: preamp,
                      filters: [.init(type: .peaking, frequency: 1000, gainDB: 0, q: 0.7)])
    }

    @Test("Each packed output channel pair receives its own correction")
    func independentCorrections() {
        let renderer = MirroredAudioRenderer(
            outputs: [.init(uid: "a", channelCount: 2, left: 0, right: 1),
                      .init(uid: "b", channelCount: 2, left: 0, right: 1)],
            sampleRate: 48000, profiles: ["a": profile("a", preamp: -6), "b": profile("b", preamp: -12)],
            preampEnabled: true)
        var samples = [Float](repeating: 0.5, count: 512 * 2)
        var output = [Float](repeating: -99, count: 512 * 4)
        samples.withUnsafeMutableBytes { source in
            output.withUnsafeMutableBytes { destination in
                var input = AudioBufferList(mNumberBuffers: 1, mBuffers: .init(mNumberChannels: 2, mDataByteSize: UInt32(source.count), mData: source.baseAddress))
                var outputs = AudioBufferList(mNumberBuffers: 1, mBuffers: .init(mNumberChannels: 4, mDataByteSize: UInt32(destination.count), mData: destination.baseAddress))
                withUnsafeMutablePointer(to: &input) { inputPtr in
                    withUnsafeMutablePointer(to: &outputs) { outPtr in
                        renderer.render(outputBuffers: UnsafeMutableAudioBufferListPointer(outPtr), frameCount: 512) { shared in
                            memcpy(shared[0].mData!, inputPtr.pointee.mBuffers.mData!, source.count)
                        }
                    }
                }
            }
        }
        #expect(abs(output[511 * 4] - 0.5 * powf(10, -6 / 20)) < 0.001)
        #expect(abs(output[511 * 4 + 2] - 0.5 * powf(10, -12 / 20)) < 0.001)
    }

    @Test("Unsupported primary does not disable a corrected secondary; profile updates stay local")
    func secondaryOnly() {
        let renderer = MirroredAudioRenderer(
            outputs: [.init(uid: "speaker", channelCount: 2, left: 0, right: 1),
                      .init(uid: "headphones", channelCount: 2, left: 0, right: 1)],
            sampleRate: 48000, profiles: ["headphones": profile("headphones", preamp: -12)], preampEnabled: true)
        var output = [Float](repeating: 0, count: 512 * 4)
        func render() {
            output.withUnsafeMutableBytes { destination in
                var list = AudioBufferList(mNumberBuffers: 1, mBuffers: .init(mNumberChannels: 4, mDataByteSize: UInt32(destination.count), mData: destination.baseAddress))
                withUnsafeMutablePointer(to: &list) { pointer in
                    renderer.render(outputBuffers: UnsafeMutableAudioBufferListPointer(pointer), frameCount: 512) { shared in
                        shared[0].mData!.assumingMemoryBound(to: Float.self).update(repeating: 0.5, count: 1024)
                    }
                }
            }
        }
        render()
        #expect(abs(output[2044] - 0.5) < 0.001)
        #expect(abs(output[2046] - 0.5 * powf(10, -12 / 20)) < 0.001)
        renderer.updateProfile(nil, for: "headphones")
        render()
        #expect(abs(output[2044] - 0.5) < 0.001)
        #expect(abs(output[2046] - 0.5) < 0.001)
    }

    @Test("Planar outputs respect preferred channels, independent software gain and mute")
    func planarGainAndMute() {
        let renderer = MirroredAudioRenderer(outputs: [
            .init(uid: "interface", channelCount: 4, left: 2, right: 3),
            .init(uid: "headphones", channelCount: 2, left: 0, right: 1)
        ], sampleRate: 48000, profiles: [:], preampEnabled: true)
        renderer.setOutputGain(0.25, muted: false, for: "interface", seed: true)
        renderer.setOutputGain(1, muted: true, for: "headphones", seed: true)
        let list = AudioBufferList.allocate(maximumBuffers: 6)
        let data = UnsafeMutablePointer<Float>.allocate(capacity: 6 * 128)
        data.initialize(repeating: -99, count: 6 * 128)
        defer { data.deallocate(); free(list.unsafeMutablePointer) }
        for channel in 0..<6 {
            list[channel] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 128 * 4, mData: data.advanced(by: channel * 128))
        }
        renderer.render(outputBuffers: list, frameCount: 128) { common in
            common[0].mData!.assumingMemoryBound(to: Float.self).update(repeating: 0.5, count: 256)
        }
        #expect(data[127] == 0)
        #expect(data[128 + 127] == 0)
        #expect(abs(data[256 + 127] - 0.125) < 0.001)
        #expect(abs(data[384 + 127] - 0.125) < 0.001)
        #expect(data[512 + 127] == 0)
        #expect(data[640 + 127] == 0)
        renderer.setOutputGain(0.5, muted: false, for: "headphones", seed: true)
        renderer.render(outputBuffers: list, frameCount: 128) { common in
            common[0].mData!.assumingMemoryBound(to: Float.self).update(repeating: 0.5, count: 256)
        }
        #expect(abs(data[256 + 127] - 0.125) < 0.001)
        #expect(abs(data[512 + 127] - 0.25) < 0.001)
    }

    @Test("Oversized callback buffers are silenced without running common DSP")
    func oversizedSilence() {
        let renderer = MirroredAudioRenderer(outputs: [.init(uid: "a", channelCount: 2, left: 0, right: 1)],
            sampleRate: 48000, profiles: [:], preampEnabled: true)
        var samples = [Float](repeating: 1, count: 16)
        samples.withUnsafeMutableBytes { bytes in
            var buffer = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2,
                mDataByteSize: UInt32(bytes.count), mData: bytes.baseAddress))
            withUnsafeMutablePointer(to: &buffer) {
                renderer.render(outputBuffers: UnsafeMutableAudioBufferListPointer($0), frameCount: MirroredAudioRenderer.capacity + 1) { _ in
                    Issue.record("Oversized buffers must not run DSP")
                }
            }
        }
        #expect(samples.allSatisfy { $0 == 0 })
    }

}
