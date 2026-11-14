import SwiftUI
import AVFoundation

@MainActor
protocol MirrorWindowPresenting: AnyObject {
    func showMirror()
    func dismissMirror()
}

/// Owns exactly one device's window, capture, input, and recording lifecycle.
@MainActor
final class MirrorSession: ObservableObject, Identifiable {
    let id = UUID()
    let device: MirrorDevice
    @Published private(set) var isConnecting = false
    @Published private(set) var isStreaming = false
    @Published private(set) var isRecording = false
    @Published private(set) var isStartingRecording = false
    @Published private(set) var isFinishingRecording = false
    @Published private(set) var recordingStartedAt: Date?
    @Published private(set) var lastCapture: URL?
    @Published var notice: String?
    @Published var error: String?
    @Published var dimensions = CGSize(width: 9, height: 19.5)
    @Published var fps = 0.0
    @Published var mbps = 0.0
    @Published private(set) var surface = VideoSurface()
    private weak var owner: AppModel?
    private var window: MirrorWindowPresenting?
    private let windowFactory: @MainActor (MirrorSession) -> MirrorWindowPresenting
    private let captureStarter: (@MainActor (MirrorSession, StreamOptions) -> Void)?
    private let captureDestination: (String, DevicePlatform, String) throws -> URL
    private var android: AndroidSession?
    private var ios: IOSCaptureService?
    private var androidCaptureOptions = StreamOptions()
    private var activeOptions: StreamOptions
    private var recorder: VideoRecorder?
    private var recordingID = UUID()
    private var recordingCompletions: [() -> Void] = []
    private var generation = UUID()
    private var connectingSince: Date?
    private var lastFrameCount = 0
    private var lastMetricDate = Date()

    init(owner: AppModel, device: MirrorDevice, options: StreamOptions,
         windowFactory: @escaping @MainActor (MirrorSession) -> MirrorWindowPresenting = { MirrorWindowController(model: $0) },
         captureStarter: (@MainActor (MirrorSession, StreamOptions) -> Void)? = nil,
         captureDestination: @escaping (String, DevicePlatform, String) throws -> URL = {
             try CaptureStorage.destination(kind: $0, platform: $1, extension: $2)
         }) {
        self.owner = owner; self.device = device; self.activeOptions = options
        self.windowFactory = windowFactory; self.captureStarter = captureStarter
        self.captureDestination = captureDestination
    }

    var hasSession: Bool { isConnecting || isStreaming }
    var hasRecording: Bool { recorder != nil }
    private var activeDevice: MirrorDevice? { hasSession ? device : nil }
    var canControl: Bool { isStreaming && device.platform == .android && activeOptions.control }

    func start() {
        guard !hasSession else { showMirror(); return }
        error = nil; notice = nil
        surface = VideoSurface()
        lastFrameCount = 0; lastMetricDate = Date()
        generation = UUID()
        let token = generation
        isConnecting = true; connectingSince = Date()
        if let captureStarter {
            captureStarter(self, activeOptions)
        } else {
            let failure: @Sendable (String) -> Void = { [weak self] message in
                Task { @MainActor in
                    guard let self, self.generation == token else { return }
                    self.fail(message)
                }
            }
            if device.platform == .android {
                androidCaptureOptions = activeOptions
                let capture = AndroidSession(surface: surface, onFailure: failure)
                android = capture; capture.start(device: device, options: activeOptions)
            } else {
                let capture = IOSCaptureService(surface: surface)
                ios = capture; capture.start(id: device.id, onFailure: failure)
            }
        }
        updateMetrics()
        showMirror()
    }

    func showMirror() {
        guard hasSession else { return }
        focus()
        if window == nil { window = windowFactory(self) }
        window?.showMirror()
    }

    func focus() { owner?.focus(self) }
    func close() { owner?.close(self) }

    func stop() {
        stopRecording()
        generation = UUID()
        android?.stop(); android = nil
        ios?.stop(); ios = nil
        isConnecting = false; isStreaming = false; connectingSince = nil
        fps = 0; mbps = 0
        window?.dismissMirror(); window = nil
    }

    func applyOptions(_ options: StreamOptions) {
        stop()
        activeOptions = options
        start()
    }

    func updateMetrics() {
        guard hasSession else { return }
        let (size, count, _, rate) = surface.metrics()
        if count > 0 {
            dimensions = size
            fps = Double(count - lastFrameCount) / max(Date().timeIntervalSince(lastMetricDate), 0.01)
            lastFrameCount = count; lastMetricDate = Date(); mbps = rate
            isConnecting = false; isStreaming = true; connectingSince = nil
        } else if let connectingSince, Date().timeIntervalSince(connectingSince) > 25 {
            fail("No video received after 25 seconds. Unlock the device, check connection permissions, and close other apps using the capture source.")
        }
    }

