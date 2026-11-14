import Foundation
import CoreGraphics
import AVFoundation

enum RecordingCodec: String, Codable, CaseIterable, Identifiable {
    case h264, hevc
    var id: String { rawValue }
    var label: String { self == .h264 ? "H.264 (Compatible)" : "HEVC / H.265 (Efficient)" }
    var avCodec: AVVideoCodecType { self == .h264 ? .h264 : .hevc }
}

enum RecordingContainer: String, Codable, CaseIterable, Identifiable {
    case mp4, mov
    var id: String { rawValue }
    var label: String { rawValue.uppercased() }
    var fileType: AVFileType { self == .mp4 ? .mp4 : .mov }
}

struct RecordingOptions: Codable, Equatable {
    var maxSize = 1920
    var fps = 30
    var bitRate = 12
    var codec: RecordingCodec = .h264
    var container: RecordingContainer = .mp4

    static let resolutions = [0, 3840, 2560, 1920, 1280, 720]
    static let frameRates = [24, 30, 60]
    static let bitRates = [2, 4, 6, 8, 12, 16, 24, 40, 60]

    var estimatedMBPerMinute: Int { bitRate * 60 / 8 }

    func outputSize(for source: CGSize) -> CGSize {
        let scale = maxSize == 0 ? 1 : min(1, CGFloat(maxSize) / max(source.width, source.height))
        // H.264 requires even dimensions. Never upscale the capture source.
        return CGSize(width: max(2, floor(source.width * scale / 2) * 2),
                      height: max(2, floor(source.height * scale / 2) * 2))
    }

    func androidCapture(sharing stream: StreamOptions) -> StreamOptions {
        var capture = stream
        capture.maxSize = stream.maxSize == 0 || maxSize == 0 ? 0 : max(stream.maxSize, maxSize)
        capture.maxFPS = max(stream.maxFPS, fps)
        capture.bitRate = max(stream.bitRate, bitRate)
        return capture
    }

    static func load(for platform: DevicePlatform, defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: key(platform)),
              let options = try? JSONDecoder().decode(Self.self, from: data),
              resolutions.contains(options.maxSize), frameRates.contains(options.fps), bitRates.contains(options.bitRate)
        else { return Self() }
        return options
    }

    func save(for platform: DevicePlatform, defaults: UserDefaults = .standard) {
        defaults.set(try? JSONEncoder().encode(self), forKey: Self.key(platform))
    }

    private static func key(_ platform: DevicePlatform) -> String { "recording.\(platform.rawValue)" }
}

enum CaptureStorage {
    static var root: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".tauross", isDirectory: true) }

    static func destination(kind: String, platform: DevicePlatform, extension suffix: String) throws -> URL {
        let directory = root.appendingPathComponent(kind, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = Date().formatted(.iso8601).replacingOccurrences(of: ":", with: "-")
        return directory.appendingPathComponent("\(platform.rawValue)-\(stamp)-\(UUID().uuidString.prefix(8)).\(suffix)")
    }
}
