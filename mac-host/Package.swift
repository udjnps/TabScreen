// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TabScreenHost",
    platforms: [
        .macOS("13.0")
    ],
    targets: [
        .target(
            name: "CGVirtualDisplayBridgeObjC",
            path: "Sources/TabScreenHost",
            sources: [
                "CGVirtualDisplayBridge.m"
            ],
            publicHeadersPath: ".",
            cSettings: [
                .headerSearchPath(".")
            ]
        ),
        .executableTarget(
            name: "TabScreenHost",
            dependencies: ["CGVirtualDisplayBridgeObjC"],
            path: "Sources/TabScreenHost",
            sources: [
                "DisplayArranger.swift",
                "ScreenStreamer.swift",
                "InputInjector.swift",
                "NetworkServer.swift",
                "USBWatcher.swift",
                "WirelessManager.swift",
                "MenuBarController.swift",
                "AudioManager.swift",
                "WebStreamServer.swift",
                "main.swift"
            ],
            swiftSettings: [
                .unsafeFlags([
                    "-import-objc-header",
                    "Sources/TabScreenHost/TabScreenHost-Bridging-Header.h"
                ])
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("Foundation"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("Network"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox")
            ]
        )
    ],
    swiftLanguageVersions: [.v5]
)
