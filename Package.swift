// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "WindowRestore",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "WindowRestore", path: "Sources/WindowRestore")
    ]
)
