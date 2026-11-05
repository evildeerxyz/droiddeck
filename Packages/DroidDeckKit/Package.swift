// swift-tools-version:6.0
import PackageDescription

// DroidDeckKit holds every non-UI layer of DroidDeck. Each target maps to one
// architectural module; the dependency graph below is the only allowed
// direction of calls (UI → Services → Runtime → SDK/ADB/gRPC → Platform → Core).
let package = Package(
    name: "DroidDeckKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "DroidDeckKit", targets: ["DroidDeckKit"]),
    ],
    targets: [
        // Domain model, configuration validation, capabilities. No I/O.
        .target(name: "DDCore"),
        // Processes, host metrics, logging/redaction, filesystem safety, ports.
        .target(name: "DDPlatform", dependencies: ["DDCore"]),
        // JSON stores for device metadata, preferences, operation history.
        .target(name: "DDPersistence", dependencies: ["DDCore", "DDPlatform"]),
        // SDK discovery, system images, device profiles, AVD files, skins.
        .target(name: "DDAndroidSDK", dependencies: ["DDCore", "DDPlatform"]),
        // adb client: devices, shell, install, files, logcat, screenshots.
        .target(name: "DDADB", dependencies: ["DDCore", "DDPlatform"]),
        // Dependency-free HTTP/2 + gRPC client for the emulator controller.
        .target(name: "DDEmulatorGRPC"),
        // Runtime adapter protocol and the Android Emulator implementation.
        .target(
            name: "DDRuntime",
            dependencies: ["DDCore", "DDPlatform", "DDAndroidSDK", "DDADB", "DDEmulatorGRPC"]
        ),
        // Application services consumed by the UI.
        .target(
            name: "DDServices",
            dependencies: [
                "DDCore", "DDPlatform", "DDPersistence", "DDAndroidSDK",
                "DDADB", "DDEmulatorGRPC", "DDRuntime",
            ]
        ),

        // Umbrella re-exporting every layer to the app target.
        .target(
            name: "DroidDeckKit",
            dependencies: [
                "DDCore", "DDPlatform", "DDPersistence", "DDAndroidSDK",
                "DDADB", "DDEmulatorGRPC", "DDRuntime", "DDServices",
            ]
        ),

        .testTarget(name: "DDCoreTests", dependencies: ["DDCore"]),
        .testTarget(name: "DDPlatformTests", dependencies: ["DDPlatform"]),
        .testTarget(name: "DDAndroidSDKTests", dependencies: ["DDAndroidSDK", "DDPlatform"]),
        .testTarget(name: "DDADBTests", dependencies: ["DDADB"]),
        .testTarget(name: "DDEmulatorGRPCTests", dependencies: ["DDEmulatorGRPC"]),
        .testTarget(
            name: "DDServicesTests",
            dependencies: ["DDServices", "DDPersistence", "DDRuntime", "DDCore"]
        ),
        // Runs against the real SDK and boots real emulators.
        // Opt in with DROIDDECK_INTEGRATION=1 (see docs/TESTING.md).
        .testTarget(
            name: "DDIntegrationTests",
            dependencies: ["DDServices", "DDRuntime", "DDAndroidSDK", "DDADB", "DDEmulatorGRPC", "DDCore", "DDPlatform"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
