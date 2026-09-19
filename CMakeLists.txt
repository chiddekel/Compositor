# CMakeLists.txt — builds the C/C++ side of the Compositor C ABI seam (ENG-1),
# the portable C pixel kernels (ENG-17, file-map "Keep" tier), and the Qt Widgets
# host shell / composition root (ENG-2).
#
# Scope:
#   - shim/            thin C++ wrapper over the C ABI (ENG-1)
#   - Compositor/Rendering/*.c   portable C pixel kernels, reused from macOS (Keep tier)
#   - host/            Qt6 Widgets shell: composition root + canvas + canonical adapters
# The Swift core (Sources/CompositorCore) is built by SwiftPM under the Freedesktop
# Swift runtime extension, not by this file (no Swift toolchain on this build host).
# The ABI tests link a C reference impl (tests/ref) so they run without Swift.
#
# Build:
#   cmake -S . -B build && cmake --build build && ctest --test-dir build --output-on-failure
# Run the host shell (offscreen check):
#   QT_QPA_PLATFORM=offscreen ./build/compositor --help 2>/dev/null; echo "exit=$?"

cmake_minimum_required(VERSION 3.16)
project(CompositorCoreShim LANGUAGES C CXX)

set(CMAKE_C_STANDARD 11)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)

# COMPOSITOR_BUILD_HOST=ON is a local-dev escape hatch that allows finding Qt6
# from the host system. The Flatpak build (the only supported build path) never
# sets it: Qt6 comes from the KDE SDK, Skia/OpenCV are vendored under /app, and
# the build refuses to use a host-system Qt. See com.wonderassembly.Compositor.yaml.
option(COMPOSITOR_BUILD_HOST OFF)

# Header-only ABI contract, consumed by the shim and tests.
add_library(CompositorCoreAbi INTERFACE)
target_include_directories(CompositorCoreAbi INTERFACE ${CMAKE_SOURCE_DIR}/include)

# Portable C pixel kernels (file-map "Keep" tier): reused verbatim from the
# macOS source tree. COMPOSITOR_PORTABLE turns on the ENG-17 canonical-buffer
# entry asserts; macOS/Xcode never defines it, so the asserts are no-ops there
# and legacy padded-stride callers keep working.
add_library(CompositorKernels STATIC
    Compositor/Rendering/AdjustPixels.c
    Compositor/Rendering/BrushPixels.c
    Compositor/Rendering/ContentFill.c
    Compositor/Rendering/HealPixels.c
    Compositor/Rendering/LensPixels.c
    Compositor/Rendering/LevelsPixels.c
    Compositor/Rendering/NoisePixels.c
    Compositor/Rendering/WandPixels.c
    Compositor/Rendering/CompositorKernelAssert.c)
target_include_directories(CompositorKernels PUBLIC ${CMAKE_SOURCE_DIR}/Compositor/Rendering)
target_compile_definitions(CompositorKernels PUBLIC COMPOSITOR_PORTABLE)
# libm is part of glibc bundled in the Freedesktop runtime, not a separately
# installed host library, so this is not a host-system dependency.
target_link_libraries(CompositorKernels PUBLIC m)

# Thin C++ wrapper over the C ABI.
add_library(CompositorCoreShim STATIC shim/CompositorCoreShim.cpp)
target_link_libraries(CompositorCoreShim PUBLIC CompositorCoreAbi)

# C reference implementation — TEST STAND-IN for the Swift @_cdecl export.
# Never linked into production; only the test executable consumes it.
add_library(CompositorCoreRef STATIC tests/ref/compositor_composite_over.c)
target_link_libraries(CompositorCoreRef PUBLIC CompositorCoreAbi)

# ---- ENG-2: Qt6 Widgets host shell / composition root ---------------------
# Qt6 must come from the Flatpak SDK (KDE 6.10), never the host system. The
# previous bare `find_package(Qt6 ... QUIET)` silently picked up the host's
# installed Qt6. Behavior now:
#   - Flatpak build (FLATPAK_ID set): accept the SDK's Qt6, build Qt targets.
#   - Host without Qt6: skip Qt targets; the kernel + ABI tests still build.
#   - Host WITH a host-system Qt6 and not COMPOSITOR_BUILD_HOST: hard error
#     (refuses to link the forbidden host-system Qt).
#   - COMPOSITOR_BUILD_HOST=ON: local-dev escape hatch, accept host Qt6.
if(COMPOSITOR_BUILD_HOST)
    find_package(Qt6 COMPONENTS Widgets QUIET)
