// FineTune/Audio/Engine/InputLevelMonitor.swift
import AudioToolbox
import Foundation
import os
import Accelerate

@MainActor
final class InputLevelMonitor {
    private let logger = Logger(subsystem: "com.ronitsingh.FineTune", category: "InputLevelMonitor")
    private let queue = DispatchQueue(label: "InputLevelMonitor", qos: .userInitiated)
    private var currentDeviceID: AudioDeviceID = .unknown
    private var deviceProcID: AudioDeviceIOProcID? = nil
    private var isRunning = false

    // MARK: - Thread-Safe Level State (nonisolated(unsafe) for lock-free audio thread access)
    private nonisolated(unsafe) var _peakLevel: Float = 0.0
    private nonisolated(unsafe) var _leftPeakLevel: Float = 0.0
    private nonisolated(unsafe) var _rightPeakLevel: Float = 0.0
    private nonisolated(unsafe) var _channelCount: Int = 1
    private nonisolated(unsafe) var _lastCallbackTime: UInt64 = 0

    var peakLevel: Float {
        guard hasRecentAudioCallback(within: 0.5) else { return 0.0 }
        return _peakLevel
    }

    var channelLevels: [Float] {
        guard hasRecentAudioCallback(within: 0.5) else {
            return [0.0, 0.0]
        }
        return [_leftPeakLevel, _rightPeakLevel]
    }

    private static let hostTimeNanosScale: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        guard info.denom != 0 else { return 1.0 }
        return Double(info.numer) / Double(info.denom)
    }()

    func hasRecentAudioCallback(within seconds: Double) -> Bool {
        let last = _lastCallbackTime
        guard last != 0 else { return false }
        let now = mach_absolute_time()
        let deltaNanos = Double(now &- last) * Self.hostTimeNanosScale
        return deltaNanos <= (seconds * 1_000_000_000.0)
    }

    func start(deviceID: AudioDeviceID) {
        // Avoid recreating if already running on the same device
        if isRunning && currentDeviceID == deviceID { return }
        
        stop()
        guard deviceID != .unknown else { return }
        currentDeviceID = deviceID

        var procID: AudioDeviceIOProcID? = nil
        let err = AudioDeviceCreateIOProcIDWithBlock(&procID, deviceID, queue) { @Sendable [weak self] _, inInputData, _, _, _ in
            guard let self = self else { return }
            self.processInputAudio(inInputData)
        }

        guard err == noErr, let createdProcID = procID else {
            logger.error("Failed to create IOProc for input device \(deviceID): OSStatus \(err)")
            return
        }

        deviceProcID = createdProcID

        let startErr = AudioDeviceStart(deviceID, createdProcID)
        if startErr == noErr {
            isRunning = true
            logger.debug("Started input level monitor for device \(deviceID)")
        } else {
            logger.error("Failed to start IOProc for input device \(deviceID): OSStatus \(startErr)")
            AudioDeviceDestroyIOProcID(deviceID, createdProcID)
            deviceProcID = nil
            currentDeviceID = .unknown
        }
    }

    func stop() {
        guard isRunning, let procID = deviceProcID, currentDeviceID != .unknown else { return }
        
        let stopErr = AudioDeviceStop(currentDeviceID, procID)
        if stopErr != noErr {
            logger.error("Failed to stop IOProc for input device \(self.currentDeviceID): OSStatus \(stopErr)")
        }

        let destroyErr = AudioDeviceDestroyIOProcID(currentDeviceID, procID)
        if destroyErr != noErr {
            logger.error("Failed to destroy IOProc for input device \(self.currentDeviceID): OSStatus \(destroyErr)")
        }

        deviceProcID = nil
        currentDeviceID = .unknown
        isRunning = false
        _peakLevel = 0.0
        _leftPeakLevel = 0.0
        _rightPeakLevel = 0.0
        _channelCount = 1
        _lastCallbackTime = 0
        logger.debug("Stopped input level monitor")
    }

    nonisolated
    private func processInputAudio(_ inputData: UnsafePointer<AudioBufferList>) {
        _lastCallbackTime = mach_absolute_time()
        
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        var maxPeak: Float = 0.0
        var leftPeak: Float = 0.0
        var rightPeak: Float = 0.0
        var channelCount = 1

        for buffer in buffers {
            let channels = Int(buffer.mNumberChannels)
            guard channels > 0, let data = buffer.mData else { continue }
            let samples = data.assumingMemoryBound(to: Float.self)
            let sampleCount = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            let frameCount = sampleCount / channels

            if channels >= 2 {
                channelCount = 2
                var ch0Peak: Float = 0.0
                var ch1Peak: Float = 0.0
                vDSP_maxmgv(samples, 2, &ch0Peak, vDSP_Length(frameCount))
                vDSP_maxmgv(samples.advanced(by: 1), 2, &ch1Peak, vDSP_Length(frameCount))
                leftPeak = max(leftPeak, ch0Peak)
                rightPeak = max(rightPeak, ch1Peak)
                maxPeak = max(maxPeak, ch0Peak, ch1Peak)
            } else {
                var chPeak: Float = 0.0
                vDSP_maxmgv(samples, 1, &chPeak, vDSP_Length(sampleCount))
                maxPeak = max(maxPeak, chPeak)
                leftPeak = max(leftPeak, chPeak)
                rightPeak = max(rightPeak, chPeak)
            }
        }

        _peakLevel = maxPeak
        _leftPeakLevel = leftPeak
        _rightPeakLevel = rightPeak
        _channelCount = channelCount
    }
}