    func key(_ code: UInt32) { if canControl { android?.key(code) } }
    func rotateDevice() { if canControl { android?.send(Data([11])) } }
    func input(_ data: Data) { if canControl { android?.send(data) } }

    func fail(_ message: String) {
        if let owner { owner.sessionFailed(self, message: message) }
        else { stop() }
    }

    private func reportError(_ message: String) {
        if hasSession { error = message }
        else { owner?.reportError(message, for: device) }
    }

    private func savedCapture(_ url: URL, notice: String) {
        lastCapture = url; self.notice = notice
        owner?.savedCapture(url, notice: notice, for: device)
    }

    private func replaceAndroidCapture(with options: StreamOptions) {
        guard let device = activeDevice, device.platform == .android else { return }
        let previous = android
        generation = UUID()
        let token = generation
        surface = VideoSurface()
        lastFrameCount = 0; lastMetricDate = Date()
        isConnecting = true; isStreaming = false; connectingSince = Date()
        androidCaptureOptions = options
        if let captureStarter {
            previous?.stop(); android = nil
            captureStarter(self, options)
            return
        }
        let session = AndroidSession(surface: surface) { [weak self] message in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                if self.hasRecording, options != self.activeOptions {
                    // A device that cannot sustain the raised recording quality
                    // should return to its original mirror settings.
                    self.reportError("Recording: " + message)
                    self.stopRecording()
                } else {
                    self.fail(message)
                }
            }
        }
        android = session
        session.start(device: device, options: options, afterStopping: previous)
    }

    func toggleRecording() {
        if hasRecording { stopRecording(); return }
        guard isStreaming, let device = activeDevice else { return }
        do {
            let options = owner?.recordingOptions(for: device.platform) ?? RecordingOptions()
            let url = try captureDestination("recordings", device.platform, options.container.rawValue)
            // Capture once at the higher requested quality, then encode the recording
            // independently. This avoids a second device encoder and Mac decoder.
            if device.platform == .android {
                let capture = options.androidCapture(sharing: activeOptions)
                if capture != androidCaptureOptions { replaceAndroidCapture(with: capture) }
            }
            let source = surface
            let token = UUID()
            recordingID = token
            isStartingRecording = true
            let failure: @Sendable (String) -> Void = { [weak self] message in
                Task { @MainActor in
                    guard let self, self.recordingID == token, self.recorder != nil, !self.isFinishingRecording else { return }
                    self.reportError("Recording: " + message)
                    self.stopRecording()
                }
            }
            let recorder = VideoRecorder(surface: source, options: options, url: url, onStarted: { [weak self] in
                Task { @MainActor in
                    guard let self, self.recordingID == token, self.recorder != nil, !self.isFinishingRecording else { return }
                    self.isStartingRecording = false
                    self.isRecording = true
                    self.recordingStartedAt = Date()
                }
            }, onFailure: failure)
            self.recorder = recorder
            recorder.start()
        } catch { reportError(error.localizedDescription) }
    }

    func stopRecording(onFinished: (() -> Void)? = nil) {
        guard let recorder else { onFinished?(); return }
        if let onFinished { recordingCompletions.append(onFinished) }
        guard !isFinishingRecording else { return }
        isFinishingRecording = true
        isRecording = false; isStartingRecording = false; recordingStartedAt = nil
        let sessionToken = generation
        recorder.finish { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.recorder = nil
                self.isFinishingRecording = false
                switch result {
                case .success(let url):
                    if let url { self.savedCapture(url, notice: "Recording saved to ~/.tauross/recordings.") }
                case .failure(let error): self.reportError(error.localizedDescription)
                }
                if self.generation == sessionToken, self.activeDevice?.platform == .android,
                   self.androidCaptureOptions != self.activeOptions {
                    self.replaceAndroidCapture(with: self.activeOptions)
                }
                let completions = self.recordingCompletions
                self.recordingCompletions.removeAll()
                completions.forEach { $0() }
            }
        }
    }

    func screenshot() {
        guard let (image, _) = surface.frame(after: -1) else { return }
        guard isStreaming, let platform = activeDevice?.platform else { return }
        let context = CIContext()
        guard let cgImage = context.createCGImage(CIImage(cvPixelBuffer: image), from: CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(image), height: CVPixelBufferGetHeight(image))),
              let data = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) else {
            reportError("Unable to create a screenshot."); return
        }
        do {
            let url = try captureDestination("screenshots", platform, "png")
            try data.write(to: url, options: .atomic)
            savedCapture(url, notice: "Screenshot saved to ~/.tauross/screenshots.")
        } catch { reportError(error.localizedDescription) }
    }
}
