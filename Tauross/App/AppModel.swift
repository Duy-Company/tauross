import SwiftUI
import AVFoundation
import Combine

@MainActor
final class AppModel: ObservableObject {
    @Published var devices: [MirrorDevice] = []
    @Published var selectedID: String?
    @Published var options = StreamOptions()
    @Published var androidRecording = RecordingOptions.load(for: .android) {
        didSet { androidRecording.save(for: .android) }
    }
    @Published var iosRecording = RecordingOptions.load(for: .ios) {
        didSet { iosRecording.save(for: .ios) }
    }
    @Published private(set) var sessions: [String: MirrorSession] = [:]
    @Published private(set) var focusedSessionID: String?
    @Published var isRefreshing = false
    @Published var error: String?
    @Published var notice: String?
    @Published private(set) var lastCapture: URL?
    @Published var diagnostics = ""
    private var monitoring: Task<Void, Never>?
    private var pendingConnections: Set<String> = []
    private var finishingSessions: [UUID: MirrorSession] = [:]
    private var observations: [String: AnyCancellable] = [:]
    private let sessionFactory: @MainActor (AppModel, MirrorDevice, StreamOptions) -> MirrorSession
    private let requestIOSAccess: () async -> Bool

    init(sessionFactory: @escaping @MainActor (AppModel, MirrorDevice, StreamOptions) -> MirrorSession = {
        MirrorSession(owner: $0, device: $1, options: $2)
    }, requestIOSAccess: @escaping () async -> Bool = { await AVCaptureDevice.requestAccess(for: .video) }) {
        self.sessionFactory = sessionFactory
        self.requestIOSAccess = requestIOSAccess
    }

    var selectedDevice: MirrorDevice? { devices.first { $0.id == selectedID } }
    var commandSession: MirrorSession? { focusedSessionID.flatMap { sessions[$0] } ?? selectedID.flatMap { sessions[$0] } }
    var hasSessions: Bool { !sessions.isEmpty }
    var hasRecordings: Bool { sessions.values.contains(where: \.hasRecording) || finishingSessions.values.contains(where: \.hasRecording) }

    func select(_ device: MirrorDevice) {
        selectedID = device.id
        focusedSessionID = nil
    }

    func focus(_ session: MirrorSession) {
        guard sessions[session.device.id] === session else { return }
        focusedSessionID = session.device.id
        selectedID = session.device.id
    }

    func recordingOptions(for platform: DevicePlatform) -> RecordingOptions {
        platform == .android ? androidRecording : iosRecording
    }

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
            for session in Array(sessions.values) { session.updateMetrics() }
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
            updateDevices(androidDevices + iosDevices)
            diagnostics = "Bundled ADB · 35.0.2\nscrcpy-server · 3.3.4\nVideo · H.264 / VideoToolbox\niOS · CoreMediaIO / AVFoundation\n\n" + devices.map { "\($0.name) · \($0.connection) · \($0.state)" }.joined(separator: "\n")
        } catch {
            // Android discovery failed, so only the iOS result can prove a disconnect.
            updateDevices(devices.filter { $0.platform == .android } + iosDevices, verifiedPlatforms: [.ios])
            diagnostics = error.localizedDescription
            if !silent { self.error = "Unable to discover Android devices.\n" + error.localizedDescription }
        }
    }

    func updateDevices(_ devices: [MirrorDevice], verifiedPlatforms: Set<DevicePlatform> = [.android, .ios]) {
        self.devices = devices
        if !devices.contains(where: { $0.id == selectedID }) { selectedID = devices.first(where: \.isReady)?.id ?? devices.first?.id }
        let disconnected = sessions.values.filter { session in
            verifiedPlatforms.contains(session.device.platform) && !devices.contains { $0.id == session.device.id && $0.isReady }
        }
        for session in disconnected {
            sessionFailed(session, message: "Device disconnected. Check the USB cable or Wi-Fi connection and try again.")
        }
    }

    func connect() async {
        guard let device = selectedDevice else { return }
        if let session = sessions[device.id] { session.showMirror(); return }
        guard device.isReady, pendingConnections.insert(device.id).inserted else { return }
        defer { pendingConnections.remove(device.id) }
        error = nil
        if device.platform == .ios {
            guard await requestIOSAccess() else {
                reportError("Allow Tauross in System Settings → Privacy & Security → Camera to access the iPhone screen source.", for: device)
                return
            }
        }
        // A permission prompt may outlive selection, disconnection, or another open request.
        guard selectedDevice?.id == device.id, selectedDevice?.isReady == true else { return }
        if let existing = sessions[device.id] { existing.showMirror(); return }
        let session = sessionFactory(self, device, options)
        sessions[device.id] = session
        observations[device.id] = session.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        session.start()
    }

    func close(_ session: MirrorSession) {
        guard sessions[session.device.id] === session else { return }
        sessions.removeValue(forKey: session.device.id)
        observations.removeValue(forKey: session.device.id)
        if focusedSessionID == session.device.id { focusedSessionID = nil }
        session.stop()
        // Retain a closed window's recording until its file has been finalized.
        if session.hasRecording {
            finishingSessions[session.id] = session
            session.stopRecording { [weak self] in self?.finishingSessions.removeValue(forKey: session.id) }
        }
    }

    func stopAll(onFinished: (() -> Void)? = nil) {
        let active = Array(sessions.values)
        let all = active + Array(finishingSessions.values)
        active.forEach { close($0) }
        guard !all.isEmpty else { onFinished?(); return }
        var remaining = all.count
        for session in all {
            session.stopRecording {
                remaining -= 1
                if remaining == 0 { onFinished?() }
            }
        }
    }

    func sessionFailed(_ session: MirrorSession, message: String) {
        guard sessions[session.device.id] === session else { return }
        close(session)
        reportError(message, for: session.device)
    }

    func reportError(_ message: String, for device: MirrorDevice) { error = "\(device.name): \(message)" }

    func savedCapture(_ url: URL, notice: String, for device: MirrorDevice) {
        lastCapture = url; self.notice = "\(device.name): \(notice)"
    }

    func applyOptions(to session: MirrorSession) {
        guard sessions[session.device.id] === session else { return }
        session.applyOptions(options)
    }

    func showCaptures() {
        do {
            try FileManager.default.createDirectory(at: CaptureStorage.root, withIntermediateDirectories: true)
            NSWorkspace.shared.open(CaptureStorage.root)
        } catch { self.error = error.localizedDescription }
    }
}
