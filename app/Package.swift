// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AwalTerminal",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "AwalTerminalLib", targets: ["AwalTerminalLib"]),
    ],
    targets: [
        .systemLibrary(
            name: "CAwalTerminal",
            path: "Sources/CAwalTerminal"
        ),
        .target(
            name: "AwalTerminalLib",
            dependencies: ["CAwalTerminal"],
            path: "Sources/AwalTerminalLib",
            exclude: ["App/Resources"],
            linkerSettings: [
                .unsafeFlags([
                    "-L", "../core/target/universal-release",
                    "-L", "../core/target/debug",
                    "-L", "../core/target/release",
                    "-lawalterminal",
                ]),
                .linkedFramework("AppKit"),
                .linkedFramework("Metal"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Speech"),
            ]
        ),
        .executableTarget(
            name: "AwalTerminal",
            dependencies: ["AwalTerminalLib"],
            path: "Sources/AwalTerminalApp"
        ),
        .testTarget(
            name: "AwalTerminalTests",
            dependencies: ["AwalTerminalLib"],
            path: "Tests/AwalTerminalTests"
        ),
    ]
)
