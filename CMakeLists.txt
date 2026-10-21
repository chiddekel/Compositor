# CMakeLists.txt — builds the C/C++ side of the Compositor C ABI seam (ENG-1),
# the portable C pixel kernels (ENG-17, file-map "Keep" tier), and the Qt Widgets
# host shell / composition root (ENG-2).
#
# Scope:
#   - shim/            thin C++ wrapper over the C ABI (ENG-1)
#   - Compositor/Rendering/*.c   portable C pixel kernels, reused from macOS (Keep tier)
#   - host/            Qt6 Widgets shell: composition root + canvas + canonical adapters
# The Swift core (the Compositor module + Sources/LinuxBridge, product CompositorCore) is built by SwiftPM under the Freedesktop
# Swift runtime extension, not by this file (no Swift toolchain on this build host).
# The ABI tests link a C reference impl (tests/ref) so they run without Swift.
#
# Build:
#   cmake -S . -B build && cmake --build build && ctest --test-dir build --output-on-failure
# Run the host shell (offscreen check):
#   QT_QPA_PLATFORM=offscreen ./build/compositor --help 2>/dev/null; echo "exit=$?"

cmake_minimum_required(VERSION 3.16)
if(NOT DEFINED CMAKE_C_COMPILER)
    find_program(COMPOSITOR_CLANG clang HINTS /usr/lib/sdk/swift6/bin REQUIRED)
    set(CMAKE_C_COMPILER "${COMPOSITOR_CLANG}" CACHE FILEPATH "C compiler supporting upstream Blocks")
endif()
project(CompositorCoreShim LANGUAGES C CXX)

set(CMAKE_C_STANDARD 11)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)

# COMPOSITOR_BUILD_HOST=ON is a local-dev escape hatch that allows finding Qt6
# from the host system. The Flatpak build (the only supported build path) never
# sets it: Qt6 comes from the KDE SDK, Skia/OpenCV are vendored under /app, and
# the build refuses to use a host-system Qt. See com.compositor.Client.yaml.
option(COMPOSITOR_BUILD_HOST OFF)

# ── VENDORED DEPENDENCIES (Flatpak) ──────────────────────────────────────
# When building inside a Flatpak, the Freedesktop SDK installs Skia, OpenCV,
# and Qt6 to /app. The manifest sets COMPOSITOR_REQUIRE_VENDORED_DEPS=ON so
# these modules are REQUIRED and fail-fast if missing. The minimal Swift+Qt
# Flatpak build sets it OFF to de-risk the Swift toolchain first.
option(COMPOSITOR_REQUIRE_VENDORED_DEPS OFF)

# ── QT6 ────────────────────────────────────────────────────────────────
# Qt6 must come from the Flatpak SDK (KDE 6.10), never the host system. The
# previous bare `find_package(Qt6 ... QUIET)` silently picked up the host's
# installed Qt6. Behavior now:
#   - Flatpak build (FLATPAK_ID set): accept the SDK's Qt6, build Qt targets.
#   - Host without Qt6: skip Qt targets; the kernel + ABI tests still build.
#   - Host WITH a host-system Qt6 and not COMPOSITOR_BUILD_HOST: hard error
#     (refuses to link the forbidden host-system Qt).
#   - COMPOSITOR_BUILD_HOST=ON: local-dev escape hatch, accept host Qt6.
if(COMPOSITOR_BUILD_HOST)
    find_package(Qt6 COMPONENTS Widgets DBus Svg Gui QUIET)
else()
    find_package(Qt6 COMPONENTS Widgets DBus Svg Gui QUIET)
    if(Qt6_FOUND AND NOT DEFINED ENV{FLATPAK_ID})
        message(FATAL_ERROR
            "Qt6 was found (at ${Qt6_DIR}) but this is a host-system Qt, not the "
            "Flatpak SDK Qt. Build via the Flatpak manifest "
            "(com.compositor.Client.yaml), or set -DCOMPOSITOR_BUILD_HOST=ON "
            "explicitly for local dev.")
    endif()
endif()

