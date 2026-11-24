// swift-tools-version: 6.4
import PackageDescription

/// `--json` output and its encoder (`CLIJSON`), shared with the other tools that follow the convention.
let cliOutput = Target.Dependency.product(name: "CLIOutput", package: "swift-cli-output")

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
        .package(url: "https://github.com/hobo-vm/swift-cli-output", from: "0.1.0"),
    ],
    targets: [
        .target(
            name: "HoboCore",
            dependencies: [.product(name: "TOMLKit", package: "TOMLKit")],
            plugins: ["HoboVersionPlugin"]
        ),
        .target(name: "HoboControl", dependencies: ["HoboCore"]),
        .target(
            name: "HoboVM",
            dependencies: ["HoboCore", "HoboControl", "HoboUICore"],
            // Files, read through `Payloads`: from `share/hobo` beside the installed `bin/hobo`, or
            // SwiftPM's resource bundle in a dev build. The plugins' outputs (agents, hobo-ui, the Windows boot driver) join them.
            resources: [.copy("Resources/Signs"), .copy("Resources/Windows"), .copy("Resources/UI")],
            // For `ucal_getWindowsTimeZoneID`, which Foundation doesn't surface.
            linkerSettings: [.linkedLibrary("icucore")],
            plugins: ["WindowsBootPlugin", "HoboAgentPlugin", "HoboUIPlugin"]
        ),
        // `Hobo.version`, from the checkout's release tags.
        .plugin(name: "HoboVersionPlugin", capability: .buildTool()),
        .plugin(name: "WindowsBootPlugin", capability: .buildTool()),
        .plugin(name: "HoboAgentPlugin", capability: .buildTool()),
        // hobo-ui, the macOS guests' accessibility driver (`hobo ui`), a resource of HoboVM.
        .plugin(name: "HoboUIPlugin", capability: .buildTool(), dependencies: ["hobo-ui"]),
        .target(name: "HoboUICore", dependencies: [.product(name: "ArgumentParser", package: "swift-argument-parser")]),
        .executableTarget(name: "hobo-ui", dependencies: ["HoboUICore"]),
        .target(name: "HoboMCP", dependencies: ["HoboCore", "HoboControl"]),
        .executableTarget(
            name: "hobo",
            dependencies: [
                "HoboCore", "HoboControl", "HoboVM", "HoboMCP", "HoboUICore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                cliOutput,
            ]
        ),
        .testTarget(name: "HoboCoreTests", dependencies: ["HoboCore", cliOutput]),
        .testTarget(name: "HoboControlTests", dependencies: ["HoboControl", "HoboCore", cliOutput]),
        .testTarget(name: "hoboTests", dependencies: ["hobo", cliOutput]),
        .testTarget(name: "HoboUICoreTests", dependencies: ["HoboUICore"]),
        .testTarget(name: "HoboVMTests", dependencies: ["HoboCore", "HoboControl", "HoboVM", "HoboUICore", cliOutput], exclude: ["recipes"]),
    ]
)
