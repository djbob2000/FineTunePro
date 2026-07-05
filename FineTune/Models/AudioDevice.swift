// FineTune/Models/AudioDevice.swift
import AppKit
import AudioToolbox

struct AudioDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let icon: NSImage?
    let supportsAutoEQ: Bool
    let transportType: TransportType

    init(
        id: AudioDeviceID,
        uid: String,
        name: String,
        icon: NSImage?,
        supportsAutoEQ: Bool,
        transportType: TransportType = .unknown
    ) {
        self.id = id
        self.uid = uid
        self.name = name
        self.icon = icon
        self.supportsAutoEQ = supportsAutoEQ
        self.transportType = transportType
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(uid)
    }

    static func == (lhs: AudioDevice, rhs: AudioDevice) -> Bool {
        lhs.uid == rhs.uid
    }
}
