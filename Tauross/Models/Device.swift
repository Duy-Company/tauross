import Foundation

enum DevicePlatform: String, CaseIterable, Identifiable {
    case android = "Android", ios = "iOS"
    var id: String { rawValue }
    var symbol: String { self == .android ? "apps.iphone" : "iphone" }
}

struct MirrorDevice: Identifiable, Equatable {
    let id: String
    let name: String
    let platform: DevicePlatform
    let connection: String
    let state: String
    var isReady: Bool { state == "device" }
    var stateLabel: String {
        switch state {
        case "device": return "Ready"
        case "unauthorized": return "Allow USB debugging on the device"
        case "offline": return "Offline"
        default: return state
        }
    }

    static func parseADB(_ output: String) -> [MirrorDevice] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count >= 2, ["device", "unauthorized", "offline", "recovery", "sideload", "no"].contains(fields[1]) else { return nil }
            let serial = fields[0]
            let model = fields.first(where: { $0.hasPrefix("model:") }).map { String($0.dropFirst(6)).replacingOccurrences(of: "_", with: " ") }
            let transport = serial.hasPrefix("emulator-") ? "Emulator" : (serial.contains(":") || serial.contains("_adb-tls-") ? "Wi-Fi" : "USB")
            return MirrorDevice(id: serial, name: model ?? serial, platform: .android, connection: transport, state: fields[1])
        }
    }
}

struct StreamOptions: Equatable {
    var maxSize = 1920
    var maxFPS = 60
    var bitRate = 8
    var control = true
    var stayAwake = true
    var showTouches = false

    var serverArguments: [String] {
        ["video_codec=h264", "audio=false", "max_size=\(maxSize)", "max_fps=\(maxFPS)",
         "video_bit_rate=\(bitRate * 1_000_000)", "control=\(control)", "stay_awake=\(stayAwake)",
         "show_touches=\(showTouches)", "clipboard_autosync=false", "tunnel_forward=true", "log_level=info"]
    }
}

struct NetworkEndpoint {
    static func validate(_ text: String) throws -> String {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Explicit host:port only; never interpreted by a shell.
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty,
              parts[0].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }),
              !parts[0].hasPrefix("-"), let port = Int(parts[1]), (1...65535).contains(port) else {
            throw TaurossError.message("Enter an address such as 192.168.1.20:37123 or device.local:37123.")
        }
        return value
    }
}

enum TaurossError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
