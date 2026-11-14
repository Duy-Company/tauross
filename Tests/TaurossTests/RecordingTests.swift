import XCTest
import AVFoundation
import CoreImage
@testable import Tauross

final class RecordingTests: XCTestCase {
    func testRecordingResolutionPreservesAspectAndNeverUpscales() {
        var options = RecordingOptions()
        options.maxSize = 1280
        XCTAssertEqual(options.outputSize(for: CGSize(width: 1080, height: 2400)), CGSize(width: 576, height: 1280))
        XCTAssertEqual(options.outputSize(for: CGSize(width: 640, height: 480)), CGSize(width: 640, height: 480))
        options.maxSize = 0
        XCTAssertEqual(options.outputSize(for: CGSize(width: 1179, height: 2556)), CGSize(width: 1178, height: 2556))
    }

    func testSharedCaptureCoversBothQualitiesWithoutChangingDeviceControls() {
        var stream = StreamOptions()
        stream.maxSize = 720; stream.maxFPS = 60; stream.bitRate = 4
        var options = RecordingOptions()
        options.maxSize = 1920; options.fps = 30; options.bitRate = 12
        let capture = options.androidCapture(sharing: stream)
        XCTAssertEqual(capture.maxSize, 1920)
        XCTAssertEqual(capture.maxFPS, 60)
        XCTAssertEqual(capture.bitRate, 12)
        XCTAssertEqual(capture.control, stream.control)
        XCTAssertEqual(capture.stayAwake, stream.stayAwake)
        options.maxSize = 0
        XCTAssertEqual(options.androidCapture(sharing: stream).maxSize, 0)
        options.maxSize = 720; stream.maxSize = 0
        XCTAssertEqual(options.androidCapture(sharing: stream).maxSize, 0)
    }

    func testStaticScreenRecordingIsPlayableAndSurvivesOrientationChange() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tauross-recording-\(UUID()).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        let surface = VideoSurface()
        surface.publish(try frame(width: 480, height: 800))
        var options = RecordingOptions()
        options.maxSize = 720; options.fps = 24; options.bitRate = 2
        let started = expectation(description: "First recorded frame")
        let recorder = VideoRecorder(surface: surface, options: options, url: url, onStarted: { started.fulfill() },
                                     onFailure: { XCTFail($0) })
        recorder.start()
        await fulfillment(of: [started], timeout: 10)
        try await Task.sleep(for: .milliseconds(300))
        surface.publish(try frame(width: 800, height: 480))
        try await Task.sleep(for: .milliseconds(350))
        let metrics = await recorder.metrics()
        XCTAssertEqual(metrics.encodedFrames, 2, "Unchanged source frames must not be repeatedly encoded")
        let saved = try await finish(recorder)
        XCTAssertEqual(saved, url)
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        XCTAssertGreaterThan(CMTimeGetSeconds(duration), 0.6)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let size = try await track.load(.naturalSize)
        XCTAssertEqual(size, CGSize(width: 432, height: 720))

        // Decode the actual MP4, including frames after the orientation change.
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var count = 0
        var previous = CMTime.invalid
        while let sample = output.copyNextSampleBuffer() {
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            if previous.isValid { XCTAssertGreaterThan(CMTimeCompare(pts, previous), 0) }
            XCTAssertNotNil(CMSampleBufferGetImageBuffer(sample))
            previous = pts; count += 1
        }
        XCTAssertEqual(reader.status, .completed)
        XCTAssertEqual(count, 3, "Two source images plus the final held frame preserve the complete timeline")
    }

    func testCancelBeforeFirstFrameDoesNotLeaveAnEmptyMovie() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tauross-cancel-\(UUID()).mp4")
        let recorder = VideoRecorder(surface: VideoSurface(), options: RecordingOptions(), url: url,
                                     onStarted: { XCTFail("No source frame") }, onFailure: { XCTFail($0) })
        recorder.start()
        let saved = try await finish(recorder)
        XCTAssertNil(saved)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testBothCodecsInBothContainersProduceDecodableVideo() async throws {
        for codec in RecordingCodec.allCases {
            for container in RecordingContainer.allCases {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("tauross-\(UUID()).\(container.rawValue)")
                defer { try? FileManager.default.removeItem(at: url) }
                var options = RecordingOptions()
                options.codec = codec; options.container = container; options.bitRate = 2
                let source = VideoSurface()
                source.publish(try frame(width: 320, height: 240))
                let started = expectation(description: "\(codec) in \(container)")
                let recorder = VideoRecorder(surface: source, options: options, url: url,
                                             onStarted: { started.fulfill() }, onFailure: { XCTFail($0) })
                recorder.start()
                await fulfillment(of: [started], timeout: 10)
                try await Task.sleep(for: .milliseconds(200))
                let metrics = await recorder.metrics()
                XCTAssertEqual(metrics.encodedFrames, 1)
                XCTAssertEqual(metrics.renderedFrames, 0, "Matching size should append the capture buffer directly")
                _ = try await finish(recorder)
                let asset = AVURLAsset(url: url)
                let tracks = try await asset.loadTracks(withMediaType: .video)
                let track = try XCTUnwrap(tracks.first)
                let descriptions = try await track.load(.formatDescriptions)
                let format = try XCTUnwrap(descriptions.first)
                XCTAssertEqual(CMFormatDescriptionGetMediaSubType(format), codec == .h264 ? kCMVideoCodecType_H264 : kCMVideoCodecType_HEVC)
                let reader = try AVAssetReader(asset: asset)
                let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
                reader.add(output)
                XCTAssertTrue(reader.startReading())
                let sample = try XCTUnwrap(output.copyNextSampleBuffer())
                XCTAssertNotNil(CMSampleBufferGetImageBuffer(sample))
                reader.cancelReading()
            }
        }
    }

    private func frame(width: Int, height: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                       [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        XCTAssertEqual(status, kCVReturnSuccess)
        let image = try XCTUnwrap(buffer)
        CIContext().render(CIImage(color: CIColor(red: 0.2, green: 0.6, blue: 0.3)), to: image,
                           bounds: CGRect(x: 0, y: 0, width: width, height: height), colorSpace: CGColorSpaceCreateDeviceRGB())
        return image
    }

    private func finish(_ recorder: VideoRecorder) async throws -> URL? {
        try await withCheckedThrowingContinuation { continuation in
            recorder.finish { continuation.resume(with: $0) }
        }
    }
}
