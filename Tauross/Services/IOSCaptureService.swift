import AVFoundation
import CoreMediaIO

final class IOSCaptureService: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.tauross.ios", qos: .userInteractive)
    private let capture = AVCaptureSession()
    private let surface: VideoSurface
    private var runtimeObserver: NSObjectProtocol?
    private var disconnectObserver: NSObjectProtocol?

    init(surface: VideoSurface) { self.surface = surface }
    deinit {
        if let runtimeObserver { NotificationCenter.default.removeObserver(runtimeObserver) }
        if let disconnectObserver { NotificationCenter.default.removeObserver(disconnectObserver) }
    }

    static func enableScreenDevices() throws {
        var property = CMIOObjectPropertyAddress(mSelector: UInt32(kCMIOHardwarePropertyAllowScreenCaptureDevices),
            mScope: UInt32(kCMIOObjectPropertyScopeGlobal), mElement: UInt32(kCMIOObjectPropertyElementMain))
        var allow: UInt32 = 1
        let status = CMIOObjectSetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &property, 0, nil,
            UInt32(MemoryLayout.size(ofValue: allow)), &allow)
        guard status == noErr else { throw TaurossError.message("macOS could not enable iOS screen capture devices (\(status)).") }
    }

    static func discover() -> [MirrorDevice] {
        // USB screen devices use the muxed media type. Never substitute the Continuity Camera.
        AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .muxed, position: .unspecified)
            .devices.map { MirrorDevice(id: $0.uniqueID, name: $0.localizedName, platform: .ios, connection: "USB", state: "device") }
    }

    func start(id: String, onFailure: @escaping @Sendable (String) -> Void) {
        queue.async { [self] in
            do {
                guard let device = AVCaptureDevice(uniqueID: id), device.hasMediaType(.muxed) else {
                    throw TaurossError.message("iPhone screen source not found. Unlock the device, connect USB, and choose Trust This Computer.")
                }
                let input = try AVCaptureDeviceInput(device: device)
                let output = AVCaptureVideoDataOutput()
                output.alwaysDiscardsLateVideoFrames = true
                output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                output.setSampleBufferDelegate(self, queue: queue)
                capture.beginConfiguration()
                guard capture.canAddInput(input), capture.canAddOutput(output) else {
                    capture.commitConfiguration()
                    throw TaurossError.message("Unable to open the iPhone screen source. Close other apps using this device.")
                }
                capture.addInput(input)
                capture.addOutput(output)
                capture.commitConfiguration()
                runtimeObserver = NotificationCenter.default.addObserver(forName: .AVCaptureSessionRuntimeError, object: capture, queue: nil) { notification in
                    let error = notification.userInfo?[AVCaptureSessionErrorKey] as? Error
                    onFailure(error?.localizedDescription ?? "The iOS screen source disconnected.")
                }
                disconnectObserver = NotificationCenter.default.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: device, queue: nil) { _ in
                    onFailure("iPhone disconnected from USB.")
                }
                capture.startRunning()
            } catch { onFailure(error.localizedDescription) }
        }
    }

    func stop() {
        queue.async { [self] in
            capture.stopRunning()
            capture.beginConfiguration()
            capture.inputs.forEach { capture.removeInput($0) }
            capture.outputs.forEach { capture.removeOutput($0) }
            capture.commitConfiguration()
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if let image = CMSampleBufferGetImageBuffer(sampleBuffer) { surface.publish(image) }
    }
}
