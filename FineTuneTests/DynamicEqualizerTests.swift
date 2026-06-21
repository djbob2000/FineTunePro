import Testing
import Foundation
@testable import FineTune

@Suite("DynamicEqualizerTests")
struct DynamicEqualizerTests {

    @Test("Frequency response of the bandpass filters")
    func bandpassFrequencyResponse() {
        let eq = DynamicEqualizer(sampleRate: 48000.0)
        let frequencies = DynamicEqualizer.frequencies
        
        // Feed a sine wave at the resonant frequency of each band
        // Verify that the bandpass filter outputs the frequency with near-unity gain,
        // while other bandpass filters attenuate it heavily.
        for (i, f0) in frequencies.enumerated() {
            // Generate a 0.5s sine wave buffer at f0 (24000 frames @ 48kHz)
            let frameCount = 24000
            var input = [Float](repeating: 0, count: frameCount * 2)
            for frame in 0..<frameCount {
                let t = Double(frame) / 48000.0
                let val = Float(sin(2.0 * .pi * f0 * t))
                input[frame * 2] = val
                input[frame * 2 + 1] = val
            }
            
            // Run process
            var output = [Float](repeating: 0, count: frameCount * 2)
            eq.reset()
            eq.process(input: input, output: &output, frameCount: frameCount)
            
            // The envelope follower for the matched band i should have a relatively high value,
            // while other bands should have lower values because they are off-resonance.
            let matchedEnvelope = eq.envelopes[i]
            #expect(matchedEnvelope > 0.05, "Resonant envelope for band \(i) at frequency \(f0) Hz should be high, got \(matchedEnvelope)")
            
            for j in 0..<5 {
                if j != i {
                    // Let's verify that other bands off-resonance are significantly lower
                    // or at least not as high as the matched band.
                    if abs(log2(frequencies[j] / f0)) > 2.4 {
                        #expect(eq.envelopes[j] < matchedEnvelope * 0.2, "Off-resonance envelope for band \(j) should be heavily attenuated compared to matched envelope \(matchedEnvelope)")
                    }
                }
            }
        }
    }

    @Test("Correct target calculations (relative spectral balance)")
    func targetCalculations() {
        let eq = DynamicEqualizer(sampleRate: 48000.0)
        
        // 1. All bands at -10 dBFS (amplitude 0.1)
        // With -10dBFS, all active, relative level is flat (0 relative to average).
        // target balance is [5.4, 4.0, 2.4, -2.5, -7.5]
        // strength = 0.5
        // expected targets = [2.7, 2.0, 1.2, -1.25, -3.75]
        eq.envelopes = [0.1, 0.1, 0.1, 0.1, 0.1]
        let targets = eq.calculateTargetGains()
        let expected: [Float] = [3.0, 0.75, 0.0, 0.5, -2.25]
        for i in 0..<5 {
            #expect(abs(targets[i] - expected[i]) < 1e-4)
        }
    }

    @Test("Silence gate threshold behavior (moves to 0dB gain below -50dBFS)")
    func silenceGateBehavior() {
        let eq = DynamicEqualizer(sampleRate: 48000.0)
        
        // 1. One band below -50 dBFS
        // E.g. band 4 is at -60 dBFS (amplitude 0.001)
        // bands 0..3 are at -10 dBFS (amplitude 0.1)
        // Band 4 should be silent-gated (target gain = 0.0)
        eq.envelopes = [0.1, 0.1, 0.1, 0.1, 0.001]
        let targets = eq.calculateTargetGains()
        #expect(targets[4] == 0.0)
        
        // Active bands 0..3 should calculate their relative levels ignoring band 4
        // avgDB of active bands = -10 dB
        // relative level of active bands = 0 dB
        // active expected targets: [3.0, 0.75, 0.0, 0.5]
        let expected: [Float] = [3.0, 0.75, 0.0, 0.5]
        for i in 0..<4 {
            #expect(abs(targets[i] - expected[i]) < 1e-4)
        }
        
        // 2. All bands below silence threshold (-50 dBFS)
        eq.envelopes = [0.001, 0.001, 0.001, 0.001, 0.001] // all -60 dBFS
        let allSilentTargets = eq.calculateTargetGains()
        for i in 0..<5 {
            #expect(allSilentTargets[i] == 0.0)
        }
    }

