// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "hobo",
    // Target is macOS 27 (vmnet topologies, DiskImageKit, guest provisioning).
    // Pinned to 26 until the macOS 27 SDK is available on the build machine.
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "hobo", targets: ["hobo"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.8.0"),
        .package(url: "https://github.com/LebJe/TOMLKit", from: "0.6.0"),
    ],
    targets: [
        .target(
            name: "HoboCore",
            dependencies: [.product(name: "TOMLKit", package: "TOMLKit")]
        ),
        .target(name: "HoboControl", dependencies: ["HoboCore"]),
        .target(name: "HoboVM", dependencies: ["HoboCore", "HoboControl"]),
        .target(name: "HoboMCP", dependencies: ["HoboCore", "HoboControl"]),
        .executableTarget(
            name: "hobo",
            dependencies: [
                "HoboCore", "HoboControl", "HoboVM", "HoboMCP",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(name: "HoboCoreTests", dependencies: ["HoboCore"]),
        .testTarget(name: "HoboVMTests", dependencies: ["HoboVM"]),
    ]
)
