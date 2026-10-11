// compositor_host_run.h — the Qt host C entry called by the Swift composition root.
//
// The Linux port's composition root is inverted: a Swift `@main`
// (Sources/CompositorHostBootstrap/hostMain.swift) bootstraps the Swift runtime
// + Foundation (which a C++ main cannot on the Freedesktop Swift 6.3 SDK), then
// calls compositor_host_run to run the Qt Widgets shell. The Qt host calls back
// into the Swift core through the compositor_session_* C ABI (ENG-1).

#ifndef COMPOSITOR_HOST_RUN_H
#define COMPOSITOR_HOST_RUN_H
#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

int compositor_host_run(int argc, char **argv);
double compositor_session_layers_panel_width(uint64_t handle, double width);
int32_t compositor_host_measure_swiftui(const uint8_t *json, size_t count, double width, double height,
                                      double *measured_width, double *measured_height);
int compositor_host_dialog_smoke(int argc, char **argv);
int compositor_host_package_smoke(int argc, char **argv);
int compositor_host_save_smoke(int argc, char **argv);
int compositor_host_text_smoke(int argc, char **argv, int (*probe)(void));
int compositor_host_interchange(int argc, char **argv);
int compositor_host_preview_smoke(int argc, char **argv);
int compositor_host_color_range_smoke(int argc, char **argv);
int compositor_host_io_smoke(int argc, char **argv);
int compositor_host_layers_smoke(int argc, char **argv);
int compositor_host_brush_smoke(int argc, char **argv);
int compositor_host_transform_smoke(int argc, char **argv);
int compositor_host_combo_smoke(int argc, char **argv);

#ifdef __cplusplus
}
#endif

#endif /* COMPOSITOR_HOST_RUN_H */
