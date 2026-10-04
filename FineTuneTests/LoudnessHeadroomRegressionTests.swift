import Foundation
import AppKit
import Testing
@testable import FineTune

@Suite("Loudness compensation — headroom regressions")
@MainActor
struct LoudnessHeadroomRegressionTests {
    @Test("A new crossfade processor uses all current loudness parameters")
    func crossfadeProcessorRetainsCurrentParameters() {
        let app = AudioApp(id: 12_345, processObjectIDs: [], name: "Test",
                           icon: NSImage(), bundleID: "com.test.loudness.state")
        let tap = ProcessTapController(app: app, targetDeviceUIDs: ["test-device"])
        tap.volume = 0.1
        tap.updateLoudnessCompensation(volume: 0.5, enabled: true, referencePhon: 0,
                                      maxDB: -20, gainScale: 0.7, bassCrossover: 90,
                                      trebleCrossover: 6_000, trebleGainScale: 0.4,
                                      bassExciterWet: 0, bassLinearWet: 0.6)
        let secondary = tap.makeLoudnessCompensator(sampleRate: 48_000)
        let expected = LoudnessCompensator(sampleRate: 48_000)
        expected.updateForVolume(0.5, digitalVolume: 0.1, referencePhon: 0, maxDB: -20,
                                 gainScale: 0.7, bassCrossoverFrequency: 90,
                                 trebleCrossoverFrequency: 6_000, trebleGainScale: 0.4,
                                 bassExciterWet: 0, bassLinearWet: 0.6)
        for frequency in [40.0, 1_000, 10_000] {
            #expect(abs(measure(secondary, frequency: frequency).gainDB
                - measure(expected, frequency: frequency).gainDB) < 0.05)
        }
        tap.updateLoudnessCompensation(volume: 0.5, enabled: true, referencePhon: 0,
                                      maxDB: -40, gainScale: 0.7, bassCrossover: 90,
                                      trebleCrossover: 6_000, trebleGainScale: 0.4,
                                      bassExciterWet: 0.2, bassLinearWet: 0.6)
        let withHarmonics = tap.makeLoudnessCompensator(sampleRate: 48_000)
        expected.updateForVolume(0.5, digitalVolume: 0.1, referencePhon: 0, maxDB: -40,
                                 gainScale: 0.7, bassCrossoverFrequency: 90,
                                 trebleCrossoverFrequency: 6_000, trebleGainScale: 0.4,
                                 bassExciterWet: 0.2, bassLinearWet: 0.6)
        #expect(abs(measure(withHarmonics, frequency: 8_000).gainDB
            - measure(expected, frequency: 8_000).gainDB) < 0.05)
        // Updating the stored state while disabled must also survive a new tap.
        tap.updateLoudnessCompensation(volume: 0.5, enabled: false, referencePhon: 0,
                                      maxDB: -20, gainScale: 0.7, bassCrossover: 90,
                                      trebleCrossover: 6_000, trebleGainScale: 0.4,
                                      bassExciterWet: 0, bassLinearWet: 0.6)
        let disabled = tap.makeLoudnessCompensator(sampleRate: 48_000)
        #expect(abs(measure(disabled, frequency: 40).gainDB) < 0.05)
    }

    @Test("Headroom attenuation preserves the bass to midrange balance")
    func globalAttenuationPreservesShape() {
        for digital: Float in [1, 0.5, 0.25, 0.1] {
            let bass = gain(at: 40, digital: digital)
            let mid = gain(at: 1_000, digital: digital)
            // Independently measured response of the original 10 dB shelf + 2 dB bell.
            #expect(abs((bass - mid) - 9.37) < 0.1)
        }
    }

    @Test("Digital attenuation is consumed before additional preamp attenuation")
    func existingDigitalHeadroomIsUsed() {
        #expect(abs(gain(at: 1_000, digital: 0.1) - 0.133) < 0.05)
        #expect(abs(gain(at: 1_000, digital: 1) - (-9.87)) < 0.1)
    }

    @Test("A small digital gain change refreshes headroom at the same listening volume")
    func smallDigitalGainChangeRefreshesHeadroom() {
        let processor = LoudnessCompensator(sampleRate: 48_000)
        processor.updateForVolume(0.25, digitalVolume: 0.30, bassExciterWet: 0)
        processor.updateForVolume(0.25, digitalVolume: 0.34, bassExciterWet: 0)
        let fresh = LoudnessCompensator(sampleRate: 48_000)
        fresh.updateForVolume(0.25, digitalVolume: 0.34, bassExciterWet: 0)
        let changed = measure(processor, frequency: 40).gainDB
        let expected = measure(fresh, frequency: 40).gainDB
        #expect(abs(changed - expected) < 0.05)
    }

    @Test("Changing sample rate retains the same hybrid loudness model")
    func sampleRateChangeMatchesFreshProcessor() {
        for frequency in [40.0, 1_000, 3_000, 10_000] {
            let switched = LoudnessCompensator(sampleRate: 48_000)
            switched.updateForVolume(0.25, digitalVolume: 1, bassExciterWet: 0)
            switched.updateSampleRate(44_100)
            let fresh = LoudnessCompensator(sampleRate: 44_100)
            fresh.updateForVolume(0.25, digitalVolume: 1, bassExciterWet: 0)
            let actual = measure(switched, rate: 44_100, frequency: frequency).gainDB
            let expected = measure(fresh, rate: 44_100, frequency: frequency).gainDB
            #expect(abs(actual - expected) < 0.05)
        }
    }

    @Test("Bass intensity controls the audible linear correction")
    func gainScaleControlsBassResponse() {
        let processor = LoudnessCompensator(sampleRate: 48_000)
        processor.updateForVolume(0.25, digitalVolume: 0.1, gainScale: 0, bassExciterWet: 0)
        #expect(abs(measure(processor, frequency: 40).gainDB) < 0.05)
        processor.updateForVolume(0.25, digitalVolume: 0.1, gainScale: 0.5, bassExciterWet: 0)
        let half = measure(processor, frequency: 40).gainDB
        #expect(half > 4 && half < 5)
    }

    @Test("Disabling linear bass leaves no linear bass boost")
    func bassLinearWetControlsBassResponse() {
        let processor = LoudnessCompensator(sampleRate: 48_000)
        processor.updateForVolume(0.25, digitalVolume: 0.1, bassExciterWet: 0, bassLinearWet: 0)
        #expect(abs(measure(processor, frequency: 40).gainDB) < 0.05)
    }

    @Test("The hybrid exciter has headroom before the final limiter")
    func fullScaleSinesStayWithinHeadroom() {
        for rate in [44_100.0, 48_000, 96_000] {
            for digital: Float in [1, 0.5, 0.35, 0.25, 0.1] {
                for frequency in [20.0, 40, 60, 100, 3_000, 10_000] {
                    let processor = LoudnessCompensator(sampleRate: rate)
                    processor.updateForVolume(0.25, digitalVolume: digital)
                    let peak = measure(processor, rate: rate, frequency: frequency, amplitude: 0.999 * digital).peak
                    #expect(peak <= 1.001, "Pre-limiter peak \(peak) at \(frequency) Hz, gain \(digital), rate \(rate)")
                }
            }
        }
    }

    @Test("A normalized multitone signal retains headroom with the exciter")
    func multitoneStaysWithinHeadroom() {
        let rate = 48_000.0
        let frames = 48_000
        for digital: Float in [1, 0.35, 0.1] {
            var samples = [Float](repeating: 0, count: frames * 2)
            for frame in 0..<frames {
                let time = Double(frame) / rate
                let value = Float((sin(2 * .pi * 40 * time) + sin(2 * .pi * 100 * time)
                    + sin(2 * .pi * 3_000 * time) + sin(2 * .pi * 10_000 * time)) / 4) * digital * 0.999
                samples[frame * 2] = value
                samples[frame * 2 + 1] = value
            }
            let processor = LoudnessCompensator(sampleRate: rate)
            processor.updateForVolume(0.25, digitalVolume: digital)
            samples.withUnsafeMutableBufferPointer { buffer in
                processor.process(input: UnsafePointer(buffer.baseAddress!), output: buffer.baseAddress!, frameCount: frames)
            }
            #expect(samples.allSatisfy { $0.isFinite && abs($0) <= 1.001 })
        }
    }

    @Test("Full listening volume bypasses previous headroom attenuation")
    func referenceVolumeClearsAttenuation() {
        let processor = LoudnessCompensator(sampleRate: 48_000)
        processor.updateForVolume(0.25)
        processor.updateForVolume(1)
        #expect(abs(measure(processor, frequency: 1_000).gainDB) < 0.05)
    }

    private func gain(at frequency: Double, digital: Float) -> Double {
        let processor = LoudnessCompensator(sampleRate: 48_000)
        processor.updateForVolume(0.25, digitalVolume: digital, bassExciterWet: 0)
        return measure(processor, frequency: frequency).gainDB
    }

    private func measure(_ processor: LoudnessCompensator, rate: Double = 48_000,
                         frequency: Double, amplitude: Float = 0.001) -> (gainDB: Double, peak: Float) {
        let warmup = Int(rate / 4)
        let measuredFrames = Int(rate / 2)
        let frames = warmup + measuredFrames
        var samples = [Float](repeating: 0, count: frames * 2)
        for frame in 0..<frames {
            let value = amplitude * Float(sin(2 * .pi * frequency * Double(frame) / rate))
            samples[frame * 2] = value
            samples[frame * 2 + 1] = value
        }
        samples.withUnsafeMutableBufferPointer { buffer in
            processor.process(input: UnsafePointer(buffer.baseAddress!), output: buffer.baseAddress!, frameCount: frames)
        }
        var real = 0.0
        var imaginary = 0.0
        var peak: Float = 0
        for frame in warmup..<frames {
            let angle = 2 * .pi * frequency * Double(frame) / rate
            let sample = samples[frame * 2]
            real += Double(sample) * cos(angle)
            imaginary += Double(sample) * sin(angle)
            peak = max(peak, abs(sample))
        }
        let magnitude = 2 * hypot(real, imaginary) / Double(measuredFrames)
        return (20 * log10(magnitude / Double(amplitude)), peak)
    }
}
