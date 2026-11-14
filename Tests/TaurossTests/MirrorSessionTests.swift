import XCTest
import AVFoundation
@testable import Tauross

@MainActor
final class MirrorSessionTests: XCTestCase {
    func testReopeningRegistrySessionKeepsTheRealAndroidStream() async throws {
        guard let serial = ProcessInfo.processInfo.environment["TAUROSS_TEST_DEVICE"] else {
            throw XCTSkip("Set TAUROSS_TEST_DEVICE for registry testing with a real Android stream.")
        }
        let devices = try await ADBService.devices()
        let device = try XCTUnwrap(devices.first { $0.id == serial })
        let systemTouches = try await ADBService.run(["-s", serial, "shell", "settings", "get", "system", "show_touches"])
        let window = TestMirrorWindow()
        let model = AppModel(sessionFactory: { owner, device, options in
            MirrorSession(owner: owner, device: device, options: options, windowFactory: { _ in window })
        })
        defer { model.stopAll() }
        model.options.maxSize = 720
        model.updateDevices([device])
        model.select(device); await model.connect()
        let session = try XCTUnwrap(model.sessions[device.id])
        let deadline = Date().addingTimeInterval(20)
        while !session.isStreaming && Date() < deadline {
            session.updateMetrics()
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(session.isStreaming, model.error ?? "No Android frame received")
        let source = session.surface
        XCTAssertGreaterThan(source.metrics().1, 0)
        await model.connect()
        XCTAssertTrue(model.sessions[device.id] === session)
        XCTAssertTrue(session.surface === source)
        XCTAssertTrue(session.isStreaming)
        XCTAssertEqual(window.presentations, 2)
        XCTAssertEqual(window.dismissals, 0)
        let during = try await ADBService.run(["-s", serial, "shell", "settings", "get", "system", "show_touches"])
        XCTAssertEqual(during, systemTouches, "Tauross must not enable Android's system touch overlay")
        session.close()
        XCTAssertFalse(model.hasSessions)
        XCTAssertEqual(window.dismissals, 1)
        let after = try await ADBService.run(["-s", serial, "shell", "settings", "get", "system", "show_touches"])
        XCTAssertEqual(after, systemTouches)
    }

    func testDifferentDevicesStayOpenAndReopeningFocusesTheExistingWindow() async throws {
        let harness = try MirrorHarness()
        defer { harness.cleanup() }
        let model = try XCTUnwrap(harness.model)
        model.updateDevices([harness.a, harness.b])
        model.select(harness.a); await model.connect()
        let a = try XCTUnwrap(model.sessions[harness.a.id])
        let firstSurface = a.surface
        model.select(harness.b); await model.connect()
        let b = try XCTUnwrap(model.sessions[harness.b.id])
        XCTAssertEqual(model.sessions.count, 2)
        XCTAssertTrue(a.isStreaming)
        XCTAssertTrue(b.isStreaming)
        XCTAssertEqual(harness.windows[harness.a.id]?.first?.dismissals, 0)

        model.select(harness.a); await model.connect()
        XCTAssertTrue(model.sessions[harness.a.id] === a)
        XCTAssertTrue(a.surface === firstSurface)
        XCTAssertEqual(harness.starts[harness.a.id], 1)
        XCTAssertEqual(harness.windows[harness.a.id]?.first?.presentations, 2)
        XCTAssertTrue(model.commandSession === a)
        b.focus()
        XCTAssertTrue(model.commandSession === b)
        a.close()
        XCTAssertNil(model.sessions[harness.a.id])
        XCTAssertTrue(model.sessions[harness.b.id] === b)
        XCTAssertTrue(b.isStreaming)
    }

    func testDisconnectAndLateCallbacksCannotStopAnotherOrReplacementSession() async throws {
        let harness = try MirrorHarness()
        defer { harness.cleanup() }
        let model = try XCTUnwrap(harness.model)
        model.updateDevices([harness.a, harness.b])
        model.select(harness.a); await model.connect()
        let old = try XCTUnwrap(model.sessions[harness.a.id])
        model.select(harness.b); await model.connect()
        let b = try XCTUnwrap(model.sessions[harness.b.id])
        model.updateDevices([harness.b])
        XCTAssertFalse(old.hasSession)
        XCTAssertTrue(b.hasSession)
        XCTAssertEqual(model.sessions.count, 1)
        model.updateDevices([harness.a, harness.b])
        model.select(harness.a); await model.connect()
        let replacement = try XCTUnwrap(model.sessions[harness.a.id])
        old.fail("Late failure from the closed capture")
        old.close()
        XCTAssertTrue(model.sessions[harness.a.id] === replacement)
        XCTAssertTrue(replacement.hasSession)
        XCTAssertTrue(b.hasSession)
    }

    func testApplyOptionsRestartsOnlyTheTargetDevice() async throws {
        let harness = try MirrorHarness()
        defer { harness.cleanup() }
        let model = try XCTUnwrap(harness.model)
        model.updateDevices([harness.a, harness.b])
        model.select(harness.a); await model.connect()
        model.select(harness.b); await model.connect()
        let a = try XCTUnwrap(model.sessions[harness.a.id])
        let b = try XCTUnwrap(model.sessions[harness.b.id])
        let bSurface = b.surface
        model.options.maxSize = 720; model.options.control = false
        model.applyOptions(to: a)
        XCTAssertEqual(harness.starts[harness.a.id], 2)
        XCTAssertEqual(harness.starts[harness.b.id], 1)
        XCTAssertEqual(harness.windows[harness.a.id]?.first?.dismissals, 1)
        XCTAssertEqual(harness.windows[harness.b.id]?.first?.dismissals, 0)
        XCTAssertTrue(b.surface === bSurface)
        XCTAssertFalse(a.canControl)
        XCTAssertTrue(b.canControl)
    }

    func testThereIsNoFixedDeviceWindowLimit() async throws {
        let harness = try MirrorHarness()
        defer { harness.cleanup() }
        let devices = (0..<64).map { MirrorDevice(id: "device-\($0)", name: "Device \($0)", platform: .android, connection: "USB", state: "device") }
        harness.model.updateDevices(devices)
        for device in devices {
            harness.model.select(device)
            await harness.model.connect()
        }
        XCTAssertEqual(harness.model.sessions.count, devices.count)
        XCTAssertTrue(harness.model.sessions.values.allSatisfy(\.isStreaming))
        harness.model.select(devices[0]); await harness.model.connect()
        XCTAssertEqual(harness.model.sessions.count, devices.count)
        XCTAssertEqual(harness.starts[devices[0].id], 1)
    }

    func testPendingIOSPermissionIsDeduplicatedAndKeepsExistingMirrors() async throws {
        var permission: CheckedContinuation<Bool, Never>?
        var permissionRequests = 0
        let harness = try MirrorHarness(requestIOSAccess: {
            permissionRequests += 1
            return await withCheckedContinuation { permission = $0 }
        })
        defer { harness.cleanup() }
        let ios = MirrorDevice(id: "ios", name: "iPhone", platform: .ios, connection: "USB", state: "device")
        let model = try XCTUnwrap(harness.model)
        model.updateDevices([harness.a, ios])
        model.select(harness.a); await model.connect()
        let a = try XCTUnwrap(model.sessions[harness.a.id])
        model.select(ios)
        let opening = Task { await model.connect() }
        while permission == nil { await Task.yield() }
        await model.connect()
        XCTAssertTrue(a.isStreaming)
        XCTAssertEqual(permissionRequests, 1)
        permission?.resume(returning: true)
        await opening.value
        XCTAssertEqual(model.sessions.count, 2)
        model.select(ios); await model.connect()
        XCTAssertEqual(permissionRequests, 1)
        XCTAssertEqual(harness.starts[ios.id], 1)
        model.updateDevices([harness.a], verifiedPlatforms: [.ios])
        XCTAssertTrue(a.isStreaming)
        XCTAssertNil(model.sessions[ios.id])
    }

    func testScreenshotsUseTheWindowDeviceAndItsOwnFrame() async throws {
        let harness = try MirrorHarness()
        defer { harness.cleanup() }
        let model = try XCTUnwrap(harness.model)
        model.updateDevices([harness.a, harness.b])
        model.select(harness.a); await model.connect()
        model.select(harness.b); await model.connect()
        let a = try XCTUnwrap(model.sessions[harness.a.id])
        let b = try XCTUnwrap(model.sessions[harness.b.id])
        a.screenshot(); b.screenshot()
        let aURL = try XCTUnwrap(a.lastCapture)
        let bURL = try XCTUnwrap(b.lastCapture)
        XCTAssertNotEqual(aURL, bURL)
        XCTAssertNotEqual(try Data(contentsOf: aURL), try Data(contentsOf: bURL))
        XCTAssertEqual(model.lastCapture, bURL)
        XCTAssertNil(model.error)
    }

    func testClosingOneRecordingKeepsTheOtherRunningAndQuitFinalizesBothFiles() async throws {
        let harness = try MirrorHarness()
        defer { harness.cleanup() }
        let model = try XCTUnwrap(harness.model)
        model.updateDevices([harness.a, harness.b])
        model.select(harness.a); await model.connect()
        model.select(harness.b); await model.connect()
        let a = try XCTUnwrap(model.sessions[harness.a.id])
        let b = try XCTUnwrap(model.sessions[harness.b.id])
        a.toggleRecording(); b.toggleRecording()
        let deadline = Date().addingTimeInterval(10)
        while (!a.isRecording || !b.isRecording) && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(a.isRecording, a.error ?? "A failed to start recording")
        XCTAssertTrue(b.isRecording, b.error ?? "B failed to start recording")
        a.close()
        XCTAssertEqual(model.sessions.count, 1)
        XCTAssertTrue(b.hasRecording)
        XCTAssertTrue(b.isStreaming)
        XCTAssertTrue(model.hasRecordings)
        await withCheckedContinuation { continuation in model.stopAll { continuation.resume() } }
        XCTAssertFalse(model.hasSessions)
        XCTAssertFalse(model.hasRecordings)
        XCTAssertFalse(a.hasRecording)
        XCTAssertFalse(b.hasRecording)
        for session in [a, b] {
            let url = try XCTUnwrap(session.lastCapture, model.error ?? "Recording was not finalized")
            let tracks = try await AVURLAsset(url: url).loadTracks(withMediaType: .video)
            XCTAssertEqual(tracks.count, 1)
        }
    }
}

@MainActor
private final class TestMirrorWindow: MirrorWindowPresenting {
    var presentations = 0
    var dismissals = 0
    func showMirror() { presentations += 1 }
    func dismissMirror() { dismissals += 1 }
}

@MainActor
private final class MirrorHarness {
    let a = MirrorDevice(id: "a", name: "Android A", platform: .android, connection: "USB", state: "device")
    let b = MirrorDevice(id: "b", name: "Android B", platform: .android, connection: "USB", state: "device")
    var starts: [String: Int] = [:]
    var windows: [String: [TestMirrorWindow]] = [:]
    var urls: [URL] = []
    var model: AppModel!
    private let imageA: CVPixelBuffer
    private let imageB: CVPixelBuffer

