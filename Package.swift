// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MixWebDeploy",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "MixWebDeploy", targets: ["MixWebDeploy"])
    ],
    targets: [
        .executableTarget(
            name: "MixWebDeploy",
            path: "Sources/MixWebDeploy"
        )
    ],
    swiftLanguageModes: [.v5]
)
