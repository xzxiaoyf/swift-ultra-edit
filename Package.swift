// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SwiftUltraEdit",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "SwiftUltraEdit", targets: ["SwiftUltraEdit"])
    ],
    targets: [
        .executableTarget(
            name: "SwiftUltraEdit",
            path: "Sources/SwiftUltraEdit"
        )
    ]
)
