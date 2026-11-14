// pattern: Functional Core

import Foundation

public enum DeviceConnectionState: String, Equatable, Sendable {
    case unauthorized
    case offline
    case device       // "device" == ready
    case recovering   // recovery mode — visible but not usable
    case noPermissions = "no permissions"
    case sideload
    case unknown
}

public struct DeviceEntry: Equatable, Sendable {
    public let serial: String
    public let state: DeviceConnectionState
    /// True for emulator serials (emulator-5554 style).
    public let isEmulator: Bool
    /// True for network transports (adb connect serials, host:port).
    public let isNetwork: Bool
    /// Properties from the -l long output (model:, product:, device:, transport_id:).
    public let properties: [String: String]

    public init(serial: String, state: DeviceConnectionState, isEmulator: Bool, isNetwork: Bool, properties: [String: String]) {
        self.serial = serial
        self.state = state
        self.isEmulator = isEmulator
        self.isNetwork = isNetwork
        self.properties = properties
    }

    /// USB candidate: ready and neither an emulator nor a network transport.
    public var isUsbCandidate: Bool {
        state == .device && !isEmulator && !isNetwork
    }

    public var displayName: String {
        let model = properties["model"]?.replacingOccurrences(of: "_", with: " ")
        if let model, !model.isEmpty { return "\(model) (\(serial))" }
        return serial
    }
}

public enum DeviceListParser {
    /// Parse the stdout of `adb devices -l`.
    public static func parse(_ text: String) -> [DeviceEntry] {
        var results: [DeviceEntry] = []
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, trimmed != "List of devices attached" else { continue }
            if trimmed.hasPrefix("*") { continue }
            let fields = trimmed.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 2 else { continue }
            let serial = String(fields[0])
            let stateToken = String(fields[1])
            var properties: [String: String] = [:]
            for field in fields.dropFirst(2) {
                let kv = field.split(separator: ":", maxSplits: 1)
                guard kv.count == 2 else { continue }
                properties[String(kv[0])] = String(kv[1])
            }
            results.append(DeviceEntry(
                serial: serial,
                state: parseState(stateToken),
                isEmulator: serial.hasPrefix("emulator-"),
                isNetwork: isNetworkSerial(serial),
                properties: properties
            ))
        }
        return results
    }

    static func parseState(_ token: String) -> DeviceConnectionState {
        switch token {
        case "device": return .device
        case "unauthorized": return .unauthorized
        case "offline": return .offline
        case "recovery": return .recovering
        case "sideload": return .sideload
        default:
            if token.hasPrefix("no permissions") { return .noPermissions }
            return .unknown
        }
    }

    /// adb network serials look like host:port (e.g. 192.168.1.5:5555).
    static func isNetworkSerial(_ serial: String) -> Bool {
        guard let colon = serial.lastIndex(of: ":") else { return false }
        let after = serial.index(after: colon)
        guard after < serial.endIndex else { return false }
        return serial[after...].allSatisfy(\.isNumber) && !serial[..<colon].isEmpty
    }

    /// Pick the single unambiguous USB candidate, or surface why not.
    public static func usbCandidate(_ devices: [DeviceEntry]) -> UsbCandidateSelection {
        let ready = devices.filter(\.isUsbCandidate)
        if ready.isEmpty {
            if let unauthorized = devices.first(where: { $0.state == .unauthorized }) {
                return .needsAuthorization(unauthorized)
            }
            if let offline = devices.first(where: { $0.state == .offline }) {
                return .disconnectedOrOffline(offline)
            }
            return .none
        }
        guard ready.count == 1 else { return .ambiguous(ready) }
        return .single(ready[0])
    }
}

public enum UsbCandidateSelection: Equatable, Sendable {
    case single(DeviceEntry)
    case ambiguous([DeviceEntry])
    case needsAuthorization(DeviceEntry)
    case disconnectedOrOffline(DeviceEntry)
    case none

    public var requiresUserChoice: Bool {
        if case .ambiguous = self { return true }
        return false
    }
}