else()
    find_package(Qt6 COMPONENTS Widgets QUIET)
    if(Qt6_FOUND AND NOT DEFINED ENV{FLATPAK_ID})
        message(FATAL_ERROR
            "Qt6 was found (at ${Qt6_DIR}) but this is a host-system Qt, not the "
            "Flatpak SDK Qt. Build via the Flatpak manifest "
            "(com.wonderassembly.Compositor.yaml), or set -DCOMPOSITOR_BUILD_HOST=ON "
            "explicitly for local dev.")
    endif()
endif()

# Vendored Skia (static, no cmake config) + OpenCV (cmake config) under /app.
# Wired now to prove the manifest modules install correctly; no target links
# them yet in the MVP (the C kernels + QImage do the pixel/codec work). The
# Skia compositing and OpenCV named-op backends plug in here later.
# COMPOSITOR_REQUIRE_VENDORED_DEPS=ON (the full Flatpak manifest) makes these
# REQUIRED so a build that omits the Skia/OpenCV modules fails fast. The minimal
# Swift+Qt Flatpak build sets it OFF to de-risk the Swift toolchain first.
# Only required inside a Flatpak build (where the manifest installed them to /app);
# skipped on the host so the Qt-independent kernel + ABI tests still build.
option(COMPOSITOR_REQUIRE_VENDORED_DEPS OFF)
if(DEFINED ENV{FLATPAK_ID} AND COMPOSITOR_REQUIRE_VENDORED_DEPS)
    find_path(Skia_INCLUDE_DIR NAMES SkCanvas.h PATHS /app/include/skia REQUIRED)
    find_library(Skia_STATIC_LIB NAMES skia PATHS /app/lib REQUIRED)
    find_package(OpenCV REQUIRED COMPONENTS core imgproc)
endif()

# Prebuilt Swift static lib (libCompositorCore.a), built by SwiftPM in the
# Flatpak manifest build-commands with --static-swift-stdlib so the Swift
# runtime is bundled. Passed in via -DCompositorCore_SWIFT_STATIC_LIB=<path>.
# The Swift core exposes its callables via @_cdecl (the C ABI seam, ENG-1).
set(COMPOSITOR_CORE_LINK "")
if(DEFINED CompositorCore_SWIFT_STATIC_LIB)
    add_library(CompositorCoreSwift STATIC IMPORTED)
    set_target_properties(CompositorCoreSwift PROPERTIES
        IMPORTED_LOCATION "${CompositorCore_SWIFT_STATIC_LIB}"
        INTERFACE_INCLUDE_DIRECTORIES "${CMAKE_SOURCE_DIR}/include")
    # --whole-archive keeps the @_cdecl exports even if no C++ TU references
    # them directly at link time (Swift symbols are pulled by the runtime, not
    # by the C++ call sites until the shim is wired).
    set(COMPOSITOR_CORE_LINK
        "-Wl,--whole-archive" CompositorCoreSwift "-Wl,--no-whole-archive")
    # The core archive alone leaves Swift runtime symbols undefined ($s…) when
    # the C++ linker (not swift build) creates the final binary. Link the toolchain's
    # static runtime set too; ld extracts only referenced members, so unused
    # archives cost link time, not binary size. Override path for non-Flatpak
    # toolchains via -DCOMPOSITOR_SWIFT_STATIC_DIR=...
    set(COMPOSITOR_SWIFT_STATIC_DIR "/usr/lib/sdk/swift6/lib/swift_static/linux"
        CACHE PATH "Swift static runtime archive directory")
    if(EXISTS "${COMPOSITOR_SWIFT_STATIC_DIR}/libswiftCore.a")
        file(GLOB COMPOSITOR_SWIFT_RUNTIME_ARCHIVES
            "${COMPOSITOR_SWIFT_STATIC_DIR}/*.a")
        # --start-group: single-pass ld cannot resolve cross-archive cycles
        # (e.g. libswift_Concurrency needs libdispatch, which needs swiftCore).
        # --whole-archive + --allow-multiple-definition: the Swift runtime
        # bootstraps via .init_array constructors that live in archive members
        # no symbol references, so a demand-only link never extracts them.
        # The system deps (curl/sqlite3/z/m/xml2) are pulled by the whole-archived
        # Foundation runtime (CFURLSession→libcurl, etc.).
        #
        # NOTE: this static embedding does NOT fully initialize the Swift runtime
        # from a non-Swift main on the Freedesktop Swift 6.3 SDK — there is no
        # swift_initSwiftRuntime, and generic class metadata (_DictionaryStorage)
        # is never bootststrapped, so the first Dictionary insertion SEGVs. The
        # C++ test_session_journey is therefore gated out of the default build;
        # the same journey is verified in Swift under `swift test`
        # (SessionJourneyTests). The working host composition root is a Swift
        # @main that bootstraps the runtime and calls into Qt via a C ABI; see
        # tests/test_session_journey.cpp and docs/linux-port-file-map.md.
        list(APPEND COMPOSITOR_CORE_LINK
            "-Wl,--allow-multiple-definition"
            "-Wl,--whole-archive" "-Wl,--start-group" ${COMPOSITOR_SWIFT_RUNTIME_ARCHIVES} "-Wl,--end-group" "-Wl,--no-whole-archive")
        list(APPEND COMPOSITOR_CORE_LINK curl sqlite3 z m xml2)
    endif()