    @Test("Dynamic gain change rate limits (speed of cut/boost)")
    func gainChangeRateLimits() {
        let eq = DynamicEqualizer(sampleRate: 48000.0)
        eq.reset()
        
        // We run a process buffer of 128 frames (dt = 128 / 48000 = 0.002666... sec)
        let frameCount = 128
        let dt = Double(frameCount) / 48000.0
        
        // Feed -10 dBFS signal to active bands
        let input = [Float](repeating: 0.1, count: frameCount * 2)
        var output = [Float](repeating: 0.0, count: frameCount * 2)
        
        // Override envelopes directly to bypass follower buildup
        eq.envelopes = [0.1, 0.1, 0.1, 0.1, 0.1]
        
        eq.process(input: input, output: &output, frameCount: frameCount)
        
        // Verify currentGains have shifted towards targets according to exponential smoothing
        let targets = eq.calculateTargetGains()
        for i in 0..<5 {
            let target = targets[i]
            let isSuddenJump = abs(target) > 2.0
            let expectedTau = isSuddenJump ? (1.3 / 1.5) : 1.3
            let expectedBeta = Float(exp(-dt / expectedTau))
            let expectedGain = (1.0 - expectedBeta) * target
            print("Band \(i): target=\(target), got=\(eq.currentGains[i]), expected=\(expectedGain), diff=\(abs(eq.currentGains[i] - expectedGain))")
            #expect(abs(eq.currentGains[i] - expectedGain) < 1e-4)
        }
        
        // Test Loud Band Protection:
        // Set current gains to 0, feed envelopes where band 0 is quiet and other bands are loud
        // to create a large target boost > 3.0 dB on band 0.
        eq.reset()
        eq.envelopes = [0.1, 10.0, 10.0, 10.0, 10.0]
        eq.process(input: input, output: &output, frameCount: frameCount)
        
        // Target for band 0 should be capped to 3.0 before applying smoothing
        let rawTarget = eq.calculateTargetGains()[0]
        #expect(rawTarget > 3.0) // Raw target is indeed > 3.0
        
        let expectedTau = 3.0 > 2.0 ? (1.3 / 1.5) : 1.3
        let expectedBeta = Float(exp(-dt / expectedTau))
        let expectedGain = (1.0 - expectedBeta) * 3.0 // capped to 3.0
        #expect(abs(eq.currentGains[0] - expectedGain) < 1e-4)
    }

    @Test("Unity gain when disabled")
    func unityGainWhenDisabled() {
        let eq = DynamicEqualizer(sampleRate: 48000.0)
        eq.isEnabled = false
        
        // Generate test buffer with values
        let frameCount = 64
        let input = (0..<frameCount*2).map { Float($0) * 0.01 }
        var output = [Float](repeating: 0, count: frameCount*2)
        
        // Set envelopes to something that would trigger EQ change if enabled
        eq.envelopes = [1.0, 1.0, 1.0, 1.0, 1.0]
        eq.currentGains = [5.0, 5.0, 5.0, 5.0, 5.0]
        
        eq.process(input: input, output: &output, frameCount: frameCount)
        
        // Output should be exactly equal to input
        #expect(output == input)
    }

