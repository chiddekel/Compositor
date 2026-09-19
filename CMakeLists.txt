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
target_link_libraries(CompositorKernels PUBLIC m)

# Thin C++ wrapper over the C ABI.
add_library(CompositorCoreShim STATIC shim/CompositorCoreShim.cpp)
target_link_libraries(CompositorCoreShim PUBLIC CompositorCoreAbi)

# C reference implementation — TEST STAND-IN for the Swift @_cdecl export.
# Never linked into production; only the test executable consumes it.
add_library(CompositorCoreRef STATIC tests/ref/compositor_composite_over.c)
target_link_libraries(CompositorCoreRef PUBLIC CompositorCoreAbi)

# ---- ENG-2: Qt6 Widgets host shell / composition root ---------------------
# find_package is QUIET and early so both Qt-gated targets below see Qt6_FOUND.
# On a host without Qt (e.g. a Swift-only SDK container) the kernel + ABI targets
# still build; the host app and host journey test are simply skipped.
find_package(Qt6 COMPONENTS Widgets QUIET)

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

if(Qt6_FOUND)
    add_executable(compositor
        host/main.cpp
        host/MainWindow.cpp
        host/CanvasWidget.cpp
        host/CanonicalBuffer.cpp)
    target_link_libraries(compositor PRIVATE Qt6::Widgets CompositorKernels)
    # The host app is the ENG-2 composition root; the C kernels run in-process.
endif()