import Foundation

/// CoreAudio Bluetooth UIDs carry the device address, usually followed by :output.
/// Names are not identities: two paired headsets can have the same display name.
enum BluetoothOutputIdentity {
    static func matches(mac: String, device: AudioDevice) -> Bool {
        guard device.transportType == .bluetooth || device.transportType == .bluetoothLE else { return false }
        let address = mac.filter { $0.isHexDigit }.lowercased()
        guard address.count == 12 else { return false }
        let pattern = #"(?i)(?<![0-9a-f])(?:[0-9a-f]{2}[:-]){5}[0-9a-f]{2}(?![0-9a-f])|(?<![0-9a-f])[0-9a-f]{12}(?![0-9a-f])"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(device.uid.startIndex..<device.uid.endIndex, in: device.uid)
        return expression.matches(in: device.uid, range: range).contains { match in
            guard let range = Range(match.range, in: device.uid) else { return false }
            return device.uid[range].filter { $0.isHexDigit }.lowercased() == address
        }
    }
}