# ── PDF ────────────────────────────────────────────────────────────────
if(Qt6_FOUND)
    find_package(PkgConfig REQUIRED)
    # Prefer the local SDK build, then Flatpak's vendored prefix. PDF stays behind a C ABI and below the domain.
    set(ENV{PKG_CONFIG_PATH} "${CMAKE_SOURCE_DIR}/build/poppler/install/lib/pkgconfig:/app/lib/pkgconfig:$ENV{PKG_CONFIG_PATH}")
    pkg_check_modules(POPPLER_QT6 IMPORTED_TARGET poppler-qt6)
    if(POPPLER_QT6_FOUND)
        add_library(CompositorPDFBackend SHARED backends/pdf/PDFBackend.cpp)
        target_link_libraries(CompositorPDFBackend PRIVATE PkgConfig::POPPLER_QT6 Qt6::Gui)
        find_package(Python3 COMPONENTS Interpreter REQUIRED)
        add_test(NAME CompositorCore.PDFBackend COMMAND Python3::Interpreter "${CMAKE_SOURCE_DIR}/tests/test_pdf_backend.py" $<TARGET_FILE:CompositorPDFBackend>)
        install(TARGETS CompositorPDFBackend LIBRARY DESTINATION lib)
    elseif(COMPOSITOR_REQUIRE_VENDORED_DEPS)
        message(FATAL_ERROR "PDF import requires the manifest's Poppler module or scripts/build-poppler.sh")
    endif()
endif()

# ── SKIA ───────────────────────────────────────────────────────────────
# Skia root and static library. Defaults to local build/skia-src if present,
# or /app (Flatpak SDK), or user-provided cache variables.
set(COMPOSITOR_SKIA_ROOT "${CMAKE_SOURCE_DIR}/build/skia-src"
    CACHE PATH "Root directory of Skia source/includes")
set(COMPOSITOR_SKIA_LIB "${CMAKE_SOURCE_DIR}/build/skia-src/out/Raster/libskia.a"
    CACHE FILEPATH "Path to Skia static library (libskia.a)")

if(EXISTS "${COMPOSITOR_SKIA_ROOT}/include/core/SkCanvas.h" AND EXISTS "${COMPOSITOR_SKIA_LIB}")
    set(Skia_FOUND TRUE)
    set(Skia_INCLUDE_DIR "${COMPOSITOR_SKIA_ROOT}")
    set(Skia_STATIC_LIB "${COMPOSITOR_SKIA_LIB}")
elseif(DEFINED ENV{FLATPAK_ID} AND COMPOSITOR_REQUIRE_VENDORED_DEPS)
    # The Skia module installs its include/ tree under /app/include/skia (headers include "include/core/...").
    find_path(Skia_INCLUDE_DIR NAMES include/core/SkCanvas.h PATHS /app/include/skia NO_DEFAULT_PATH REQUIRED)
    find_library(Skia_STATIC_LIB NAMES skia PATHS /app/lib REQUIRED)
    # Verify Skia was built with Vulkan enabled
    if(NOT SKIA_STATIC_LIB MATCHES ".*vulkan.*")
        message(WARNING "Skia library found but may not have Vulkan enabled; "
                  "Vulkan backend will be unavailable.")
    endif()
    if(Skia_INCLUDE_DIR AND Skia_STATIC_LIB)
        set(Skia_FOUND TRUE)
    endif()
endif()

# ── OPENCV (Flatpak vendored) ──────────────────────────────────────────
# OpenCV 4.14.0 minimal modules (core + imgproc) under /app, required when
# COMPOSITOR_REQUIRE_VENDORED_DEPS is ON and we're in a Flatpak.
if(DEFINED ENV{FLATPAK_ID} AND COMPOSITOR_REQUIRE_VENDORED_DEPS)
    find_package(OpenCV REQUIRED COMPONENTS core imgproc PATHS /app)
endif()

# ── SWIFT CORE LINK ────────────────────────────────────────────────────
# Prebuilt Swift static lib (libCompositorCore.a), built by SwiftPM in the
# Flatpak manifest build-commands with --static-swift-stdlib so the Swift
# runtime is bundled. Passed in via -DCompositorCore_SWIFT_STATIC_LIB=<path>.
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
        "-Wl,--whole-archive" CompositorCoreSwift "-Wl,--no-whole-archive" vulkan)
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

