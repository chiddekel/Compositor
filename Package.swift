// swift-tools-version: 6.2
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
import Foundation

// The pinned OpenCV (third_party/opencv.pinned: 4.14.0, static core + imgproc) lives under /app in the Flatpak build and
// under build/opencv/install when built locally with the manifest's options. The OpenCV tier of the layer-effects chain
// compiles only when its headers are there, and links the static libraries from the same prefix.
let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let opencvPrefix: String? = ["\(packageRoot)/build/opencv/install", "/app"].first {
    FileManager.default.fileExists(atPath: "\($0)/include/opencv4/opencv2/imgproc.hpp")
}
let opencvLibrary: String? = opencvPrefix.flatMap { prefix in
    ["lib64", "lib"].map { "\(prefix)/\($0)" }.first { FileManager.default.fileExists(atPath: "\($0)/libopencv_core.a") }
}
// (SwiftPM caches this manifest's evaluation by its content: after building OpenCV locally, build once with
// `--manifest-cache none` so these file checks run again.)
// OpenCV's DNN module (same prefix, when the build enabled it — scripts/build-opencv.sh, the manifest's `opencv`): runs
// U²-Net-small for the Vision compat's subject segmentation (backends/vision).
let opencvHasDNN: Bool = opencvPrefix.map { prefix in
    FileManager.default.fileExists(atPath: "\(prefix)/include/opencv4/opencv2/dnn.hpp")
        && opencvLibrary.map { FileManager.default.fileExists(atPath: "\($0)/libopencv_dnn.a") } == true
} ?? false
// The pinned LibRaw (scripts/build-libraw.sh / the manifest's `libraw` module: static, OpenMP) — camera RAW decoding for
// the host (host/RawDecoder.cpp compiles its decoder only when the header is there).
// OpenEXR (scripts/build-openexr.sh, or the Flatpak's openexr module): EXR import and export in host/QtImageIO.cpp,
// static, with its Imath and libdeflate.
let openexrPrefix: String? = ["\(packageRoot)/build/openexr/install", "/app"].first {
    FileManager.default.fileExists(atPath: "\($0)/include/OpenEXR/ImfRgbaFile.h") && FileManager.default.fileExists(atPath: "\($0)/lib/libOpenEXR-3_5.a")
}
let openexrLibraries: [String] = openexrPrefix.map { prefix in
    ["libOpenEXR-3_5.a", "libOpenEXRCore-3_5.a", "libIex-3_5.a", "libIlmThread-3_5.a", "libImath-3_2.a", "libdeflate.a"].map { "\(prefix)/lib/\($0)" }
} ?? []
let librawPrefix: String? = ["\(packageRoot)/build/libraw/install", "/app"].first {
    FileManager.default.fileExists(atPath: "\($0)/include/libraw/libraw.h") && FileManager.default.fileExists(atPath: "\($0)/lib/libraw_r.a")
}
import Foundation

// LibRaw built with RawSpeed (scripts/build-rawspeed.sh, then scripts/build-libraw.sh): RawSpeed's static libraries
// link after LibRaw's, and RawDecoder.cpp turns it on (LIBRAW_WITH_RAWSPEED3).
let rawspeedLibraries: [String] = librawPrefix.flatMap { prefix -> [String]? in
    guard FileManager.default.fileExists(atPath: "\(prefix)/include/libraw/rawspeed3-enabled"),
          let directory = ["\(packageRoot)/build/rawspeed/install/lib", "\(prefix)/lib"].first(where: {
              FileManager.default.fileExists(atPath: "\($0)/librawspeed3_capi.a")
          }) else { return nil }
    return ["librawspeed3_capi.a", "librawspeed.a", "libpugixml.a"].map { "\(directory)/\($0)" }
        .filter { FileManager.default.fileExists(atPath: $0) }
} ?? []

