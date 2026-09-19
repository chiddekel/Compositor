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
        // Static library so the C++ host (ENG-2 composition root) links the Swift
        // core's @_cdecl symbols in-process; built with --static-swift-stdlib in
        // the Flatpak manifest so the Swift runtime is bundled, not a system dep.
        .library(name: "CompositorCore", type: .static, targets: ["CompositorCore"]),
    ],
    targets: [
        // The portable C pixel kernels (file-map "Keep" tier), reused verbatim from
        // the macOS source tree. The same .c files are ALSO built by CMakeLists.txt
        // for the C++ host and tests; this target makes them callable from the Swift
        // core (brush_alpha_bounds, spot_heal, …) so the two sides share one kernel
        // implementation. COMPOSITOR_PORTABLE turns on the ENG-17 canonical-buffer
        // entry asserts (no-ops on macOS/Xcode, which never defines it).
        .target(
            name: "CompositorKernels",
            path: "Compositor/Rendering",
            exclude: [
                "AdjustmentSurface.swift",
                "BrushCursorOverlay.swift",
                "CanvasViewport.swift",
                "DownsampleCache.swift",
                "EditorCanvas.swift",
                "LayerRenderer.swift",
                "LiveMaskRenderer.swift",
                "MetalBrushCoverage.swift",
                "RasterSnapshot.swift",
                "SampleRingOverlay.swift",
                "SeparableBlend.swift",
                "TiledLayerRenderer.swift",
                "TransformOverlay.swift",
            ],
            publicHeadersPath: ".",
            cSettings: [
                .define("COMPOSITOR_PORTABLE"),
            ]
        ),
        .target(
            name: "CompositorCore",
            dependencies: ["CompositorKernels"],
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
        // ENG-2 composition root, inverted: a Swift `@main` bootstraps the Swift
        // runtime + Foundation (which a C++ main cannot on the Freedesktop Swift
        // 6.3 SDK — see docs/linux-port-file-map.md "composition-root constraint"),
        // then drives the Qt host through a C ABI. This bootstrap target proves
        // the architecture by running the session journey through the real
        // compositor_session_* ABI from a Swift entry point, AND initializes Qt
        // (via the HostRun C++ target) to prove the full Swift-main -> Qt link.
        //
        // HostRun compiles host/host_run.cpp (moc-free) as the Qt host entry
        // compositor_host_run; the Flatpak full build swaps in the CMake-built
        // CompositorHostRun lib (with the real MainWindow + app.exec()). Qt6
        // comes from the KDE SDK at the standard /usr paths.
        .target(
            name: "HostRun",
            dependencies: [],
            path: "host",
            sources: ["host_run.cpp"],
            cxxSettings: [
                .unsafeFlags([
                    "-I/usr/include/QtWidgets",
                    "-I/usr/include/QtCore",
                    "-I/usr/include/QtGui",
                    "-DQT_CORE_LIB", "-DQT_GUI_LIB", "-DQT_WIDGETS_LIB",
                ]),
            ]
        ),
        .executableTarget(
            name: "CompositorHostBootstrap",
            dependencies: ["CompositorCore", "HostRun"],
            path: "Sources/CompositorHostBootstrap",
            swiftSettings: [.unsafeFlags(["-swift-version", "5"])],
            linkerSettings: [
                .linkedLibrary("Qt6Widgets"),
                .linkedLibrary("Qt6Gui"),
                .linkedLibrary("Qt6Core"),
                .unsafeFlags(["-L/usr/lib/x86_64-linux-gnu",
                              "-Xlinker", "-rpath", "-Xlinker", "/usr/lib/x86_64-linux-gnu"]),
            ]
        ),
    ]
)