# ── ABI Library ────────────────────────────────────────────────────────
add_library(CompositorCoreAbi INTERFACE)
target_include_directories(CompositorCoreAbi INTERFACE ${CMAKE_SOURCE_DIR}/include)

# ── Portable C pixel kernels (file-map "Keep" tier) ───────────────────
# Upstream's kernels (Compositor/Rendering, kept unmodified), each compiled through linux/kernels/Checked*.c, which
# puts the ENG-17 canonical-stride checks in front of the entries that take a stride (see CompositorKernelChecks.h).
add_library(CompositorKernels STATIC
    linux/kernels/CheckedAdjustPixels.c
    linux/kernels/CheckedBrushPixels.c
    linux/kernels/CheckedPatchPixels.c
    linux/kernels/CheckedHealPixels.c
    linux/kernels/CheckedLensPixels.c
    Compositor/Rendering/LevelsPixels.c
    Compositor/Rendering/DeepPixels.c
    linux/kernels/CheckedNoisePixels.c
    linux/kernels/CheckedWandPixels.c)
target_include_directories(CompositorKernels PUBLIC ${CMAKE_SOURCE_DIR}/Compositor/Rendering)
target_compile_definitions(CompositorKernels PUBLIC COMPOSITOR_PORTABLE)
# libm is part of glibc bundled in the Freedesktop runtime, not a separately
# installed host library, so this is not a host-system dependency.
find_path(COMPOSITOR_DISPATCH_INCLUDE dispatch/dispatch.h HINTS /usr/lib/sdk/swift6/lib/swift /usr/local/swift/usr/lib/swift REQUIRED)
find_library(COMPOSITOR_DISPATCH_LIBRARY dispatch HINTS /usr/lib/sdk/swift6/lib/swift/linux /usr/local/swift/usr/lib/swift/linux REQUIRED)
find_library(COMPOSITOR_BLOCKS_LIBRARY BlocksRuntime HINTS /usr/lib/sdk/swift6/lib/swift/linux /usr/local/swift/usr/lib/swift/linux REQUIRED)
set_target_properties(CompositorKernels PROPERTIES AUTOMOC OFF)
target_compile_options(CompositorKernels PRIVATE "$<$<COMPILE_LANGUAGE:C>:-fblocks>")
target_include_directories(CompositorKernels PRIVATE "${COMPOSITOR_DISPATCH_INCLUDE}" "${COMPOSITOR_DISPATCH_INCLUDE}/Block")
target_link_libraries(CompositorKernels PUBLIC m "${COMPOSITOR_DISPATCH_LIBRARY}" "${COMPOSITOR_BLOCKS_LIBRARY}")

# ── Thin C++ wrapper over the C ABI. ───────────────────────────────────
add_library(CompositorCoreShim STATIC shim/CompositorCoreShim.cpp)
target_link_libraries(CompositorCoreShim PUBLIC CompositorCoreAbi)

# ── C reference implementation — TEST STAND-IN for the Swift @_cdecl export. ─────
# Never linked into production; only the test executable consumes it.
add_library(CompositorCoreRef STATIC tests/ref/compositor_composite_over.c)
target_link_libraries(CompositorCoreRef PUBLIC CompositorCoreAbi)

# ── ENG-2: Qt6 Widgets host shell / composition root ───────────────────
# The host app is the ENG-2 composition root; the C kernels run in-process.
# When the Swift static lib is linked it already embeds the kernel objects
# (SwiftPM folds the C target into the library product), so it must come
# FIRST: with the kernel symbols already defined, ld never extracts the
# duplicate members from this project's own kernel archive, which stays in
# the link line for its include path.

find_package(Vulkan QUIET)
if(Vulkan_FOUND)
    # Independent pixel/ROI checks for the kernel used by the Metal API compatibility driver.
    add_library(test_dispersion_backend SHARED EXCLUDE_FROM_ALL
        backends/coreimage/Dispersion.cpp backends/coreimage/VulkanRaster.cpp)
    target_link_libraries(test_dispersion_backend PRIVATE Vulkan::Vulkan)
    set_target_properties(test_dispersion_backend PROPERTIES AUTOMOC OFF)
endif()

option(COMPOSITOR_ENABLE_SKIA_GPU "Link Skia Ganesh Vulkan into CompRenderer when the Skia build has it" OFF)

