// host_run.cpp — the Qt host entry called by the Swift composition root.
//
// The Linux port's composition root is inverted: a Swift `@main`
// (Sources/CompositorHostBootstrap/hostMain.swift) bootstraps the Swift runtime
// + Foundation (which a C++ main cannot on the Freedesktop Swift 6.3 SDK), then
// calls this `compositor_host_run` C entry to run the Qt Widgets shell. The Qt
// host in turn calls back into the Swift core through the `compositor_session_*`
// C ABI (ENG-1). The standalone CMake `compositor` target keeps its own `main`
// (host/main.cpp) for the C++-only build path.
//
// This file is deliberately moc-free (no Q_OBJECT) so it can be compiled by
// SwiftPM's C/C++ target support, which does not run moc. The full MainWindow
// (which uses Q_OBJECT) is linked via the CMake-built host static lib in the
// Flatpak build; this bootstrap entry proves the Swift-main -> Qt link itself.

#include <QApplication>
#include <QWidget>

#include "compositor_host_run.h"

extern "C" int compositor_host_run(int argc, char **argv) {
    QApplication app(argc, argv);
    app.setApplicationName("Compositor");
    app.setOrganizationName("Compositor");
    QWidget window;
    window.resize(64, 64);
    window.setWindowTitle("Compositor");
    // For the headless bootstrap proof we do not enter the event loop; proving
    // that Qt initializes from a Swift-driven entry point is the goal. The
    // Flatpak build replaces this with MainWindow + app.exec().
    return 0;
}