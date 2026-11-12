import Foundation

enum BundledTools {
    static var resourceRoot: URL {
        #if SWIFT_PACKAGE
        return Bundle.module.bundleURL.appendingPathComponent("Resources")
        #else
        return Bundle.main.resourceURL!.appendingPathComponent("Resources")
        #endif
    }
    static func url(_ name: String) throws -> URL {
        let url = resourceRoot.appendingPathComponent("Tools/\(name)")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw TaurossError.message("Missing bundled resource: \(name). Rebuild using Scripts/build.sh.")
        }
        return url
    }
}

enum ADBService {
    static func process(_ arguments: [String]) throws -> Process {
        let process = Process()
        process.executableURL = try BundledTools.url("adb")
        process.arguments = arguments
        return process
    }

    /// Runs off the main thread. Output is drained while running so large output cannot fill the pipe.
    static func runSync(_ arguments: [String], timeout: TimeInterval = 15) throws -> String {
        let process = try process(arguments)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        deadline.cancel()
        let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            throw TaurossError.message(output.isEmpty ? "ADB did not respond or the request timed out." : output)
        }
        return output
    }

    static func run(_ arguments: [String], timeout: TimeInterval = 15) async throws -> String {
        try await Task.detached { try runSync(arguments, timeout: timeout) }.value
    }

    static func devices() async throws -> [MirrorDevice] {
        MirrorDevice.parseADB(try await run(["devices", "-l"]))
    }

    static func connect(_ endpoint: String) async throws -> String {
        let result = try await run(["connect", NetworkEndpoint.validate(endpoint)])
        guard result.contains("connected to") else { throw TaurossError.message(result) }
        return result
    }

    static func pair(_ endpoint: String, code: String) async throws -> String {
        guard code.count == 6, code.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            throw TaurossError.message("Enter the 6-digit pairing code from Wireless debugging on Android.")
        }
        let result = try await run(["pair", NetworkEndpoint.validate(endpoint), code], timeout: 30)
        guard result.contains("Successfully paired") else { throw TaurossError.message(result) }
        return "Paired. Connect using the separate connection port on the main Wireless debugging screen."
    }
}