add_library(CompositorSkiaBridge SHARED linux/graphics/SkiaBridge.cpp)
target_include_directories(CompositorSkiaBridge PUBLIC ${CMAKE_SOURCE_DIR}/include)
target_include_directories(CompositorSkiaBridge PRIVATE
    ${CMAKE_SOURCE_DIR}/backends/effects/include
    ${CMAKE_SOURCE_DIR}/linux/graphics)
if(COMPOSITOR_ENABLE_SKIA_GPU)
    target_compile_definitions(CompositorSkiaBridge PRIVATE COMPOSITOR_ENABLE_SKIA_GPU=1)
endif()
if(Skia_FOUND)
    target_include_directories(CompositorSkiaBridge PRIVATE ${Skia_INCLUDE_DIR})
    # SkPathOps (path booleans for CGPath.union/intersection/...) is a separate GN source set that plain
    # libskia.a omits when PDF is off; scripts/build-skia-pathops.sh archives it as libskia_pathops.a.
    get_filename_component(_skia_lib_dir "${Skia_STATIC_LIB}" DIRECTORY)
    if(EXISTS "${_skia_lib_dir}/libskia_pathops.a")
        target_link_libraries(CompositorSkiaBridge PUBLIC ${Skia_STATIC_LIB} "${_skia_lib_dir}/libskia_pathops.a" pthread dl)
    else()
        message(WARNING "libskia_pathops.a not found next to ${Skia_STATIC_LIB}; CGPath booleans will be unavailable "
                        "(run scripts/build-skia-pathops.sh)")
        target_link_libraries(CompositorSkiaBridge PUBLIC ${Skia_STATIC_LIB} pthread dl)
    endif()
endif()
if(Vulkan_FOUND)
    target_link_libraries(CompositorSkiaBridge PUBLIC Vulkan::Vulkan)
endif()

# Stage 0/5 DoD smoke: Raster surface round-trip + Vulkan loader check.
add_executable(test_skia_bridge tests/test_skia_bridge.cpp)
target_link_libraries(test_skia_bridge PRIVATE CompositorSkiaBridge)
add_test(NAME CompositorCore.SkiaBridge COMMAND test_skia_bridge)
set_tests_properties(CompositorCore.SkiaBridge PROPERTIES SKIP_RETURN_CODE 77)

# Stage 10: Selected OpenCV Operations / Inpainting / Guided Filter bridge
add_library(CompositorOpenCVBridge STATIC linux/graphics/OpenCVBridge.cpp)
target_include_directories(CompositorOpenCVBridge PUBLIC ${CMAKE_SOURCE_DIR}/include ${CMAKE_SOURCE_DIR}/Compositor/Rendering)
target_link_libraries(CompositorOpenCVBridge PUBLIC CompositorKernels)
if(OpenCV_FOUND)
    target_link_libraries(CompositorOpenCVBridge PUBLIC ${OpenCV_LIBS})
endif()

add_executable(test_opencv_bridge tests/test_opencv_bridge.cpp)
target_link_libraries(test_opencv_bridge PRIVATE CompositorOpenCVBridge)
add_test(NAME CompositorCore.OpenCVBridge COMMAND test_opencv_bridge)