let package = Package(
    name: "Compositor",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        // Static library so the C++ host (ENG-2 composition root) links the Swift
        // core's @_cdecl symbols in-process; built with --static-swift-stdlib in
        // the Flatpak manifest so the Swift runtime is bundled, not a system dep.
        .library(name: "CompositorCore", type: .static, targets: ["Compositor"]),
    ],
    targets: [
        .target(name: "CompositorSelectionBackend", path: "backends/selection", publicHeadersPath: "include"),
        // Layer effects (stroke / shadow / overlay / inner shadow): the C tier and the Vulkan tier of the chain that
        // Sources/Overrides/MetalLayerEffects.swift fronts. Same nine passes as upstream's Metal kernels.
        .target(name: "CompositorEffectsBackend", path: "backends/effects",
            exclude: ["shaders/effects.comp"],
            sources: ["EffectsCPU.cpp", "EffectsVulkan.cpp", "EffectsOpenCV.cpp"], publicHeadersPath: "include",
            cxxSettings: opencvPrefix.map { [.unsafeFlags(["-DCOMPOSITOR_HAS_OPENCV", "-I\($0)/include/opencv4"])] } ?? [],
            linkerSettings: [.linkedLibrary("vulkan")] + (opencvLibrary.map { library in [
                .unsafeFlags(["-L\(library)", "-L\(library)/opencv4/3rdparty"]),
                .linkedLibrary("opencv_imgproc"), .linkedLibrary("opencv_core"), .linkedLibrary("zlib"),
                .linkedLibrary("dl"), .linkedLibrary("pthread"),
            ] } ?? [])),
        // Subject segmentation (Select Subject, Remove Background): U²-Net-small through OpenCV DNN; without the DNN
        // module it builds as stubs and the Vision compat keeps its classical segmenter.
        .target(name: "CompositorVisionBackend", path: "backends/vision", sources: ["U2NetSegmenter.cpp"],
            publicHeadersPath: "include",
            cxxSettings: opencvHasDNN ? [.unsafeFlags(["-DCOMPOSITOR_HAS_OPENCV_DNN", "-I\(opencvPrefix!)/include/opencv4"])] : [],
            linkerSettings: opencvHasDNN ? [
                .unsafeFlags(["-L\(opencvLibrary!)", "-L\(opencvLibrary!)/opencv4/3rdparty"]),
                .linkedLibrary("opencv_dnn"), .linkedLibrary("opencv_imgproc"), .linkedLibrary("opencv_core"),
                .linkedLibrary("libprotobuf"), .linkedLibrary("zlib"), .linkedLibrary("dl"), .linkedLibrary("pthread"),
            ] : []),
        .target(name: "CompositorBrushBackend", path: "backends/brush",
            exclude: ["shaders/continuous_brush.comp", "shaders/warp_smudge.comp", "shaders/warp_liquify.comp",
                "shaders/warp_smudge_packed.comp", "shaders/warp_liquify_packed.comp", "shaders/warp_formats.glsl", "shaders/warp_precision.glsl"],
            sources: ["BrushCoverageCPU.cpp", "VulkanBrushCoverage.cpp", "VulkanSmudge.cpp"],
            publicHeadersPath: "include", linkerSettings: [.linkedLibrary("vulkan")]),
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
                "CanvasLinesOverlay.swift",
                "CanvasViewport.swift",
                "DownsampleCache.swift",
                "EditorCanvas.swift",
                "EffectsPreviewCache.swift",
                "GPUCanvas.swift",
                "GPUNoise.swift",
                "InlineTextEditor.swift",
                "LayerEffectsSurface.swift",
                "LayerRenderer.swift",
                "LiveMaskRenderer.swift",
                "MetalBrushCoverage.swift",
                "MetalCameraRawLookup.swift",
                "MetalLayerEffects.swift",
                "MetalWarp.swift",
                "NavigatorGeometry.swift",
                "RasterSnapshot.swift",
                "SampleRingOverlay.swift",
                "SeparableBlend.swift",
                "TiledLayerRenderer.swift",
                "TransformOverlay.swift",
                // Built through linux/kernels/DitherPixelsLinux.c (serial dispatch_apply).
                "DitherPixels.c",
            ],
            publicHeadersPath: ".",
            cSettings: [
                .define("COMPOSITOR_PORTABLE"),
                // Tip 1.4.9 AdjustPixels.c splits work with dispatch_apply blocks: the toolchain's own libdispatch.
                .unsafeFlags([
                    "-fblocks",
                    "-I/usr/lib/sdk/swift6/lib/swift",
                    "-I/usr/lib/sdk/swift6/lib/swift/Block",
                ]),
            ],
            linkerSettings: [
                .unsafeFlags(["-L/usr/lib/sdk/swift6/lib/swift/linux"]),
                .linkedLibrary("dispatch"),
                .linkedLibrary("BlocksRuntime"),
            ]
        ),
        // Tip DitherPixels.c with a serial dispatch_apply so Scanlines glow matches macOS on Linux.
        .target(
            name: "CompositorDitherKernel",
            dependencies: [],
            path: "linux/kernels",
            exclude: [
                "CheckedAdjustPixels.c", "CheckedBrushPixels.c", "CheckedPatchPixels.c",
                "CheckedHealPixels.c", "CheckedLensPixels.c", "CheckedNoisePixels.c", "CheckedWandPixels.c",
                "CompositorKernelChecks.h",
            ],
            sources: ["DitherPixelsLinux.c"],
            publicHeadersPath: "include",
            cSettings: [
                .define("COMPOSITOR_PORTABLE"),
                .headerSearchPath("../../Compositor/Rendering"),
                .headerSearchPath("."),   // stub linux/kernels/dispatch/dispatch.h
                .unsafeFlags([
                    "-fblocks",
                    "-I/usr/lib/sdk/swift6/lib/swift/Block",
                ]),
            ],
            linkerSettings: [
                .unsafeFlags(["-L/usr/lib/sdk/swift6/lib/swift/linux"]),
                .linkedLibrary("BlocksRuntime"),
            ]
        ),
        // Apple CoreGraphics API surface for Linux (CGContext/CGImage/CGPath/... over Skia, pure-Swift failsafe).
        // Named exactly like the Apple framework so upstream macOS sources compile with `import CoreGraphics`.
        // It must not depend on any document/domain type (see docs/upstream-shim-worklist.md).
        // ICC colour management (CMYK colour spaces and contexts, ColorSync) over the runtime's LittleCMS 2.
        .target(name: "CompositorColorManagement", path: "backends/colormanagement", publicHeadersPath: "include",
                linkerSettings: [.linkedLibrary("lcms2")]),
        .target(name: "CompositorCameraRawBackend", path: "backends/cameraraw", exclude: ["shaders/lookup.comp"],
                sources: ["VulkanCameraRaw.cpp"], publicHeadersPath: "include", linkerSettings: [.linkedLibrary("vulkan")]),
        // ColorSync's profile calls (CMYK profile names), over the same LittleCMS backend.
        .target(name: "ColorSync", dependencies: ["CompositorColorManagement"], path: "Sources/Compat/ColorSync",
                swiftSettings: [.unsafeFlags(["-swift-version", "5"])]),
        .target(
            name: "CoreGraphics",
            dependencies: ["CompatSupport", "CompositorColorManagement"],
            path: "Sources/Compat/CoreGraphics",
            swiftSettings: [.unsafeFlags(["-swift-version", "5"])]
        ),
        // ServiceSlot: the one mechanism the compat modules use to expose a replaceable implementation (install / override).
        .target(name: "CompatSupport", path: "Sources/Compat/CompatSupport",
                swiftSettings: [.unsafeFlags(["-swift-version", "5"])]),
        // Foundation gaps (FileWrapper, NSFileCoordinator, security-scoped URLs), UTType and the headless AppKit
        // surface upstream's model code touches. Each is one Apple framework (interface segregation).
        .systemLibrary(name: "CSQLite", path: "Sources/CSQLite", pkgConfig: "sqlite3"),
        .systemLibrary(name: "CLibXML2", path: "Sources/CLibXML2", pkgConfig: "libxml-2.0"),
        .systemLibrary(name: "CLZMA", path: "Sources/CLZMA", pkgConfig: "liblzma"),
        .target(name: "FoundationCompat", dependencies: ["UniformTypeIdentifiers", "CSQLite", "CLZMA"], path: "Sources/Compat/FoundationCompat",
                swiftSettings: [.unsafeFlags(["-swift-version", "5"])]),
        .target(name: "Accelerate", path: "Sources/Compat/Accelerate",
                swiftSettings: [.unsafeFlags(["-swift-version", "5"])]),
        .target(name: "ImageIO", dependencies: ["CoreGraphics", "Accelerate", "UniformTypeIdentifiers", "CompatSupport", "CompositorColorManagement"],
                path: "Sources/Compat/ImageIO", swiftSettings: [.unsafeFlags(["-swift-version", "5"])]),
        .target(name: "Vision", dependencies: ["CoreGraphics", "CoreVideo", "CompatSupport"], path: "Sources/Compat/Vision",
                swiftSettings: [.unsafeFlags(["-swift-version", "5"])]),
        .target(name: "Combine", path: "Sources/Compat/Combine", swiftSettings: [.unsafeFlags(["-swift-version", "5"])]),
        .target(name: "Sparkle", path: "Sources/Compat/Sparkle", swiftSettings: [.unsafeFlags(["-swift-version", "5"])]),
        .target(name: "SwiftUI", dependencies: ["CoreGraphics", "AppKit", "Combine", "FoundationCompat", "CompatSupport"], path: "Sources/Compat/SwiftUI",
                swiftSettings: [.unsafeFlags(["-swift-version", "5"])]),
        .target(name: "CoreVideo", path: "Sources/Compat/CoreVideo", swiftSettings: [.unsafeFlags(["-swift-version", "5"])]),
        // Metal type surface for Linux (CPU-backed MTLTexture/Device) so tip GPUCanvasTests compile.
        .target(name: "Metal", dependencies: ["CoreGraphics"], path: "Sources/Compat/Metal",
                swiftSettings: [.unsafeFlags(["-swift-version", "5"])]),
        .target(name: "CoreImageKernels", path: "backends/coreimage", exclude: ["shaders/raster.comp", "shaders/raster_fused.comp", "shaders/raster_ops.glsl"], sources: ["Gaussian.c", "GaussianFFT.c", "Motion.c", "VulkanRaster.cpp"],
                publicHeadersPath: "include", cSettings: [.unsafeFlags(["-ffp-contract=off"])], linkerSettings: [.linkedLibrary("vulkan")]),
        .target(name: "CoreImage", dependencies: ["CoreGraphics", "CoreVideo", "CompatSupport", "CoreImageKernels"], path: "Sources/Compat/CoreImage",
                swiftSettings: [.unsafeFlags(["-swift-version", "5"])]),
        // CoreText: single-line drawing over the Qt text engine (upstream's Dither ASCII glyphs).
        .target(name: "CoreText", dependencies: ["AppKit", "CoreGraphics"], path: "Sources/Compat/CoreText",
                swiftSettings: [.unsafeFlags(["-swift-version", "5"])]),
        // CryptoKit: SHA256 with Apple's API over a portable implementation (upstream's ProjectDigest).
        .target(name: "CryptoKit", path: "Sources/Compat/CryptoKit"),
        .target(name: "UniformTypeIdentifiers", path: "Sources/Compat/UniformTypeIdentifiers",
                swiftSettings: [.unsafeFlags(["-swift-version", "5"])]),
        .target(name: "AppKit", dependencies: ["CoreGraphics", "FoundationCompat", "UniformTypeIdentifiers", "ImageIO", "CompatSupport", "CLibXML2"],
                path: "Sources/Compat/AppKit", swiftSettings: [.unsafeFlags(["-swift-version", "5"])]),
        .target(name: "_Testing_AppKit", path: "Sources/Compat/TestingOverlays/_Testing_AppKit"),
        .target(name: "_Testing_CoreGraphics", path: "Sources/Compat/TestingOverlays/_Testing_CoreGraphics"),
        .target(name: "_Testing_CoreImage", path: "Sources/Compat/TestingOverlays/_Testing_CoreImage"),
        // Test-process environment Xcode's runner provides (XCTestConfigurationFilePath); see its .c file.
        .target(name: "_Testing_XCTestEnvironment", path: "Sources/Compat/TestingOverlays/_Testing_XCTestEnvironment"),
        .target(name: "_Testing_AppHost", dependencies: ["AppKit", "CoreGraphics"], path: "Sources/Compat/TestingOverlays/_Testing_AppHost",
                swiftSettings: [.unsafeFlags(["-swift-version", "5"])]),
        // The unmodified macOS editor core (Compositor/{Document,IO,Rendering}) as the module `Compositor`, so upstream's
        // own tests (`@testable import Compositor`) run against it. Files are reached through symlinks in
        // Sources/UpstreamCore; nothing under Compositor/ is edited. Excluded: view/app code the Qt shell replaces
        // and the two Metal files, which Sources/Overrides replaces with same-API Vulkan/CPU implementations.
        // SmudgeLiquify's generated override caches the unchanged tip falloff; its upstream class is a test oracle.
        // Xcode's own settings apply: Swift 5 mode, default actor isolation MainActor, approachable concurrency.
        .target(
            name: "Compositor",
            dependencies: ["CoreGraphics", "AppKit", "SwiftUI", "Combine", "Sparkle", "CoreImage", "ImageIO", "Accelerate", "CoreVideo", "Vision", "UniformTypeIdentifiers", "FoundationCompat", "CryptoKit", "CoreText", "Metal", "ColorSync"] + ["CompositorKernels", "CompositorDitherKernel", "CompositorBrushBackend", "CompositorEffectsBackend", "CompositorVisionBackend", "CompositorSelectionBackend", "CompositorCameraRawBackend", "CompatSupport"],
            path: "Sources/UpstreamCore",
            exclude: ["Rendering/AdjustPixels.c",
                     "Rendering/AdjustPixels.h",
                     "Rendering/BrushPixels.c",
                     "Rendering/BrushPixels.h",
                     "Rendering/PatchPixels.c",
                     "Rendering/PatchPixels.h",
                     "Rendering/DeepPixels.c",
                     "Rendering/DeepPixels.h",
                     "Rendering/DitherPixels.c",
                     "Rendering/DitherPixels.h",
                     "Rendering/HealPixels.c",
                     "Rendering/HealPixels.h",
                     "Rendering/LensPixels.c",
                     "Rendering/LensPixels.h",
                     "Rendering/LevelsPixels.c",
                     "Rendering/LevelsPixels.h",
                     "Rendering/NoisePixels.c",
                     "Rendering/NoisePixels.h",
                     "Rendering/WandPixels.c",
                     "Rendering/WandPixels.h",
                     "IO/CompositorApplicationDelegate.swift",
                     // Tip 1.4.9 Sparkle user driver (its own AppKit update alert); Linux updates through Flatpak.
                     "IO/UpdateDriver.swift",
                     "Document/EditorSession.swift",
                     "Document/SmudgeLiquify.swift",
                     "Document/ColorRangeSelection.swift",
                     "Rendering/MetalBrushCoverage.swift",
                     "Rendering/MetalCameraRawLookup.swift",
                     "Rendering/MetalLayerEffects.swift",
                     "Rendering/MetalWarp.swift",
                     "Rendering/GPUCanvas.swift",
                     "Rendering/GPUNoise.swift",
                     "Rendering/InlineTextEditor.swift",
                     "Rendering/TransformOverlay.swift",
                     "UI/ProjectTabs.swift",
                     "UI/LayerMaskMenu.swift",
                     "UI/RawDevelopSheet.swift"],
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .defaultIsolation(MainActor.self),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
                .enableUpcomingFeature("InferSendableFromCaptures"),
                // Upstream's Swift reaches the C kernels through a bridging header (no imports), and Foundation-only
                // files use the Foundation gaps FoundationCompat fills; both become implicit module imports.
                .unsafeFlags([                              "-Xfrontend", "-import-module", "-Xfrontend", "FoundationCompat",
                              "-Xfrontend", "-import-module", "-Xfrontend", "CompositorKernels",
                              "-Xfrontend", "-import-module", "-Xfrontend", "CoreImage",
                              "-Xfrontend", "-import-module", "-Xfrontend", "Metal",
                              // Apple's closure-taking APIs (Timer, Dispatch) do not check main-actor state against
                              // Sendable in Swift 5 mode; corelibs' do. Minimal checking matches Xcode's behaviour.
                              "-strict-concurrency=minimal"]),
            ]
        ),
        // Upstream's own test suite, unmodified (Swift Testing), run against the module above.
        .testTarget(
            name: "CompositorUpstreamTests",
            dependencies: ["Compositor", "CompositorKernels", "_Testing_AppKit", "_Testing_CoreGraphics", "_Testing_CoreImage", "_Testing_XCTestEnvironment", "_Testing_AppHost"] + ["CoreGraphics", "AppKit", "SwiftUI", "CoreImage", "ImageIO", "Accelerate", "CoreVideo", "Vision", "UniformTypeIdentifiers", "FoundationCompat", "Metal"],
            path: "CompositorTests",
            // Upstream tests that cannot run on Linux yet (Objective-C selectors and swizzling in the test itself, the
            // real layer table, the app's own window): listed in linux/UPSTREAM_TEST_EXCLUSIONS.md, never edited.
            exclude: ["LayerTests.swift", "KeyboardShortcutTests.swift"],
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
                .enableUpcomingFeature("InferSendableFromCaptures"),
                // As in the Mac test target: the bridging header's C kernels, and Core Image through AppKit.
                .unsafeFlags(["-Xfrontend", "-import-module", "-Xfrontend", "FoundationCompat",
                              "-Xfrontend", "-import-module", "-Xfrontend", "CompositorKernels",
                              "-Xfrontend", "-import-module", "-Xfrontend", "CoreImage",
                              "-Xfrontend", "-import-module", "-Xfrontend", "Metal"]),
            ],
            // The test-only _Testing_AppHost overlay is reached by name (dlsym from compat AppKit's lazy test-host
            // window hook), not by a link-time dependency: AppKit must not depend on it. dlsym only sees .dynsym, so
            // the test binary has to export its symbols.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-export-dynamic"])]
        ),
        // Tests of Linux-owned code that lives inside the Compositor module (the Sources/Overrides stand-ins), checked
        // against upstream's own behaviour.
        .testTarget(
            name: "LinuxOverrideTests",
            dependencies: ["Compositor", "_Testing_AppKit", "_Testing_CoreGraphics", "_Testing_CoreImage", "CompatSupport"] + ["CoreGraphics", "AppKit", "SwiftUI", "CoreImage", "ImageIO", "UniformTypeIdentifiers", "FoundationCompat"],
            path: "Tests/LinuxOverrideTests",
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
                .enableUpcomingFeature("InferSendableFromCaptures"),
                .unsafeFlags(["-Xfrontend", "-import-module", "-Xfrontend", "FoundationCompat"]),
            ],
            // Same -export-dynamic as CompositorUpstreamTests: both merge into one test binary.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-export-dynamic"])]
        ),
        .testTarget(
            name: "CompatTests",
            dependencies: ["CoreGraphics", "CompatSupport", "CompositorBrushBackend", "AppKit", "FoundationCompat", "CSQLite", "CLibXML2", "UniformTypeIdentifiers", "Accelerate", "ImageIO", "CoreImage", "CoreVideo", "Vision", "SwiftUI"],
            path: "Tests/CompatTests"
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
            sources: ["host_run.cpp", "SessionWindow.cpp", "DialogJourney.cpp", "InterchangeJourney.cpp", "SessionDialogs.cpp", "SizeDialog.cpp", "FilterDialog.cpp", "AdjustDialog.cpp", "ImageExporters.cpp", "TabletHandler.cpp", "QtImageIO.cpp", "RawDecoder.cpp", "RawLensJourney.cpp", "FlatpakUpdateService.cpp", "SwiftUIQtRenderer.cpp", "moc_SessionWindow.cpp", "moc_FlatpakUpdateService.cpp"],
            cxxSettings: [
                .unsafeFlags([
                    "-I/usr/include/QtWidgets",
                    "-I/usr/include/QtCore",
                    "-I/usr/include/QtGui",
                    "-I/usr/include/QtDBus",
                    "-I/usr/include/QtSvg",
                    "-DQT_CORE_LIB", "-DQT_GUI_LIB", "-DQT_WIDGETS_LIB", "-DQT_DBUS_LIB",
                ] + (librawPrefix.map { ["-I\($0)/include"] } ?? []) + (rawspeedLibraries.isEmpty ? [] : ["-DLIBRAW_WITH_RAWSPEED3"])
                  + (openexrPrefix.map { ["-I\($0)/include", "-I\($0)/include/OpenEXR", "-I\($0)/include/Imath", "-DCOMPOSITOR_HAS_OPENEXR=1"] } ?? [])),
            ],
            // QtImageIO.cpp routes HEIF/HEIC/AVIF through libheif when its header is installed (`__has_include`), so
            // the link follows the same condition; RawDecoder.cpp likewise with LibRaw (static, plus OpenMP's runtime).
            // OtherApplications.h (Hide Others / Show All) uses xcb when its header is installed.
            linkerSettings: (FileManager.default.fileExists(atPath: "/usr/include/libheif/heif.h") ? [.linkedLibrary("heif")] : [])
                + (FileManager.default.fileExists(atPath: "/usr/include/xcb/xcb.h") ? [.linkedLibrary("xcb")] : [])
                + [.linkedLibrary("z"), .linkedLibrary("tiff")]
                + (librawPrefix.map { prefix in [.unsafeFlags(["\(prefix)/lib/libraw_r.a"] + rawspeedLibraries), .linkedLibrary("gomp"), .linkedLibrary("z"), .linkedLibrary("jpeg")] } ?? [])
                + (openexrLibraries.isEmpty ? [] : [.unsafeFlags(openexrLibraries), .linkedLibrary("zstd")])
        ),
        .executableTarget(
            name: "CompositorHostBootstrap",
            dependencies: ["Compositor", "HostRun", "ImageIO", "CoreGraphics", "FoundationCompat", "AppKit"],
            path: "Sources/CompositorHostBootstrap",
            swiftSettings: [.unsafeFlags(["-swift-version", "5"])],
            linkerSettings: [
                .linkedLibrary("Qt6Widgets"),
                .linkedLibrary("Qt6Gui"),
                .linkedLibrary("Qt6Core"),
                .linkedLibrary("Qt6DBus"),
                .linkedLibrary("Qt6Svg"),
                .unsafeFlags(["-L/usr/lib/x86_64-linux-gnu",
                              "-Xlinker", "-rpath", "-Xlinker", "/usr/lib/x86_64-linux-gnu"]),
            ]
        ),
    ],
    cxxLanguageStandard: .cxx17
)
