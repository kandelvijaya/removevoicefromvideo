// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VoiceRemoved",
    platforms: [.macOS("15.0")],
    products: [.executable(name: "voice-remove", targets: ["voice-remove"])],
    targets: [
        .target(name: "VoiceRemovedCore", linkerSettings: [.linkedFramework("AudioToolbox")]),
        .executableTarget(name: "voice-remove", dependencies: ["VoiceRemovedCore"]),
        .testTarget(name: "VoiceRemovedCoreTests", dependencies: ["VoiceRemovedCore"])
    ]
)
