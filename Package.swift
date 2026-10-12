// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Pinna",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Pinna", path: "Sources/Pinna")
    ]
)
