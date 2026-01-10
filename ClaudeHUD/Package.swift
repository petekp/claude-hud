// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClaudeHUD",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ClaudeHUD", targets: ["ClaudeHUD"])
    ],
    dependencies: [],
    targets: [
        // System library wrapper for the Rust FFI
        .systemLibrary(
            name: "hud_coreFFI",
            path: "Sources/HudCoreFFI"
        ),
        // Main Swift app
        .executableTarget(
            name: "ClaudeHUD",
            dependencies: ["hud_coreFFI"],
            path: "Sources/ClaudeHUD",
            linkerSettings: [
                .linkedLibrary("hud_core"),
                .unsafeFlags(["-L", "../target/release"])
            ]
        )
    ]
)
