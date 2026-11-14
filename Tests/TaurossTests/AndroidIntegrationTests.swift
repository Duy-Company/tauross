import XCTest
import AVFoundation
@testable import Tauross

final class AndroidIntegrationTests: XCTestCase {
    func testReconfiguringCaptureStopsThePreviousDeviceEncoder() async throws {
        guard let serial = ProcessInfo.processInfo.environment["TAUROSS_TEST_DEVICE"] else {
            throw XCTSkip("Set TAUROSS_TEST_DEVICE for capture reconfiguration testing.")
        }
        let devices = try await ADBService.devices()
        let device = try XCTUnwrap(devices.first { $0.id == serial })
        func encoderCount() async throws -> Int {
            let processes = try await ADBService.run(["-s", serial, "shell", "ps", "-A", "-o", "ARGS"])
            return processes.split(separator: "\n").filter {
                $0.trimmingCharacters(in: .whitespaces).hasPrefix("app_process / com.genymobile.scrcpy.Server ")
            }.count
        }
        let baseline = try await encoderCount()
        var previous: AndroidSession?
        defer { previous?.stop() }
        for size in [720, 1280, 720] {
            let surface = VideoSurface()
            let session = AndroidSession(surface: surface) { XCTFail($0) }
            var options = StreamOptions()
            options.maxSize = size
            session.start(device: device, options: options, afterStopping: previous)
            previous = session
            let deadline = Date().addingTimeInterval(20)
            while surface.metrics().1 == 0 && Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
            XCTAssertGreaterThan(surface.metrics().1, 0)
            let count = try await encoderCount()
            XCTAssertEqual(count, baseline + 1, "Quality changes must replace the encoder instead of adding another one")
        }
        previous?.stop()
        // Let the last server release its encoder before other integration tests run.
        let deadline = Date().addingTimeInterval(10)
        while try await encoderCount() > baseline && Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
    }

    func testSharedCaptureRecordsHigherAndLowerResolutionThanMirror() async throws {
        guard let serial = ProcessInfo.processInfo.environment["TAUROSS_TEST_DEVICE"] else {
            throw XCTSkip("Set TAUROSS_TEST_DEVICE for real recording testing.")
        }
        let devices = try await ADBService.devices()
        let device = try XCTUnwrap(devices.first { $0.id == serial })
        for (mirrorSize, recordSize) in [(720, 1280), (1280, 720)] {
            let source = VideoSurface()
            var stream = StreamOptions()
            stream.maxSize = mirrorSize; stream.bitRate = 2
            var options = RecordingOptions()
            options.maxSize = recordSize; options.bitRate = 8; options.codec = .hevc
            let session = AndroidSession(surface: source) { XCTFail($0) }
            defer { session.stop() }
            session.start(device: device, options: options.androidCapture(sharing: stream))
            let deadline = Date().addingTimeInterval(20)
            while source.metrics().1 == 0 && Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
            XCTAssertGreaterThan(source.metrics().1, 0)
            let sourceSize = source.metrics().0
            XCTAssertGreaterThan(max(sourceSize.width, sourceSize.height), 720)

            let url = FileManager.default.temporaryDirectory.appendingPathComponent("tauross-android-\(UUID()).mp4")
            defer { try? FileManager.default.removeItem(at: url) }
            let started = expectation(description: "Shared recorder started")
            let recorder = VideoRecorder(surface: source, options: options, url: url,
                                         onStarted: { started.fulfill() }, onFailure: { XCTFail($0) })
            recorder.start()
            await fulfillment(of: [started], timeout: 10)
            session.key(187)
            try await Task.sleep(for: .milliseconds(700))
            let saved: URL? = try await withCheckedThrowingContinuation { continuation in
                recorder.finish { continuation.resume(with: $0) }
            }
            XCTAssertEqual(saved, url)
            let asset = AVURLAsset(url: url)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            let track = try XCTUnwrap(tracks.first)
            let size = try await track.load(.naturalSize)
            XCTAssertEqual(size, options.outputSize(for: sourceSize))
            let duration = try await asset.load(.duration)
            XCTAssertGreaterThan(CMTimeGetSeconds(duration), 0.6)
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            reader.add(output)
            XCTAssertTrue(reader.startReading())
            XCTAssertNotNil(output.copyNextSampleBuffer())
            reader.cancelReading()
            let count = source.metrics().1
            session.key(3)
            try await Task.sleep(for: .seconds(1))
            XCTAssertGreaterThan(source.metrics().1, count, "Stopping recording must leave mirror/control working")
        }
    }

    func testRealAndroidStreamAndControl() async throws {
        guard let serial = ProcessInfo.processInfo.environment["TAUROSS_TEST_DEVICE"] else {
            throw XCTSkip("Set TAUROSS_TEST_DEVICE to an authorized Android serial for real stream testing.")
        }
        let devices = try await ADBService.devices()
        let device = try XCTUnwrap(devices.first { $0.id == serial })
        let surface = VideoSurface()
        let failure = expectation(description: "No stream failure")
        failure.isInverted = true
        let session = AndroidSession(surface: surface) { message in
            XCTFail(message); failure.fulfill()
        }
        defer { session.stop() }
        session.start(device: device, options: StreamOptions())
        let deadline = Date().addingTimeInterval(20)
        while surface.metrics().1 < 3 && Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
        let metrics = surface.metrics()
        XCTAssertGreaterThan(metrics.1, 2, "Must decode real frames, not just open the socket")
        XCTAssertGreaterThan(metrics.0.width, 100)
        XCTAssertGreaterThan(metrics.0.height, 100)
        session.key(3)
        session.key(187)
        try await Task.sleep(for: .seconds(1))
        XCTAssertGreaterThan(surface.metrics().1, metrics.1, "Control must trigger visible frame changes")
        session.stop()
        await fulfillment(of: [failure], timeout: 1)
    }
}
