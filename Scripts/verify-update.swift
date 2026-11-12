import Foundation
import CryptoKit

// Independent public-key verification of the exact files CI will publish.
func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw NSError(domain: "TaurossUpdate", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

do {
    guard CommandLine.arguments.count == 4 else { throw NSError(domain: "Usage: verify-update appcast.xml archive.zip Info.plist", code: 1) }
    let feed = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
    let archiveURL = URL(fileURLWithPath: CommandLine.arguments[2])
    let archive = try Data(contentsOf: archiveURL)
    let infoData = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3]))
    let info = try PropertyListSerialization.propertyList(from: infoData, format: nil) as! [String: Any]
    let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: Data(base64Encoded: info["SUPublicEDKey"] as! String)!)
    let prefix = Data("<!-- sparkle-signatures:\n".utf8)
    guard let marker = feed.range(of: prefix, options: .backwards),
          let block = String(data: feed[marker.upperBound...], encoding: .utf8) else {
        throw NSError(domain: "Missing signed appcast", code: 1)
    }
    let content = feed[..<marker.lowerBound]
    let fields = Dictionary(block.split(separator: "\n").compactMap { line -> (String, String)? in
        let parts = line.split(separator: ":", maxSplits: 1)
        return parts.count == 2 ? (String(parts[0]), parts[1].trimmingCharacters(in: .whitespaces)) : nil
    }, uniquingKeysWith: { _, new in new })
    try require(fields["length"].flatMap(Int.init) == content.count, "Appcast content length mismatch")
    guard let signature = fields["edSignature"].flatMap({ Data(base64Encoded: $0) }) else {
        throw NSError(domain: "Missing feed signature", code: 1)
    }
    try require(publicKey.isValidSignature(signature, for: content), "Invalid feed signature or wrong signing key")
    let xml = try XMLDocument(data: Data(content))
    let items = try xml.nodes(forXPath: "/rss/channel/item")
    try require(items.count == 1, "Expected exactly one current release in the feed")
    let item = items[0] as! XMLElement
    let version = info["CFBundleVersion"] as! String
    let shortVersion = info["CFBundleShortVersionString"] as! String
    try require(item.elements(forName: "sparkle:version").first?.stringValue == version, "Feed build version mismatch")
    try require(item.elements(forName: "sparkle:shortVersionString").first?.stringValue == shortVersion, "Feed display version mismatch")
    try require(item.elements(forName: "sparkle:minimumSystemVersion").first?.stringValue == info["LSMinimumSystemVersion"] as? String, "Minimum macOS version mismatch")
    let enclosures = item.elements(forName: "enclosure")
    try require(enclosures.count == 1, "Expected one full update archive")
    let enclosure = enclosures[0]
    let expectedURL = "https://github.com/Duy-Company/tauross/releases/download/v\(shortVersion)/\(archiveURL.lastPathComponent)"
    try require(enclosure.attribute(forName: "url")?.stringValue == expectedURL, "Unexpected update download URL")
    try require(enclosure.attribute(forName: "length")?.stringValue.flatMap(Int.init) == archive.count, "Archive length mismatch")
    guard let zipSignature = enclosure.attribute(forName: "sparkle:edSignature")?.stringValue.flatMap({ Data(base64Encoded: $0) }) else {
        throw NSError(domain: "Missing archive signature", code: 1)
    }
    try require(publicKey.isValidSignature(zipSignature, for: archive), "Invalid archive signature")
    print("Verified signed feed, archive, versions, and release URL against the app's public key.")
} catch {
    fputs("Update verification failed: \(error.localizedDescription)\n", stderr)
    exit(1)
}
