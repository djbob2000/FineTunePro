// FineTune/Audio/Engine/TapInitialState.swift
import Foundation

/// Persisted settings applied to a fresh ProcessTapController before its IOProc starts.
struct TapInitialState {
    var eqSettings: EQSettings = .flat
    var autoEQProfile: AutoEQProfile? = nil
    var autoEQPreampEnabled: Bool = false
    var loudnessVolume: Float = 1.0
    var loudnessCompensationEnabled: Bool = false
    var loudnessReferencePhon: Double = ISO226Contours.defaultReferencePhon
    var loudnessEqualizerSettings: LoudnessEqualizerSettings = .init()
    var loudnessBassCrossover: Double = 70.0
    var loudnessGainScale: Double = 1.0
    var loudnessTrebleCrossover: Double = 3000.0
    var loudnessTrebleGainScale: Double = 1.0
    var loudnessBassExciterWet: Double = 0.20
    var loudnessBassLinearWet: Double = 1.0
}
