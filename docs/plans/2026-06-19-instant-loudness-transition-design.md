# Мгновенный переход при включении/выключении Loudness Compensation

Этот документ описывает дизайн переключения режима Loudness Compensator без использования плавного перехода (ramping).

## Проблема
Плавный переход громкости и АЧХ фильтров в течение 150-300 мс плохо работает на Bluetooth-наушниках и других беспроводных устройствах из-за задержек передачи команд регулировки громкости и перегрузки очереди драйверов. Это вызывает неприятные искажения звука и задержку применения компенсации.

## Решение
Мы полностью удаляем механизм плавного перехода громкости (ramping) и тембрального перехода.
1. При включении/выключении Loudness Compensation целевая громкость аппаратного устройства устанавливается мгновенно.
2. Коэффициент масштабирования тембра `gainScale` устанавливается мгновенно:
   - При включении: `enabled = true`, `gainScale = 1.0`
   - При выключении: `enabled = false`, `gainScale = 0.0`
3. Убираются асинхронные задачи перехода (`volumeRampTasks` и `rampLoudnessCompensation` в `AudioEngine.swift`).

## Изменения в коде

### 1. AudioEngine.swift
- Удаляем переменную `volumeRampTasks`.
- В `deinit` и `stop` удаляем очистку `volumeRampTasks`.
- Удаляем метод `rampLoudnessCompensation`.
- Изменяем `setLoudnessCompensationEnabled(for:enabled:)` для мгновенного выполнения регулировки громкости и обновления фильтров:
```swift
func setLoudnessCompensationEnabled(for deviceUID: String, enabled: Bool) {
    settingsManager.setLoudnessCompensationEnabled(for: deviceUID, to: enabled)
    let referencePhon = settingsManager.getLoudnessReferencePhon(for: deviceUID)
    
    if let device = deviceMonitor.device(for: deviceUID) {
        let b = outputVolumeBackend(for: device.id)
        if b == .hardware || b == .ddc {
            let currentVolume = deviceVolumeMonitor.volumes[device.id] ?? 1.0
            let targetVolume: Float
            if enabled {
                let offsetScalar: Float
                if let existing = appliedLoudnessOffsets[deviceUID] {
                    offsetScalar = existing
                } else {
                    let peakDB = computeHeadroomOffsetDB(for: deviceUID, systemVolume: currentVolume, referencePhon: referencePhon)
                    offsetScalar = Float(peakDB / 100.0)
                    appliedLoudnessOffsets[deviceUID] = offsetScalar
                }
                targetVolume = min(1.0, currentVolume + offsetScalar)
            } else {
                let offsetScalar = appliedLoudnessOffsets[deviceUID] ?? 0.0
                appliedLoudnessOffsets[deviceUID] = nil
                targetVolume = max(0.0, currentVolume - offsetScalar)
            }
            deviceVolumeMonitor.setVolume(for: device.id, to: targetVolume)
        }
    }
    
    let gainScale: Float = enabled ? 1.0 : 0.0
    updateTapsLoudness(deviceUID: deviceUID, enabled: enabled, referencePhon: referencePhon, gainScale: gainScale)
}
```

### 2. LoudnessVolumeCompensationTests.swift
- Обновляем тесты `togglingLoudnessAdjustsHardwareVolume` и `togglingLoudnessDoesNotAdjustSoftwareVolume`.
- Вместо ожидания окончания рампинга в цикле проверяем мгновенную реакцию громкости и коэффициента `gainScale` сразу после вызова `setLoudnessCompensationEnabled`.
