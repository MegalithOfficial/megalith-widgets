// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MegalithWidgets",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "MegalithWidgets", path: "Sources/MegalithWidgets"),
    ]
)
