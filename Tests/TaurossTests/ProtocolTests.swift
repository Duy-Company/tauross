import XCTest
import AppKit
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

    func testStreamOptionsEnableClipboardOnlyWithInputControl() {
        let args = StreamOptions().serverArguments
        XCTAssertTrue(args.contains("audio=false"))
        XCTAssertTrue(args.contains("clipboard_autosync=true"))
        XCTAssertTrue(args.contains("video_bit_rate=8000000"))
        XCTAssertTrue(args.contains("show_touches=false"))
        var readOnly = StreamOptions()
        readOnly.control = false
        XCTAssertTrue(readOnly.serverArguments.contains("clipboard_autosync=false"))
    }

    func testClipboardControlWireFormatAndUTF8Limit() throws {
        XCTAssertEqual(ScrcpyControl.getClipboard(copyKey: 1), Data([8, 1]))
        XCTAssertEqual(ScrcpyControl.getClipboard(copyKey: 2), Data([8, 2]))
        let text = "Tiếng Việt 👋\nline 2"
        let packet = ScrcpyControl.setClipboard(text, paste: true, sequence: 0x0102030405060708)
        XCTAssertEqual(Array(packet.prefix(10)), [9, 1, 2, 3, 4, 5, 6, 7, 8, 1])
        XCTAssertEqual(packet.unsignedBE(at: 10, count: 4), UInt64(text.utf8.count))
        XCTAssertEqual(String(data: packet.dropFirst(14), encoding: .utf8), text)
        XCTAssertEqual(ScrcpyControl.setClipboard("", paste: false), Data([9] + Array(repeating: 0, count: 13)))

        let large = ScrcpyControl.setClipboard(String(repeating: "🙂", count: 70_000), paste: true)
        XCTAssertLessThanOrEqual(large.count, 1 << 18)
        XCTAssertEqual(large.unsignedBE(at: 10, count: 4), UInt64(large.count - 14))
        XCTAssertEqual(try XCTUnwrap(String(data: large.dropFirst(14), encoding: .utf8)), String(repeating: "🙂", count: ((1 << 18) - 14) / 4))
    }

    func testDeviceClipboardMessagesStayAlignedWithAcknowledgements() throws {
        let text = "Android → Mac ✅"
        var wire = Data([1])
        wire.appendBE(UInt64(42))
        wire.append(contentsOf: [2, 0, 7, 0, 2, 0xaa, 0xbb])
        wire.append(0)
        wire.appendBE(UInt32(text.utf8.count))
        wire.append(contentsOf: text.utf8)
        wire.append(contentsOf: [0, 0, 0, 0, 0])
        var offset = 0
        func read(_ count: Int) throws -> Data {
            guard offset + count <= wire.count else { throw TaurossError.message("Truncated fixture") }
            defer { offset += count }
            return wire.subdata(in: offset..<(offset + count))
        }
        XCTAssertEqual(try ScrcpyDeviceMessage.read(using: read), .clipboardAcknowledged(42))
        XCTAssertEqual(try ScrcpyDeviceMessage.read(using: read), .uhidOutput(id: 7, data: Data([0xaa, 0xbb])))
        XCTAssertEqual(try ScrcpyDeviceMessage.read(using: read), .clipboard(text))
        XCTAssertEqual(try ScrcpyDeviceMessage.read(using: read), .clipboard(""))
        XCTAssertEqual(offset, wire.count)
    }

    func testDeviceClipboardRejectsOversizeUnknownAndTruncatedPackets() {
        for wire in [Data([0, 0, 4, 0, 0]), Data([99]), Data([0, 0, 0, 0, 2, 65]), Data([0, 0, 0, 0, 1, 0xff])] {
            var offset = 0
            XCTAssertThrowsError(try ScrcpyDeviceMessage.read { count in
                guard offset + count <= wire.count else { throw TaurossError.message("Truncated fixture") }
                defer { offset += count }
                return wire.subdata(in: offset..<(offset + count))
            })
        }
    }

    @MainActor
    func testMirrorClipboardActionsAndCommandShortcutsRespectControlAndFocus() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let text = "Dán từ Mac 🙂"
        XCTAssertTrue(pasteboard.setString(text, forType: .string))
        var sent: [Data] = []
        let view = VideoNSView(surface: VideoSurface(), pasteboard: pasteboard) { sent.append($0) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        defer { window.contentView = nil }
        XCTAssertTrue(window.makeFirstResponder(view))
        view.controlEnabled = true
        for key in ["v", "c", "x", "a"] {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: 0))
            XCTAssertTrue(view.performKeyEquivalent(with: event))
        }
        XCTAssertEqual(sent, [ScrcpyControl.setClipboard(text, paste: true), Data([8, 1]), Data([8, 2]),
                             ScrcpyControl.key(29, down: true, metaState: 0x1000),
                             ScrcpyControl.key(29, down: false, metaState: 0x1000)])
        sent.removeAll()
        view.controlEnabled = false
        view.copy(nil); view.cut(nil); view.paste(nil); view.selectAll(nil)
        XCTAssertTrue(sent.isEmpty)
        view.controlEnabled = true
        pasteboard.clearContents()
        view.paste(nil)
        XCTAssertTrue(sent.isEmpty, "An image-only or empty clipboard must not paste stale Android text")
    }
}
