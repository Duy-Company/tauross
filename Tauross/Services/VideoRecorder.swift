import AVFoundation
import CoreImage
import QuartzCore

struct RecordingMetrics {
    var encodedFrames = 0
    var renderedFrames = 0
    var encoderBackpressure = 0
    var processingSeconds = 0.0
}

/// A bounded, serial pipeline shared by Android and iOS. Encode new source frames
/// at most at the requested rate, with timestamps assigned before rendering.
final class VideoRecorder: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.tauross.recording", qos: .userInitiated)
    private lazy var context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    private let surface: VideoSurface
    private let options: RecordingOptions
    private let url: URL
    private let onStarted: @Sendable () -> Void
    private let onFailure: @Sendable (String) -> Void
    private var timer: DispatchSourceTimer?
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var canvas = CGSize.zero
    private var requestedAt = CACurrentMediaTime()
    private var startedAt: CFTimeInterval?
    private var lastPTS = CMTime.invalid
    private var lastSequence = -1
    private var lastBuffer: CVPixelBuffer?
    private var statistics = RecordingMetrics()
    private var terminalError: String?
    private var finished = false
    private var finalizedInput = false

    init(surface: VideoSurface, options: RecordingOptions, url: URL,
         onStarted: @escaping @Sendable () -> Void, onFailure: @escaping @Sendable (String) -> Void) {
        self.surface = surface; self.options = options; self.url = url
        self.onStarted = onStarted; self.onFailure = onFailure
    }

    func start() {
        queue.async { [self] in
            guard !finished else { return }
            requestedAt = CACurrentMediaTime()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .nanoseconds(1_000_000_000 / options.fps), leeway: .milliseconds(2))
            timer.setEventHandler { [weak self] in
                autoreleasepool { self?.tick() }
            }
            self.timer = timer
            timer.resume()
        }
    }

    func metrics() async -> RecordingMetrics {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.statistics) }
        }
    }

    private func configure(for image: CVPixelBuffer) throws {
        canvas = options.outputSize(for: CGSize(width: CVPixelBufferGetWidth(image), height: CVPixelBufferGetHeight(image)))
        let writer = try AVAssetWriter(outputURL: url, fileType: options.container.fileType)
        let settings: [String: Any] = [
            AVVideoCodecKey: options.codec.avCodec,
            AVVideoWidthKey: Int(canvas.width), AVVideoHeightKey: Int(canvas.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: options.bitRate * 1_000_000,
                AVVideoExpectedSourceFrameRateKey: options.fps,
                AVVideoMaxKeyFrameIntervalKey: options.fps * 2,
                AVVideoAllowFrameReorderingKey: false
            ]
        ]
        guard writer.canApply(outputSettings: settings, forMediaType: .video) else {
            throw TaurossError.message("This Mac cannot encode the selected recording format or quality. Try H.264, a lower resolution, or a lower bitrate.")
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(canvas.width),
            kCVPixelBufferHeightKey as String: Int(canvas.height),
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ])
        guard writer.canAdd(input) else { throw TaurossError.message("Unable to create the recording video track.") }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? TaurossError.message("Unable to start video recording.") }
        writer.startSession(atSourceTime: .zero)
        self.writer = writer; self.input = input; self.adaptor = adaptor
    }

    private func tick() {
        guard !finished, terminalError == nil else { return }
        do {
            guard let frame = surface.snapshot(after: lastSequence) else {
                if writer == nil && CACurrentMediaTime() - requestedAt > 25 {
                    throw TaurossError.message("No video received for recording. Try a lower recording resolution or check the device connection.")
                }
                return
            }
            let image = frame.image
            if writer == nil { try configure(for: image) }
            guard let writer, let input, let adaptor else { return }
            guard writer.status == .writing else { throw writer.error ?? TaurossError.message("Video recording stopped unexpectedly.") }
            guard input.isReadyForMoreMediaData else { statistics.encoderBackpressure += 1; return }
            let processingStarted = CACurrentMediaTime()
            let origin = startedAt ?? max(requestedAt, frame.publishedAt)
            let pts = CMTime(seconds: max(0, frame.publishedAt - origin), preferredTimescale: 60_000)
            guard !lastPTS.isValid || CMTimeCompare(pts, lastPTS) > 0 else { return }
            let destination: CVPixelBuffer
            if CVPixelBufferGetWidth(image) == Int(canvas.width), CVPixelBufferGetHeight(image) == Int(canvas.height) {
                // Retain the decoder/capture buffer directly; no GPU render or pixel copy.
                destination = image
            } else {
                guard let pool = adaptor.pixelBufferPool else { throw TaurossError.message("Unable to allocate the recording frame pool.") }
                var buffer: CVPixelBuffer?
                let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
                guard status == kCVReturnSuccess, let buffer else { throw TaurossError.message("Unable to allocate a recording frame (\(status)).") }
                destination = buffer
                let source = CIImage(cvPixelBuffer: image)
                let scale = min(canvas.width / source.extent.width, canvas.height / source.extent.height)
                let scaled = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                let centered = scaled.transformed(by: CGAffineTransform(translationX: (canvas.width - scaled.extent.width) / 2,
                                                                        y: (canvas.height - scaled.extent.height) / 2))
                let bounds = CGRect(origin: .zero, size: canvas)
                let background = CIImage(color: .black).cropped(to: bounds)
                context.render(centered.composited(over: background), to: destination, bounds: bounds, colorSpace: colorSpace)
                statistics.renderedFrames += 1
            }
            guard adaptor.append(destination, withPresentationTime: pts) else {
                throw writer.error ?? TaurossError.message("Unable to write a recording frame. Check available disk space.")
            }
            lastPTS = pts
            lastSequence = frame.sequence; lastBuffer = destination
            statistics.encodedFrames += 1
            statistics.processingSeconds += CACurrentMediaTime() - processingStarted
            if startedAt == nil { startedAt = origin; onStarted() }
        } catch {
            terminalError = error.localizedDescription
            timer?.cancel(); timer = nil
            onFailure(error.localizedDescription)
        }
    }

    func finish(completion: @escaping @Sendable (Result<URL?, Error>) -> Void) {
        queue.async { [self] in
            guard !finished else { return }
            finished = true
            timer?.cancel(); timer = nil
            guard let writer, let input, let startedAt else {
                writer?.cancelWriting()
                try? FileManager.default.removeItem(at: url)
                if let terminalError { completion(.failure(TaurossError.message(terminalError))) }
                else { completion(.success(nil)) }
                return
            }
            guard writer.status == .writing else {
                let error = writer.error ?? TaurossError.message(terminalError ?? "Unable to finish the recording.")
                writer.cancelWriting()
                try? FileManager.default.removeItem(at: url)
                completion(.failure(error))
                return
            }
            let interval = 1 / Double(options.fps)
            let end = max(CACurrentMediaTime() - startedAt, CMTimeGetSeconds(lastPTS) + interval)
            // One final held frame preserves a static screen's duration without encoding
            // identical images 60 times per second throughout the recording.
            input.requestMediaDataWhenReady(on: queue) { [self] in
                guard !finalizedInput else { return }
                finalizedInput = true
                let hold = CMTime(seconds: max(CMTimeGetSeconds(lastPTS) + interval, end - interval), preferredTimescale: 60_000)
                if writer.status == .writing, let lastBuffer, let adaptor {
                    if !adaptor.append(lastBuffer, withPresentationTime: hold) {
                        writer.cancelWriting()
                        try? FileManager.default.removeItem(at: url)
                        completion(.failure(writer.error ?? TaurossError.message("Unable to finish the recording.")))
                        return
                    }
                }
                writer.endSession(atSourceTime: CMTime(seconds: max(end, CMTimeGetSeconds(hold) + interval), preferredTimescale: 60_000))
                input.markAsFinished()
                writer.finishWriting { [self] in
                    if writer.status == .completed { completion(.success(url)) }
                    else {
                        try? FileManager.default.removeItem(at: url)
                        completion(.failure(writer.error ?? TaurossError.message("Unable to save the recording.")))
                    }
                }
            }
        }
    }
}
