import SwiftUI
import AVFoundation

@MainActor
final class AppModel: ObservableObject {
    @Published var devices: [MirrorDevice] = []
    @Published var selectedID: String?
    @Published var options = StreamOptions()
    @Published var isRefreshing = false
    @Published var isConnecting = false
    @Published var isStreaming = false
    @Published var activeDevice: MirrorDevice?
    @Published var error: String?
    @Published var notice: String?
    @Published var dimensions = CGSize(width: 9, height: 19.5)
    @Published var fps = 0.0
    @Published var mbps = 0.0
    @Published var diagnostics = ""
    @Published private(set) var surface = VideoSurface()
    private lazy var mirrorWindow = MirrorWindowController(model: self)
    private var monitoring: Task<Void, Never>?
    private var android: AndroidSession?
    private var ios: IOSCaptureService?
    private var generation = UUID()
    private var activeOptions = StreamOptions()
    private var connectingSince: Date?
    private var lastFrameCount = 0
    private var lastMetricDate = Date()

    var selectedDevice: MirrorDevice? { devices.first { $0.id == selectedID } }
    var hasSession: Bool { isConnecting || isStreaming }

    func startMonitoring() {
        guard monitoring == nil else { return }
        monitoring = Task { await run() }
    }

    private func run() async {
        do { try IOSCaptureService.enableScreenDevices() } catch { diagnostics = error.localizedDescription }
        await refresh()
        var tick = 0
        while !Task.isCancelled {
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            updateMetrics()
            tick += 1
            if tick % 4 == 0 { await refresh(silent: true) }
        }
    }

    func refresh(silent: Bool = false) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let iosDevices = IOSCaptureService.discover()
        do {
            let androidDevices = try await ADBService.devices()
            devices = androidDevices + iosDevices
            if !devices.contains(where: { $0.id == selectedID }) { selectedID = devices.first(where: \.isReady)?.id ?? devices.first?.id }
            if let activeDevice, !devices.contains(where: { $0.id == activeDevice.id && $0.isReady }) {
                stop()
                error = "Device disconnected. Check the USB cable or Wi-Fi connection and try again."
            }
            diagnostics = "Bundled ADB · 35.0.2\nscrcpy-server · 3.3.4\nVideo · H.264 / VideoToolbox\niOS · CoreMediaIO / AVFoundation\n\n" + devices.map { "\($0.name) · \($0.connection) · \($0.state)" }.joined(separator: "\n")
        } catch {
            devices = devices.filter { $0.platform == .android } + iosDevices
            diagnostics = error.localizedDescription
            if !silent { self.error = "Unable to discover Android devices.\n" + error.localizedDescription }
        }
    }

    func connect() async {
        guard let device = selectedDevice, device.isReady else { return }
        if hasSession && activeDevice?.id == device.id { mirrorWindow.showMirror(); return }
        if hasSession { stop() }
        error = nil; notice = nil
        if device.platform == .ios {
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            guard granted else {
                error = "Allow Tauross in System Settings → Privacy & Security → Camera to access the iPhone screen source."
                return
            }
        }
        // Selection may have changed while the permission dialog was open.
        guard !hasSession, selectedDevice?.id == device.id else { return }
        // Each session owns a mailbox; frames from a cancelled worker cannot leak into the next session.
        surface = VideoSurface(); dimensions = CGSize(width: 9, height: 19.5)
        lastFrameCount = 0; lastMetricDate = Date()
        generation = UUID()
        let token = generation
        activeDevice = device; isConnecting = true; connectingSince = Date()
        activeOptions = options
        let failure: @Sendable (String) -> Void = { [weak self] message in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.stop(); self.error = message
            }
        }
        if device.platform == .android {
            let session = AndroidSession(surface: surface, onFailure: failure)
            android = session; session.start(device: device, options: options)
        } else {
            let session = IOSCaptureService(surface: surface)
            ios = session; session.start(id: device.id, onFailure: failure)
        }
        mirrorWindow.showMirror()
    }

    func stop() {
        generation = UUID()
        android?.stop(); android = nil
        ios?.stop(); ios = nil
        isConnecting = false; isStreaming = false; activeDevice = nil; connectingSince = nil
        fps = 0; mbps = 0
        mirrorWindow.dismissMirror()
    }

    func applyOptions() async {
        guard let id = activeDevice?.id else { return }
        stop(); selectedID = id
        await connect()
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
            stop()
            error = "No video received after 25 seconds. Unlock the device, check connection permissions, and close other apps using the capture source."
        }
    }

    func key(_ code: UInt32) { android?.key(code) }
    func input(_ data: Data) { android?.send(data) }
    var canControl: Bool { isStreaming && activeDevice?.platform == .android && activeOptions.control }

    func screenshot() {
        guard let (image, _) = surface.frame(after: -1) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "Tauross-\(Date().formatted(.iso8601).replacingOccurrences(of: ":", with: "-" )).png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let context = CIContext()
        guard let cgImage = context.createCGImage(CIImage(cvPixelBuffer: image), from: CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(image), height: CVPixelBufferGetHeight(image))),
              let data = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) else {
            error = "Unable to create a screenshot."; return
        }
        do { try data.write(to: url); notice = "Screenshot saved." } catch { self.error = error.localizedDescription }
    }
}
