# Дизайн динамической компенсации оффсета громкости (Headroom Offset)

Этот документ описывает дизайн динамического расчета оффсета громкости для функции Loudness Compensation, предотвращающего снижение громкости и нежелательную эквализацию на 100% системной громкости macOS.

## Проблема
В текущей реализации при включении Loudness Compensation рассчитывается статический оффсет громкости (`appliedLoudnessOffsets`), компенсирующий снижение уровня (headroom) в DSP.
Если пользователь включает тонкомпенсацию на средней громкости (например, 50%), оффсет сохраняется как константа (например, 0.08 или 8% громкости). При ручном увеличении системной громкости до 100% этот оффсет продолжает вычитаться. DSP считает, что реальная громкость равна 92%, из-за чего:
1. Звук окрашивается эквализацией (так как DSP думает, что уровень прослушивания ниже опорного).
2. Общая громкость занижается на величину headroom (~8 дБ), и пользователь не может получить максимальную громкость от устройства.

На 100% громкости при опорном уровне АЧХ должна быть абсолютно плоской (bypassed), а оффсет равен 0.

## Решение
Сделать оффсет громкости динамическим. При изменении громкости ползунком системы или при нажатии медиаклавиш оффсет должен пересчитываться в реальном времени.

Для связи физической громкости $V_{hw}$ (получаемой от OS) и оригинальной пользовательской громкости $V_{user}$ (задаваемой пользователем) используется формула:
$$V_{hw} = V_{user} + \text{offset}(V_{user})$$

Где $\text{offset}(V_{user})$ рассчитывается через пиковый подъем фильтра:
$$\text{offset}(V_{user}) = \frac{\text{peakDB}(V_{user})}{100.0}$$

Поскольку $\text{offset}$ зависит от $V_{user}$, мы находим $V_{user}$ численно за 3 итерации:
```swift
var originalVolume = newVolume
var currentOffset: Float = 0.0
for _ in 0..<3 {
    originalVolume = max(0.0, min(1.0, newVolume - currentOffset))
    let peakDB = computeHeadroomOffsetDB(for: deviceUID, systemVolume: originalVolume, referencePhon: referencePhon)
    currentOffset = Float(peakDB / 100.0)
}
```

При $newVolume = 1.0$ (100% системная громкость) оригинальная громкость сойдется к 1.0, а оффсет к 0.0, так как на опорном уровне `peakDB = 0.0`.

## Изменения в коде

### 1. [AudioEngine.swift](file:///Users/air/develop/FineTuneFork/FineTune/Audio/Engine/AudioEngine.swift)

#### В callback `deviceVolumeMonitor.onVolumeChanged`:
Обновляем расчет оффсета перед рассылкой по тапам:
```swift
deviceVolumeMonitor.onVolumeChanged = { [weak self] deviceID, newVolume in
    guard let self else { return }
    guard let deviceUID = self.deviceMonitor.outputDevices.first(where: { $0.id == deviceID })?.uid else { return }
    let loudnessEnabled = self.settingsManager.getLoudnessCompensationEnabled(for: deviceUID)
    
    if loudnessEnabled {
        let referencePhon = self.settingsManager.getLoudnessReferencePhon(for: deviceUID)
        var originalVolume = newVolume
        var currentOffset: Float = 0.0
        for _ in 0..<3 {
            originalVolume = max(0.0, min(1.0, newVolume - currentOffset))
            let peakDB = self.computeHeadroomOffsetDB(for: deviceUID, systemVolume: originalVolume, referencePhon: referencePhon)
            currentOffset = Float(peakDB / 100.0)
        }
        self.appliedLoudnessOffsets[deviceUID] = currentOffset
    }
    
    // ... дальнейшая рассылка tap.updateLoudnessCompensation
}
```

#### В методе `setLoudnessReferencePhon(for:to:)`:
Пересчитываем оффсет при изменении опорного уровня (так как АЧХ и headroom меняются):
```swift
func setLoudnessReferencePhon(for deviceUID: String, to referencePhon: Double) {
    settingsManager.setLoudnessReferencePhon(for: deviceUID, to: referencePhon)
    let enabled = settingsManager.getLoudnessCompensationEnabled(for: deviceUID)
    
    if enabled, let device = deviceMonitor.device(for: deviceUID) {
        let currentVolume = deviceVolumeMonitor.volumes[device.id] ?? 1.0
        var originalVolume = currentVolume
        var currentOffset: Float = 0.0
        for _ in 0..<3 {
            originalVolume = max(0.0, min(1.0, currentVolume - currentOffset))
            let peakDB = computeHeadroomOffsetDB(for: deviceUID, systemVolume: originalVolume, referencePhon: referencePhon)
            currentOffset = Float(peakDB / 100.0)
        }
        appliedLoudnessOffsets[deviceUID] = currentOffset
    }
    
    // ... рассылка по тапам
}
```

## Верификация
1. Тест-сьют `FineTuneTests` (сборка и прохождение всех тестов).
2. Ручная проверка:
   - Включить Loudness на 50% громкости.
   - Поднять громкость до 100%. Убедиться, что на 100% звук идентичен выключенному Loudness (нет просадки громкости и тембральной коррекции).
