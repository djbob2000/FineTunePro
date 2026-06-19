# Дизайн плавного тембрального перехода при переключении Loudness

Этот документ описывает дизайн плавного (300 мс) тембрального перехода (изменения АЧХ фильтров тонкомпенсации) при включении и выключении функции Loudness Compensator.

## Проблема
При переключении режима Loudness Compensator системная громкость меняется плавно в течение 300 мс (для аппаратных/DDC устройств), но характеристики цифровых фильтров (АЧХ) переключаются мгновенно. Это создает ощутимый тембральный скачок (резкое появление/исчезновение баса и высоких частот) до завершения изменения громкости.

## Решение
Тембральные характеристики фильтров тонкомпенсации должны меняться плавно в течение тех же 300 мс, синхронно с изменением громкости (или независимо, если аппаратное управление громкостью отсутствует).

Мы вводим коэффициент масштабирования усиления `gainScale` (от `0.0` до `1.0`), который умножается на рассчитанные целевые усиления полос фильтра:
* `gainScale = 0.0` — фильтр полностью плоский (bypassed).
* `gainScale = 1.0` — фильтр имеет полные целевые характеристики.

При переходе `gainScale` меняется линейно параллельно с изменением аппаратной громкости.

## Изменения в коде

### 1. LoudnessCompensator.swift
Добавляем поддержку масштабирования усиления полос:
```swift
private var _currentGainScale: Float = 1.0

func updateForVolume(_ systemVolume: Float, digitalVolume: Float = 1.0, referencePhon: Double = 85.0, gainScale: Float = 1.0) {
    ...
    guard !isEnabled || abs(phon - _currentPhon) >= 1.0 || ... || abs(gainScale - _currentGainScale) >= 0.01 else { return }
    _currentGainScale = gainScale
    ...
    let gains = computeBandGains(phon: phon, referencePhon: referencePhon, digitalVolume: digitalVolume, gainScale: gainScale)
    ...
}

private func computeBandGains(phon: Double, referencePhon: Double, digitalVolume: Float, gainScale: Float = 1.0) -> [Float] {
    let gains = Self.fittedSectionGains(forPhon: phon, referencePhon: referencePhon, sampleRate: sampleRate)
    let scaledGains = gains.map { $0 * gainScale }
    let realized = Self.realizedResponseDB(sectionGains: scaledGains.map(Double.init), sampleRate: sampleRate)
    ...
    return scaledGains.map { $0 - Float(headroomToSubtract) }
}
```

### 2. ProcessTapControlling.swift & ProcessTapController.swift
Обновляем сигнатуру и хранение состояния:
```swift
protocol ProcessTapControlling {
    func updateLoudnessCompensation(volume: Float, enabled: Bool, referencePhon: Double, gainScale: Float)
}

final class ProcessTapController: ProcessTapControlling {
    private var _lastLoudnessGainScale: Float = 1.0

    func updateLoudnessCompensation(volume: Float, enabled: Bool, referencePhon: Double, gainScale: Float = 1.0) {
        _lastLoudnessVolume = volume
        _lastLoudnessReferencePhon = referencePhon
        _lastLoudnessGainScale = gainScale
        if enabled {
            loudnessCompensator?.updateForVolume(volume, digitalVolume: _volume, referencePhon: referencePhon, gainScale: gainScale)
            secondaryLoudnessCompensator?.updateForVolume(volume, digitalVolume: _volume, referencePhon: referencePhon, gainScale: gainScale)
        } else {
            loudnessCompensator?.setEnabled(false)
            secondaryLoudnessCompensator?.setEnabled(false)
        }
    }
}
```

### 3. AudioEngine.swift
Координируем плавный переход системной громкости и АЧХ фильтров:
```swift
private func updateTapsLoudness(deviceUID: String, enabled: Bool, referencePhon: Double, gainScale: Float) {
    for tap in taps.values {
        guard tap.currentDeviceUID == deviceUID else { continue }
        tap.updateLoudnessCompensation(
            volume: effectiveLoudnessVolume(for: tap),
            enabled: enabled,
            referencePhon: referencePhon,
            gainScale: gainScale
        )
    }
}

private func rampLoudnessCompensation(
    for deviceUID: String,
    deviceID: AudioDeviceID?,
    fromVolume: Float?,
    toVolume: Float?,
    enabling: Bool,
    referencePhon: Double
) {
    volumeRampTasks[deviceUID]?.cancel()
    
    let task = Task { @MainActor in
        let duration: TimeInterval = 0.300
        let stepInterval: TimeInterval = 0.030
        let steps = Int(duration / stepInterval)
        
        for step in 1...steps {
            guard !Task.isCancelled else { return }
            
            let progress = Float(step) / Float(steps)
            
            if let deviceID, let fromVol = fromVolume, let toVol = toVolume {
                let currentStepVolume = fromVol + (toVol - fromVol) * progress
                deviceVolumeMonitor.setVolume(for: deviceID, to: currentStepVolume)
            }
            
            let gainScale = enabling ? progress : (1.0 - progress)
            updateTapsLoudness(deviceUID: deviceUID, enabled: true, referencePhon: referencePhon, gainScale: gainScale)
            
            try? await Task.sleep(for: .milliseconds(30))
        }
        
        if !Task.isCancelled {
            if let deviceID, let toVol = toVolume {
                deviceVolumeMonitor.setVolume(for: deviceID, to: toVol)
            }
            
            let finalGainScale: Float = enabling ? 1.0 : 0.0
            updateTapsLoudness(deviceUID: deviceUID, enabled: enabling, referencePhon: referencePhon, gainScale: finalGainScale)
            
            volumeRampTasks.removeValue(forKey: deviceUID)
        }
    }
    volumeRampTasks[deviceUID] = task
}
```
