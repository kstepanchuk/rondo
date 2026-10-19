// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Rondo",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Rondo",
            path: "Sources/Rondo",
            swiftSettings: [.unsafeFlags(["-swift-version", "5"])]
        )
    ]
)