# Qt image plugins as a loadable ImageIO backend (JPEG/TIFF/HEIC/WebP/... for CGImageSource/Destination). The Swift
# ImageIO shim dlopens it when the host has not registered one itself (upstream's tests, headless tools).
if(Qt6_FOUND)
    find_package(Qt6 COMPONENTS Gui QUIET)
    add_library(CompositorQtImageIO SHARED host/QtImageIO.cpp)
    find_package(ZLIB REQUIRED)
    find_package(TIFF 4.5 REQUIRED)
    find_package(PkgConfig REQUIRED)
    pkg_check_modules(LCMS2 REQUIRED IMPORTED_TARGET lcms2)
    target_link_libraries(CompositorQtImageIO PRIVATE Qt6::Gui ZLIB::ZLIB TIFF::TIFF PkgConfig::LCMS2)
    find_package(PkgConfig QUIET)
    if(PkgConfig_FOUND)
        pkg_check_modules(LIBHEIF QUIET IMPORTED_TARGET libheif)
        if(LIBHEIF_FOUND)
            target_link_libraries(CompositorQtImageIO PRIVATE PkgConfig::LIBHEIF)
        endif()
    endif()
    # EXR through OpenEXR (scripts/build-openexr.sh into build/openexr/install, or the Flatpak's /app), static.
    list(APPEND CMAKE_PREFIX_PATH "${CMAKE_SOURCE_DIR}/build/openexr/install" /app)
    # OpenEXRCore links zstd through pkg-config's imported target, which its config file expects to exist.
    if(PkgConfig_FOUND)
        pkg_check_modules(libzstd QUIET IMPORTED_TARGET libzstd)
    endif()
    if(TARGET PkgConfig::libzstd)
        find_package(OpenEXR 3.5 CONFIG QUIET)
    endif()
    if(OpenEXR_FOUND)
        target_link_libraries(CompositorQtImageIO PRIVATE OpenEXR::OpenEXR)
        target_compile_definitions(CompositorQtImageIO PRIVATE COMPOSITOR_HAS_OPENEXR=1)
    endif()
endif()

# Headless host journey test: open -> canonicalize -> filter -> save -> reopen.
# Needs Qt6 (QImage codec); gated on Qt6_FOUND like the host app.
if(Qt6_FOUND)
    add_executable(test_host_journey tests/test_host_journey.cpp host/CanonicalBuffer.cpp)
    target_include_directories(test_host_journey PRIVATE ${CMAKE_SOURCE_DIR}/host)
    target_link_libraries(test_host_journey PRIVATE Qt6::Gui CompositorKernels)
    add_test(NAME CompositorCore.HostJourney COMMAND test_host_journey)

    # IO-tier codec verification (ImageIO → Qt, file-map "IO / codec mapping"):
    # PNG export/import round-trip byte-identical for QImage::Format_RGBA8888
    # (the format compositor_session_render emits), plus the JPEG lossy leg.
    # Qt-only (no Swift static lib); runs in the default CMake/CTest build.
    add_executable(test_png_codec tests/test_png_codec.cpp)
    target_link_libraries(test_png_codec PRIVATE Qt6::Gui)
    add_test(NAME CompositorCore.PngCodec COMMAND test_png_codec)

    # Native text and lowered controls must preserve system font traits.
    add_executable(test_font_traits tests/test_font_traits.cpp)
    target_link_libraries(test_font_traits PRIVATE Qt6::Gui)
    add_test(NAME CompositorCore.FontTraits COMMAND test_font_traits)
    set_tests_properties(CompositorCore.FontTraits PROPERTIES ENVIRONMENT "QT_QPA_PLATFORM=offscreen"
        WORKING_DIRECTORY "${CMAKE_SOURCE_DIR}")
    # Needs the built Swift host; the contract runner supplies its executable path.
    add_executable(test_group_rotation tests/test_group_rotation.cpp)
    target_link_libraries(test_group_rotation PRIVATE Qt6::Gui)
    add_executable(test_grid_settings tests/test_grid_settings.cpp)
    target_link_libraries(test_grid_settings PRIVATE Qt6::Core)
    add_executable(test_native_file_panels tests/test_native_file_panels.cpp)
    target_include_directories(test_native_file_panels PRIVATE ${CMAKE_SOURCE_DIR}/host)
    target_link_libraries(test_native_file_panels PRIVATE Qt6::Widgets)
    add_test(NAME CompositorCore.NativeFilePanels COMMAND test_native_file_panels)
    set_tests_properties(CompositorCore.NativeFilePanels PROPERTIES ENVIRONMENT "QT_QPA_PLATFORM=offscreen")
    # Exercise the actual ImageIO callbacks, including source-profile conversion and export tags.
    add_executable(test_imageio_color tests/test_imageio_color.cpp)
    target_link_libraries(test_imageio_color PRIVATE Qt6::Gui CompositorQtImageIO TIFF::TIFF)
    if(LIBHEIF_FOUND)
        target_link_libraries(test_imageio_color PRIVATE PkgConfig::LIBHEIF)
        target_compile_definitions(test_imageio_color PRIVATE COMPOSITOR_TEST_LIBHEIF=1)
    endif()
    add_test(NAME CompositorCore.ImageIOColor COMMAND test_imageio_color)
    set_tests_properties(CompositorCore.ImageIOColor PROPERTIES ENVIRONMENT "QT_QPA_PLATFORM=offscreen")

    # SessionWindow file operations test source remains available for the Swift
    # composition root. Do not register its C++ main as CTest: Foundation-backed
    # Swift calls require a Swift @main to bootstrap the runtime. Not built by default
    # (EXCLUDE_FROM_ALL): its source list predates the host's D-Bus, SwiftUI renderer and
    # RAW sources, and nothing runs it; `cmake --build build --target test_session_window_io`.
    if(DEFINED CompositorCore_SWIFT_STATIC_LIB)
        add_executable(test_session_window_io EXCLUDE_FROM_ALL tests/test_session_window_io.cpp host/SessionWindow.cpp host/SessionDialogs.cpp host/SizeDialog.cpp host/FilterDialog.cpp host/ImageExporters.cpp host/TabletHandler.cpp)
        target_include_directories(test_session_window_io PRIVATE ${CMAKE_SOURCE_DIR}/host)
        target_link_libraries(test_session_window_io PRIVATE Qt6::Widgets Qt6::Gui ${COMPOSITOR_CORE_LINK})
    endif()
