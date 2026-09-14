import Foundation

/// Connection state adb reports for a device.
enum AdbDeviceState: String, Sendable, Equatable {
    case device          // ready to use
    case unauthorized    // the USB debugging prompt has not been accepted
    case offline
    case authorizing
    case connecting
    case recovery
    case sideload
    case bootloader
    case rescue
    case host
    case noPermissions = "no permissions"
    case unknown

    init(raw: String) {
        let normalized = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if normalized.hasPrefix("no permissions") {
            self = .noPermissions
        } else {
            self = AdbDeviceState(rawValue: normalized) ?? .unknown
        }
    }

    /// Only a device in this state can accept a port forward.
    var isUsable: Bool { self == .device }
}

struct AdbDevice: Equatable, Sendable {
    var serial: String
    var state: AdbDeviceState
    var model: String?

    var displayName: String { model ?? serial }
}

/// Pure parsers for the adb output we depend on. Separated from process
/// handling so the formats can be unit tested.
enum AdbParsing {
    /// `adb forward tcp:0 tcp:41777` prints the local port it allocated.
    /// Some builds print nothing but a newline, and daemon chatter can be
    /// interleaved, so take the last line that is a plain port number.
    static func forwardedPort(from output: String) -> Int? {
        let candidates = output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        for line in candidates.reversed() {
            guard let port = Int(line), (1...65_535).contains(port) else { continue }
            return port
        }
        return nil
    }

    /// One snapshot from `adb track-devices`: lines of `serial<TAB>state`.
    ///
    /// Daemon messages ("* daemon not running…"), the `List of devices
    /// attached` header and blank lines are all ignored, and an optional
    /// four-hex-digit length prefix is stripped so the raw host service output
    /// parses too.
    static func parseDeviceList(_ block: String) -> [AdbDevice] {
        var devices: [AdbDevice] = []
        for rawLine in block.split(whereSeparator: \.isNewline) {
            let line = stripLengthPrefix(String(rawLine)).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            guard !line.hasPrefix("*") else { continue }
            guard !line.lowercased().hasPrefix("list of devices") else { continue }
            guard !line.lowercased().hasPrefix("adb server") else { continue }

            let fields = line.split(whereSeparator: { $0 == "\t" || $0 == " " })
                .map { String($0) }
                .filter { !$0.isEmpty }
            guard fields.count >= 2 else { continue }
            let serial = fields[0]
            // `no permissions` and similar states span several words, and
            // `devices -l` appends key:value pairs we want to skip.
            let stateWords = fields.dropFirst().prefix { !$0.contains(":") }
            let state = AdbDeviceState(raw: stateWords.joined(separator: " "))
            let model = fields.dropFirst().first { $0.hasPrefix("model:") }?
                .replacingOccurrences(of: "model:", with: "")
                .replacingOccurrences(of: "_", with: " ")
            devices.append(AdbDevice(serial: serial, state: state, model: model?.isEmpty == false ? model : nil))
        }
        return devices
    }

    /// Split a streamed `track-devices` buffer into complete snapshots.
    ///
    /// The command line tool separates snapshots with a blank line. Consumed
    /// bytes are removed from `buffer`; an incomplete trailing snapshot stays.
    static func takeSnapshots(from buffer: inout String) -> [[AdbDevice]] {
        var snapshots: [[AdbDevice]] = []
        while let range = buffer.range(of: "\n\n") {
            let block = String(buffer[buffer.startIndex..<range.lowerBound])
            buffer.removeSubrange(buffer.startIndex..<range.upperBound)
            snapshots.append(parseDeviceList(block))
        }
        return snapshots
    }

    /// Strip the four-hex-digit length prefix the adb host service uses, when
    /// one is present.
    static func stripLengthPrefix(_ line: String) -> String {
        guard line.count > 4 else { return line }
        let prefix = line.prefix(4)
        guard prefix.allSatisfy({ $0.isHexDigit }),
              Int(prefix, radix: 16) != nil,
              // A serial number can easily start with four hex digits, so only
              // treat it as a prefix when what follows looks like a device line.
              line.dropFirst(4).contains("\t") else { return line }
        return String(line.dropFirst(4))
    }

    /// `adb shell getprop ro.product.model` output, trimmed.
    static func model(from output: String) -> String? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