endif()

enable_testing()

add_executable(test_composite_over tests/test_composite_over.cpp)
target_link_libraries(test_composite_over PRIVATE CompositorCoreShim CompositorCoreRef)
add_test(NAME CompositorCore.Abi COMMAND test_composite_over)

add_executable(test_kernels tests/test_kernels.cpp)
target_link_libraries(test_kernels PRIVATE CompositorKernels)
add_test(NAME CompositorCore.Kernels COMMAND test_kernels)

# Headless host journey test: open -> canonicalize -> filter -> save -> reopen.
# Needs Qt6 (QImage codec); gated on Qt6_FOUND like the host app.
if(Qt6_FOUND)
    add_executable(test_host_journey tests/test_host_journey.cpp host/CanonicalBuffer.cpp)
    target_include_directories(test_host_journey PRIVATE ${CMAKE_SOURCE_DIR}/host)
    target_link_libraries(test_host_journey PRIVATE Qt6::Gui CompositorKernels)
    add_test(NAME CompositorCore.HostJourney COMMAND test_host_journey)
endif()

# Headless Swift-session journey test: new -> paint -> render -> undo -> redo ->
# state, driven through the real Swift core via the @_cdecl C ABI. Only meaningful
# when the prebuilt Swift static lib is provided (Flatpak build, or a host build
# that ran `swift build --static-swift-stdlib` and passed -DCompositorCore_SWIFT_STATIC_LIB).
if(DEFINED CompositorCore_SWIFT_STATIC_LIB)
    add_executable(test_session_journey tests/test_session_journey.cpp)
    target_link_libraries(test_session_journey PRIVATE CompositorCoreAbi ${COMPOSITOR_CORE_LINK})
    add_test(NAME CompositorCore.SessionJourney COMMAND test_session_journey)
endif()

if(Qt6_FOUND)
    add_executable(compositor
        host/main.cpp
        host/MainWindow.cpp
        host/CanvasWidget.cpp
        host/CanonicalBuffer.cpp)
    # The host app is the ENG-2 composition root; the C kernels run in-process.
    # When the Swift static lib is linked it already embeds the kernel objects
    # (SwiftPM folds the C target into the library product), so it must come
    # FIRST: with the kernel symbols already defined, ld never extracts the
    # duplicate members from this project's own kernel archive, which stays in
    # the link line for its include path.
    target_link_libraries(compositor PRIVATE Qt6::Widgets ${COMPOSITOR_CORE_LINK} CompositorKernels)

    # The Swift-@main composition root (Sources/CompositorHostBootstrap) links
    # this static lib to call compositor_host_run (host/host_run.cpp, moc-free)
    # from a Swift entry point that bootstraps the Swift runtime + Foundation.
    # Built by CMake because it needs Qt6 + AUTOMOC for the full MainWindow; the
    # Flatpak manifest links it into the Swift executable. host_run.cpp itself
    # is moc-free so the bootstrap can also be built by SwiftPM in the SDK.
    add_library(CompositorHostRun STATIC host/host_run.cpp)
    target_include_directories(CompositorHostRun PUBLIC host/include)
    target_link_libraries(CompositorHostRun PUBLIC Qt6::Widgets)
endif()