endif()

# Headless Swift-session journey test: new -> paint -> render -> undo -> redo ->
# state, driven through the real Swift core via the @_cdecl C ABI. Only meaningful
# when the prebuilt Swift static lib is provided (Flatpak build, or a host build
# that ran `swift build --static-swift-stdlib` and passed -DCompositorCore_SWIFT_STATIC_LIB).
if(DEFINED CompositorCore_SWIFT_STATIC_LIB)
    # EXCLUDE_FROM_ALL: gated out of the default build, as the runtime note above says (its whole-archive
    # link would also need every dependency of the core, e.g. OpenCV for the effects backend).
    add_executable(test_session_journey EXCLUDE_FROM_ALL tests/test_session_journey.cpp)
    target_link_libraries(test_session_journey PRIVATE CompositorCoreAbi ${COMPOSITOR_CORE_LINK})
    # A C++ main cannot bootstrap Foundation on the Freedesktop Swift SDK.
    # SessionJourneyTests and CompositorHostBootstrap cover this path from Swift.
endif()

if(Qt6_FOUND)
    # The Swift-@main composition root (Sources/CompositorHostBootstrap) links
    # this static lib to call compositor_host_run (host/host_run.cpp) from a Swift
    # entry point that bootstraps the Swift runtime + Foundation. host_run.cpp
    # creates SessionWindow (a moc'd Q_OBJECT Qt window that drives the Swift core
    # via compositor_session_* and paints the composited RGBA); CMake's AUTOMOC
    # generates SessionWindow's moc (the SwiftPM build uses the committed
    # host/moc_SessionWindow.cpp instead, since SwiftPM cannot run moc).
    add_library(CompositorHostRun STATIC host/host_run.cpp host/DialogJourney.cpp host/InterchangeJourney.cpp host/SessionWindow.cpp host/SessionDialogs.cpp host/SizeDialog.cpp host/FilterDialog.cpp host/ImageExporters.cpp host/TabletHandler.cpp host/QtImageIO.cpp host/FlatpakUpdateService.cpp host/SwiftUIQtRenderer.cpp)
    find_package(Qt6 REQUIRED COMPONENTS GuiPrivate)
    pkg_check_modules(KEYBOARD_LAYOUT REQUIRED IMPORTED_TARGET xkbcommon xkbcommon-x11 wayland-client)
    add_executable(test_keyboard_layout tests/test_keyboard_layout.cpp)
    target_include_directories(test_keyboard_layout PRIVATE host)
    target_link_libraries(test_keyboard_layout PRIVATE Qt6::GuiPrivate PkgConfig::KEYBOARD_LAYOUT)
    target_include_directories(CompositorHostRun PUBLIC host/include PRIVATE host)
    target_link_libraries(CompositorHostRun PUBLIC Qt6::Widgets Qt6::DBus Qt6::Svg PRIVATE Qt6::GuiPrivate PkgConfig::KEYBOARD_LAYOUT ZLIB::ZLIB TIFF::TIFF PkgConfig::LCMS2)
    # OtherApplications.h (Hide Others / Show All) uses xcb when its header is installed.
    pkg_check_modules(XCB QUIET IMPORTED_TARGET xcb)
    if(XCB_FOUND)
        target_link_libraries(CompositorHostRun PUBLIC PkgConfig::XCB)
    endif()
    if(COMPOSITOR_ENABLE_SKIA_GPU AND DEFINED ENV{FLATPAK_ID})
        target_compile_definitions(CompositorHostRun PRIVATE COMPOSITOR_SKIA_BRIDGE=1)
        target_link_libraries(CompositorHostRun PUBLIC CompositorSkiaBridge)
    endif()

    # Freedesktop thumbnailer for .comp packages (reads QuickLook/Preview.jpg).
    add_executable(compositor-thumbnailer host/ThumbnailerMain.cpp)
    target_link_libraries(compositor-thumbnailer PRIVATE Qt6::Gui)
    add_executable(test_thumbnailer tests/test_thumbnailer.cpp)
    target_link_libraries(test_thumbnailer PRIVATE Qt6::Gui)
    add_dependencies(test_thumbnailer compositor-thumbnailer)
    add_test(NAME CompositorCore.Thumbnailer COMMAND test_thumbnailer $<TARGET_FILE:compositor-thumbnailer>)
