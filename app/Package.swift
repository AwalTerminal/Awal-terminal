// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AwalTerminal",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .systemLibrary(
            name: "CAwalTerminal",
            path: "Sources/CAwalTerminal"
        ),
        .executableTarget(
            name: "AwalTerminal",
            dependencies: ["CAwalTerminal"],
            path: "Sources",
            exclude: ["CAwalTerminal", "App/Resources"],
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
    ]
)
