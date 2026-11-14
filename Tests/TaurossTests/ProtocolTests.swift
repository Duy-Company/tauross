import XCTest
@testable import Tauross

final class ProtocolTests: XCTestCase {
    func testRuntimeToolsAreBundledAndADBIsExecutable() throws {
        let adb = try BundledTools.url("adb")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: adb.path))
        let server = try BundledTools.url("scrcpy-server")
        XCTAssertGreaterThan(try Data(contentsOf: server).count, 1000)
    }

    func testADBEnumerationExcludesDaemonNoiseAndKeepsUnauthorizedDevices() {
        let output = """
        * daemon started successfully
        List of devices attached
        ABC123 unauthorized usb:123 transport_id:1
        emulator-5554 device product:sdk model:Pixel_9a device:emu64 transport_id:2
        192.168.1.3:37123 device product:test model:Pixel_8 transport_id:3
        adb-ABC-test._adb-tls-connect._tcp device model:Pixel_7 transport_id:4
        """
        let devices = MirrorDevice.parseADB(output)
        XCTAssertEqual(devices.count, 4)
        XCTAssertFalse(devices[0].isReady)
        XCTAssertEqual(devices[1].name, "Pixel 9a")
        XCTAssertEqual(devices.map(\.connection), ["USB", "Emulator", "Wi-Fi", "Wi-Fi"])
    }

    func testAnnexBMixedStartCodesAndPayloadBoundaries() {
        let data = Data([0,0,0,1,0x67,0x42,0,0,1,0x68,0xce,0,0,0,1,0x65,0x88])
        XCTAssertEqual(H264AnnexB.units(data), [Data([0x67,0x42]), Data([0x68,0xce]), Data([0x65,0x88])])
        XCTAssertTrue(H264AnnexB.units(Data([0,0,1])).isEmpty)
    }

    func testControlMessagesMatchScrcpy334WireContract() {
        XCTAssertEqual(Array(ScrcpyControl.key(3, down: true)), [0,0,0,0,0,3,0,0,0,0,0,0,0,0])
        XCTAssertEqual(Array(ScrcpyControl.text("Hi")), [1,0,0,0,2,72,105])
        let touch = ScrcpyControl.touch(action: 0, x: 123, y: 456, width: 1080, height: 2400)
        XCTAssertEqual(touch.count, 32)
        XCTAssertEqual(touch.unsignedBE(at: 2, count: 8), UInt64.max - 1)
        XCTAssertEqual(touch.unsignedBE(at: 10, count: 4), 123)
        XCTAssertEqual(touch.unsignedBE(at: 14, count: 4), 456)
        XCTAssertEqual(touch.unsignedBE(at: 18, count: 2), 1080)
        XCTAssertEqual(touch.unsignedBE(at: 22, count: 2), 65535)
        XCTAssertEqual(ScrcpyControl.touch(action: 1, x: 0, y: 0, width: 1080, height: 2400).unsignedBE(at: 22, count: 2), 0)
        XCTAssertEqual(ScrcpyControl.scroll(x: 0, y: 0, width: 1080, height: 2400, dx: 1, dy: -1).count, 21)
    }

    func testNetworkEndpointRejectsInvalidPortsAndShellPayloads() throws {
        XCTAssertEqual(try NetworkEndpoint.validate(" 192.168.1.3:37123 "), "192.168.1.3:37123")
        XCTAssertEqual(try NetworkEndpoint.validate("pixel.local:5555"), "pixel.local:5555")
        for value in ["host", "host:0", "host:65536", "host:abc", "-host:123", "host;ls:123", "$(id):123", "host:1:2", "host :5555"] {
            XCTAssertThrowsError(try NetworkEndpoint.validate(value), value)
        }
    }

    func testStreamOptionsDoNotEnableUnimplementedAudioOrClipboardSync() {
        let args = StreamOptions().serverArguments
        XCTAssertTrue(args.contains("audio=false"))
        XCTAssertTrue(args.contains("clipboard_autosync=false"))
        XCTAssertTrue(args.contains("video_bit_rate=8000000"))
        XCTAssertTrue(args.contains("show_touches=false"))
    }
}
