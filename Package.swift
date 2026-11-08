// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "hobo",
    // macOS 27 for DiskImageKit and guest provisioning.
    platforms: [.macOS(.v27)],
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
        .target(
            name: "HoboVM",
            dependencies: ["HoboCore", "HoboControl"],
            // Compiled in: `make install` copies only the binary, so a resource bundle wouldn't follow it.
            resources: [.embedInCode("Resources/Signs"), .embedInCode("Resources/Windows")],
            // For `ucal_getWindowsTimeZoneID`, which Foundation doesn't surface.
            linkerSettings: [.linkedLibrary("icucore")],
            plugins: ["WindowsBootPlugin", "HoboAgentPlugin"]
        ),
        .plugin(name: "WindowsBootPlugin", capability: .buildTool()),
        .plugin(name: "HoboAgentPlugin", capability: .buildTool()),
        .target(name: "HoboMCP", dependencies: ["HoboCore", "HoboControl"]),
        .executableTarget(
            name: "hobo",
            dependencies: [
                "HoboCore", "HoboControl", "HoboVM", "HoboMCP",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(name: "HoboCoreTests", dependencies: ["HoboCore"]),
        .testTarget(name: "HoboControlTests", dependencies: ["HoboControl", "HoboCore"]),
        .testTarget(name: "hoboTests", dependencies: ["hobo"]),
        .testTarget(name: "HoboVMTests", dependencies: ["HoboCore", "HoboControl", "HoboVM"]),
    ]
)
