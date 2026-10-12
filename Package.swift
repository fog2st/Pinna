// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Pinna",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Pinna", path: "Sources/Pinna"),
        .testTarget(name: "PinnaTests", dependencies: ["Pinna"], path: "Tests/PinnaTests"),
    ]
)
