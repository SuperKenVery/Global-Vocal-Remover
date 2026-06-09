// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "GlobalVocalRemover",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "GlobalVocalRemover", targets: ["GlobalVocalRemover"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-atomics", from: "1.2.0"),
        .package(url: "https://github.com/microsoft/onnxruntime-swift-package-manager", from: "1.24.2")
    ],
    targets: [
        .executableTarget(
            name: "GlobalVocalRemover",
            dependencies: [
                .product(name: "Atomics", package: "swift-atomics"),
                .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager")
            ],
            resources: [.copy("Resources")],
            linkerSettings: [
                .linkedFramework("Accelerate"),
                .linkedFramework("AppKit"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreAudio")
            ]
        )
    ]
)
