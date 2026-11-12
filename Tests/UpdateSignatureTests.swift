import Foundation
import CryptoKit

// Ephemeral fixture keys never touch Keychain or the production signing identity.
let key = Curve25519.Signing.PrivateKey()
let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }
let archive = directory.appendingPathComponent("Tauross-1.0.0-macos-universal.zip")
let feed = directory.appendingPathComponent("appcast.xml")
let info = directory.appendingPathComponent("Info.plist")
let payload = Data("signed archive fixture".utf8)
let verifier = URL(fileURLWithPath: CommandLine.arguments[1])
let expectedURL = "https://github.com/Duy-Company/tauross/releases/download/v1.0.0/\(archive.lastPathComponent)"

func writeInfo(publicKey: Data? = nil) throws {
    let metadata = ["SUPublicEDKey": (publicKey ?? key.publicKey.rawRepresentation).base64EncodedString(),
                    "CFBundleVersion": "1.0.0", "CFBundleShortVersionString": "1.0.0", "LSMinimumSystemVersion": "14.0"]
    try PropertyListSerialization.data(fromPropertyList: metadata, format: .xml, options: 0).write(to: info)
}
func writeFeed(url: String? = nil, version: String = "1.0.0", minimumOS: String = "14.0") throws {
    let archiveSignature = try key.signature(for: payload).base64EncodedString()
    let xml = """
    <?xml version="1.0" encoding="utf-8"?>
    <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item>
    <sparkle:version>\(version)</sparkle:version><sparkle:shortVersionString>1.0.0</sparkle:shortVersionString>
    <sparkle:minimumSystemVersion>\(minimumOS)</sparkle:minimumSystemVersion>
    <enclosure url="\(url ?? expectedURL)" length="\(payload.count)" sparkle:edSignature="\(archiveSignature)"/>
    </item></channel></rss>

    """
    let content = Data(xml.utf8)
    let signature = try key.signature(for: content).base64EncodedString()
    try (content + Data("<!-- sparkle-signatures:\nlength:\(content.count)\nedSignature:\(signature)\n-->\n".utf8)).write(to: feed)
}
func check(_ name: String, valid: Bool) throws {
    let process = Process()
    process.executableURL = verifier
    process.arguments = [feed.path, archive.path, info.path]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run(); process.waitUntilExit()
    guard (process.terminationStatus == 0) == valid else { fatalError("Signature verification failed: \(name)") }
    print("Passed: \(name)")
}

try writeInfo(); try payload.write(to: archive); try writeFeed()
try check("valid signed feed and archive", valid: true)
try (Data(" ".utf8) + Data(contentsOf: feed)).write(to: feed)
try check("tampered feed rejected", valid: false)
try writeFeed(); try (payload + Data([0])).write(to: archive)
try check("tampered archive rejected", valid: false)
try payload.write(to: archive); try writeInfo(publicKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation)
try check("wrong public key rejected", valid: false)
try writeInfo(); try writeFeed(url: "https://example.com/untrusted.zip")
try check("foreign download URL rejected", valid: false)
try writeFeed(version: "0.9.0")
try check("wrong version rejected", valid: false)
try writeFeed(minimumOS: "15.0")
try check("wrong minimum macOS rejected", valid: false)
try Data("<rss/>".utf8).write(to: feed)
try check("unsigned feed rejected", valid: false)