    init(requestIOSAccess: @escaping () async -> Bool = { true }) throws {
        imageA = try Self.frame(value: 40)
        imageB = try Self.frame(value: 180)
        model = AppModel(sessionFactory: { [unowned self] owner, device, options in
            MirrorSession(owner: owner, device: device, options: options, windowFactory: { _ in
                let window = TestMirrorWindow()
                self.windows[device.id, default: []].append(window)
                return window
            }, captureStarter: { session, _ in
                self.starts[device.id, default: 0] += 1
                session.surface.publish(device.id == self.b.id ? self.imageB : self.imageA)
                session.updateMetrics()
            }, captureDestination: { _, _, suffix in
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("tauross-multi-\(device.id)-\(UUID()).\(suffix)")
                self.urls.append(url)
                return url
            })
        }, requestIOSAccess: requestIOSAccess)
    }

    func cleanup() {
        model.stopAll()
        for url in urls { try? FileManager.default.removeItem(at: url) }
    }

    private static func frame(value: UInt8) throws -> CVPixelBuffer {
        var image: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 320, 240, kCVPixelFormatType_32BGRA,
                                         [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &image), kCVReturnSuccess)
        let buffer = try XCTUnwrap(image)
        CVPixelBufferLockBaseAddress(buffer, [])
        let bytes = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        for row in 0..<240 {
            for column in 0..<320 {
                let offset = row * CVPixelBufferGetBytesPerRow(buffer) + column * 4
                bytes[offset] = value; bytes[offset + 1] = value; bytes[offset + 2] = value; bytes[offset + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }
}
