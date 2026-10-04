// FineTune/Audio/Engine/TapInitialState.swift
import Foundation

/// Persisted settings applied to a fresh ProcessTapController before its IOProc starts.
struct TapInitialState {
    var appAUEffectChain: [AUEffectChainEntry] = []
    var deviceAUEffectChain: [AUEffectChainEntry] = []
    var appAUBypassed: Bool = false
    var deviceAUBypassed: Bool = false
    var monoDownmix: Bool = false
    var eqSettings: EQSettings = .flat
    var autoEQProfile: AutoEQProfile? = nil
    var autoEQPreampEnabled: Bool = false
    var loudnessVolume: Float = 1.0
    var loudnessCompensationEnabled: Bool = false
    var loudnessReferencePhon: Double = ISO226Contours.defaultReferencePhon
    var loudnessMaxDB: Double = -30.0
    var loudnessEqualizerSettings: LoudnessEqualizerSettings = .init()
    var loudnessBassCrossover: Double = 70.0
    var loudnessGainScale: Double = 1.0
    var loudnessTrebleCrossover: Double = 3000.0
    var loudnessTrebleGainScale: Double = 1.0
    var loudnessBassExciterWet: Double = 0.20
    var loudnessBassLinearWet: Double = 1.0
}

/// Destination settings captured on main before a routing operation suspends.
struct DeviceAUEffectConfiguration: Equatable {
    var entries: [AUEffectChainEntry]
    var isBypassed: Bool
}
