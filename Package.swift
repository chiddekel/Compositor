// swift-tools-version: 5.10
// Compositor — Linux port package manifest.
//
// The macOS app remains an Xcode project (Compositor.xcodeproj). This SwiftPM
// manifest builds the portable Swift core for Linux (and is the home of the
// @_cdecl C ABI seam, ENG-1). Per the autoplan provisional decision (ENG-12),
// the port ships in Swift 5 language mode; a Swift 6 compile spike is a
// tracked follow-up, not a blocker.
//
// Build (under the Freedesktop Swift runtime extension): `swift build`
// This host has no Swift toolchain; `swift build` is run in the SDK.

import PackageDescription

let package = Package(
    name: "Compositor",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(name: "CompositorCore", targets: ["CompositorCore"]),
    ],
    targets: [
        .target(
            name: "CompositorCore",
            path: "Sources/CompositorCore",
            swiftSettings: [
                // ENG-12 provisional decision: Swift 5 language mode for the
                // vertical slice. Switching to .v6 is a tracked follow-up that
                // enforces Sendable data-race safety (aligns with SOLID).
                .unsafeFlags(["-swift-version", "5"]),
            ]
        ),
        .testTarget(
            name: "CompositorCoreTests",
            dependencies: ["CompositorCore"],
            path: "Tests/CompositorCoreTests"
        ),
    ]
)