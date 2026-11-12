// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Tauross",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Tauross", targets: ["Tauross"])],
    targets: [
        .executableTarget(name: "Tauross", path: "Tauross", resources: [.copy("Resources")]),
        .testTarget(name: "TaurossTests", dependencies: ["Tauross"], path: "Tests/TaurossTests")
    ],
    swiftLanguageModes: [.v5]
)