    @Test("Dynamic EQ response on different frequencies with different intensities")
    func dynamicEQIntensityAndContinuity() {
        let eq = DynamicEqualizer(sampleRate: 48000.0)
        let frequencies = DynamicEqualizer.frequencies
        
        // We will test each target frequency
        for (i, f0) in frequencies.enumerated() {
            // Generate test signals at f0 with different intensities/amplitudes:
            // 1. High intensity (amplitude 0.8)
            // 2. Low intensity (amplitude 0.1)
            
            // To allow envelope and gains to settle, we run multiple blocks
            let blockSize = 512
            let blockCount = 30
            
            // --- 1. High Intensity ---
            eq.reset()
            for _ in 0..<blockCount {
                var input = [Float](repeating: 0, count: blockSize * 2)
                for frame in 0..<blockSize {
                    let val = Float(0.8 * sin(2.0 * .pi * f0 * Double(frame) / 48000.0))
                    input[frame * 2] = val
                    input[frame * 2 + 1] = val
                }
                var output = [Float](repeating: 0, count: blockSize * 2)
                eq.process(input: input, output: &output, frameCount: blockSize)
            }
            let gainHigh = eq.currentGains[i]
            
            // --- 2. Low Intensity ---
            eq.reset()
            for _ in 0..<blockCount {
                var input = [Float](repeating: 0, count: blockSize * 2)
                for frame in 0..<blockSize {
                    let val = Float(0.1 * sin(2.0 * .pi * f0 * Double(frame) / 48000.0))
                    input[frame * 2] = val
                    input[frame * 2 + 1] = val
                }
                var output = [Float](repeating: 0, count: blockSize * 2)
                eq.process(input: input, output: &output, frameCount: blockSize)
            }
            let gainLow = eq.currentGains[i]
            
            // Verify that the EQ adjusts (i.e. gain is different for different intensities)
            #expect(abs(gainHigh - gainLow) > 0.05, "Gain for frequency \(f0) at high intensity (\(gainHigh) dB) should be different from low intensity (\(gainLow) dB)")
            
            // --- 3. Gating/Silence Test ---
            // If we feed silence after high intensity, the EQ should not immediately/suddenly jump/reset to 0.
            // It should equalize continuously or at least decay smoothly without sudden gating discontinuities.
            eq.reset()
            // First feed high intensity to establish a gain offset
            for _ in 0..<blockCount {
                var input = [Float](repeating: 0, count: blockSize * 2)
                for frame in 0..<blockSize {
                    let val = Float(0.8 * sin(2.0 * .pi * f0 * Double(frame) / 48000.0))
                    input[frame * 2] = val
                    input[frame * 2 + 1] = val
                }
                var output = [Float](repeating: 0, count: blockSize * 2)
                eq.process(input: input, output: &output, frameCount: blockSize)
            }
            
            // Now process a block of pure silence
            var inputSilence = [Float](repeating: 0.0, count: blockSize * 2)
            var outputSilence = [Float](repeating: 0, count: blockSize * 2)
            eq.process(input: inputSilence, output: &outputSilence, frameCount: blockSize)
            let gainAfterSilence = eq.currentGains[i]
            
            // Verify it did not suddenly reset to exactly 0.0 due to a hard silence gate
            #expect(abs(gainAfterSilence) > 0.01, "EQ should continuously equalize and not suddenly drop to 0 on silence. Got \(gainAfterSilence) dB")
        }
    }

    @Test("Automatic negative makeup gain prevents peak gains above 0dB")
    func automaticNegativeMakeupGain() {
        let eq = DynamicEqualizer(sampleRate: 48000.0)
        eq.reset()
        
        // Setup current gains to have a boost on some bands
        // max boost is +6.0 dB (which is a linear gain of 2.0)
        eq.currentGains = [6.0, 2.0, 0.0, -3.0, -5.0]
        eq.setupFilters()
        
        let frameCount = 100
        // Feed a DC signal to verify scaling
        let input = [Float](repeating: 0.5, count: frameCount * 2)
        var output = [Float](repeating: 0.0, count: frameCount * 2)
        
        eq.process(input: input, output: &output, frameCount: frameCount)
        
        // With a 6.0 dB boost peaking filter, the maximum gain is +6.0 dB.
        // Makeup gain should be -6.0 dB (linear 0.5), pulling the maximum gain down to 0.0 dB.
        // Let's verify that the output samples do not exceed the input amplitude (0.5).
        for val in output {
            #expect(abs(val) <= 0.501, "Output sample \(val) should not exceed input amplitude 0.5 due to negative makeup gain")
        }
    }
}
