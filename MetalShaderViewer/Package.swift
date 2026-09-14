// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MetalShaderViewer",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "MetalShaderViewer",
            path: "Sources/MetalShaderViewer",
            swiftSettings: [.unsafeFlags(["-Ounchecked"], .when(configuration: .release))]
        )
    ]
)