endif()

# ── Tests ──────────────────────────────────────────────────────────────
enable_testing()
add_executable(test_pressure_brush tests/test_pressure_brush.cpp backends/brush/BrushCoverageCPU.cpp backends/brush/PressureBrushCoverage.cpp)
add_test(NAME CompositorCore.PressureBrush COMMAND test_pressure_brush)

add_executable(test_composite_over tests/test_composite_over.cpp)
target_link_libraries(test_composite_over PRIVATE CompositorCoreShim CompositorCoreRef)
add_test(NAME CompositorCore.Abi COMMAND test_composite_over)

add_executable(test_kernels tests/test_kernels.cpp)
target_link_libraries(test_kernels PRIVATE CompositorKernels)
add_test(NAME CompositorCore.Kernels COMMAND test_kernels)

add_executable(test_scanlines_initialization tests/test_scanlines_initialization.c linux/kernels/DitherPixelsLinux.c)
set_target_properties(test_scanlines_initialization PROPERTIES AUTOMOC OFF)
target_include_directories(test_scanlines_initialization PRIVATE Compositor/Rendering linux/kernels)
target_compile_options(test_scanlines_initialization PRIVATE "$<$<COMPILE_LANGUAGE:C>:-fblocks>")
target_link_options(test_scanlines_initialization PRIVATE -Wl,--wrap=malloc)
target_link_libraries(test_scanlines_initialization PRIVATE ${COMPOSITOR_BLOCKS_LIBRARY} m)
add_test(NAME CompositorCore.ScanlinesInitialization COMMAND test_scanlines_initialization)

# Exercise the unchanged PatchMatch kernel through checked entries and injected allocator failures.
add_executable(test_patch_pixels tests/test_patch_pixels.cpp tests/PatchAllocationFailure.c)
set_target_properties(test_patch_pixels PROPERTIES AUTOMOC OFF)
target_compile_options(test_patch_pixels PRIVATE "$<$<COMPILE_LANGUAGE:C>:-fblocks>")
target_include_directories(test_patch_pixels PRIVATE "${COMPOSITOR_DISPATCH_INCLUDE}" "${COMPOSITOR_DISPATCH_INCLUDE}/Block")
target_link_libraries(test_patch_pixels PRIVATE CompositorKernels)
add_test(NAME CompositorCore.PatchPixels COMMAND test_patch_pixels)

# RAW lens correction from the file's own profile (DNG OpcodeList3, Sony, Fujifilm, OM System, Panasonic): header-only.
add_executable(test_raw_lens tests/test_raw_lens.cpp)
set_target_properties(test_raw_lens PROPERTIES AUTOMOC OFF)
find_package(Threads REQUIRED)
target_link_libraries(test_raw_lens PRIVATE Threads::Threads)
add_test(NAME CompositorCore.RawLens COMMAND test_raw_lens)
