import XCTest
import QuartzCore
@testable import Tauross

/// Opt-in A/B measurement. Both cases use the current recorder; only capture
/// topology changes, isolating the cost of the old second encoder/decoder.
final class RecordingPerformanceTests: XCTestCase {
    func testDualVersusSharedCapture() async throws {
        guard ProcessInfo.processInfo.environment["TAUROSS_PROFILE_RECORDING"] == "1",
              let serial = ProcessInfo.processInfo.environment["TAUROSS_TEST_DEVICE"] else {
            throw XCTSkip("Set TAUROSS_PROFILE_RECORDING=1 and TAUROSS_TEST_DEVICE for the emulator A/B measurement.")
        }
        let devices = try await ADBService.devices()
        let device = try XCTUnwrap(devices.first { $0.id == serial })
        var stream = StreamOptions()
        stream.maxSize = 1920; stream.maxFPS = 60; stream.bitRate = 12
        var recording = RecordingOptions()
        recording.maxSize = 720; recording.fps = 60; recording.bitRate = 16; recording.codec = .hevc
        for shared in [false, true] {
            let label = shared ? "shared" : "dual"
            let mirrorSurface = VideoSurface()
            let recordSurface = shared ? mirrorSurface : VideoSurface()
            let session = AndroidSession(surface: mirrorSurface) { XCTFail($0) }
            let capture: AndroidSession? = shared ? nil : AndroidSession(surface: recordSurface) { XCTFail($0) }
            defer { session.stop(); capture?.stop() }
            session.start(device: device, options: shared ? recording.androidCapture(sharing: stream) : stream)
            let ready = Date().addingTimeInterval(20)
            while mirrorSurface.metrics().1 == 0 && Date() < ready { try await Task.sleep(for: .milliseconds(100)) }
            if let capture {
                var options = stream
                options.maxSize = recording.maxSize; options.maxFPS = recording.fps; options.bitRate = recording.bitRate
                options.control = false; options.stayAwake = false
                capture.start(device: device, options: options)
                let ready = Date().addingTimeInterval(20)
                while recordSurface.metrics().1 == 0 && Date() < ready { try await Task.sleep(for: .milliseconds(100)) }
            }
            XCTAssertGreaterThan(recordSurface.metrics().1, 0)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("tauross-profile-\(UUID()).mp4")
            defer { try? FileManager.default.removeItem(at: url) }
            let started = expectation(description: label)
            let recorder = VideoRecorder(surface: recordSurface, options: recording, url: url,
                                         onStarted: { started.fulfill() }, onFailure: { XCTFail($0) })
            recorder.start()
            await fulfillment(of: [started], timeout: 10)
            session.key(3)
            try await Task.sleep(for: .seconds(1))
            let initialCount = mirrorSurface.metrics().1
            let first = try XCTUnwrap(mirrorSurface.snapshot(after: -1))
            let start = CACurrentMediaTime()
            var nextInput = start
            var recent = true
            var previousSequence = first.sequence
            var previousPublished = first.publishedAt
            var gaps: [Double] = []
            while CACurrentMediaTime() - start < 8 {
                if CACurrentMediaTime() >= nextInput {
                    session.key(recent ? 187 : 3)
                    recent.toggle()
                    nextInput += 0.65
                }
                if let frame = mirrorSurface.snapshot(after: previousSequence) {
                    gaps.append(frame.publishedAt - previousPublished)
                    previousPublished = frame.publishedAt; previousSequence = frame.sequence
                }
                try await Task.sleep(for: .milliseconds(8))
            }
            let elapsed = CACurrentMediaTime() - start
            let frames = mirrorSurface.metrics().1 - initialCount
            let last = try XCTUnwrap(mirrorSurface.snapshot(after: -1))
            let drift = (last.publishedAt - first.publishedAt) - ((last.sourceTime ?? 0) - (first.sourceTime ?? 0))
            let metrics = await recorder.metrics()
            let saved: URL? = try await withCheckedThrowingContinuation { continuation in
                recorder.finish { continuation.resume(with: $0) }
            }
            XCTAssertNotNil(saved)
            gaps.sort()
            let p95 = gaps.isEmpty ? 0 : gaps[min(gaps.count - 1, Int(Double(gaps.count) * 0.95))] * 1000
            print(String(format: "RECORDING_PROFILE %@ decodedFPS=%.1f frameGapP95Ms=%.1f sourceLagGrowthMs=%.1f encodedFrames=%d renderedFrames=%d backpressure=%d meanProcessingMs=%.2f",
                         label, Double(frames) / elapsed, p95, drift * 1000, metrics.encodedFrames, metrics.renderedFrames,
                         metrics.encoderBackpressure, metrics.processingSeconds * 1000 / Double(max(1, metrics.encodedFrames))))
            session.key(3)
            session.stop(); capture?.stop()
            try await Task.sleep(for: .seconds(1))
        }
    }
}
