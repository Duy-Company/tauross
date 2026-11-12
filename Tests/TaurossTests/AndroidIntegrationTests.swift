import XCTest
@testable import Tauross

final class AndroidIntegrationTests: XCTestCase {
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
