#!/usr/bin/env python3
"""Exercise the spectral compute backend independently of Swift and the application renderer."""
import ctypes as C
import math
import sys


def main(path):
    lib = C.CDLL(path)
    floats = C.POINTER(C.c_float)
    lib.compositor_vulkan_raster_create.argtypes = [C.c_int]
    lib.compositor_vulkan_raster_create.restype = C.c_void_p
    lib.compositor_vulkan_raster_destroy.argtypes = [C.c_void_p]
    lib.compositor_vulkan_raster_submissions.argtypes = [C.c_void_p]
    lib.compositor_vulkan_raster_submissions.restype = C.c_uint64
    lib.compositor_dispersion_render.argtypes = [C.c_void_p, C.c_uint, C.c_uint, floats, floats, floats]
    # Permit Mesa lavapipe so SDK/CI machines without a physical GPU exercise the shader too.
    gpu = lib.compositor_vulkan_raster_create(1)
    width, height = 61, 45
    source = [0.0] * (width * height * 4)
    for y in range(20, 25):
        for x in range(28, 33):
            source[(y * width + x) * 4:(y * width + x) * 4 + 4] = [0.5] * 4
    parameters = [30.5, 22.5, 1, 0, 8, 0, 20, 0, 0, 8, 1, 0, 0, 0, 0, 1, width, height, 0, 0]

    def run(p, pixels=source, w=width, h=height, driver=None):
        output = (C.c_float * (w * h * 4))()
        code = lib.compositor_dispersion_render(driver, w, h, (C.c_float * len(pixels))(*pixels),
                                               (C.c_float * 20)(*p), output)
        assert code == (1 if driver else 0), code
        return list(output)

    try:
        drivers = [None, gpu] if gpu else [None]
        for driver in drivers:
            # Direction, continuous spectrum, streaks, radial center and associated alpha.
            out = run(parameters, driver=driver)
            red = sum(out[(22 * width + x) * 4] for x in range(34, 42))
            blue = sum(out[(22 * width + x) * 4 + 2] for x in range(34, 42))
            assert red > blue * 2, (red, blue)
            assert all(math.isfinite(v) for v in out)
            for i in range(0, len(out), 4):
                assert all(-1e-6 <= out[i + c] <= out[i + 3] + 1e-6 for c in range(3))
                assert 0 <= out[i + 3] <= 0.500001
            streak = parameters.copy()
            streak[5], streak[10] = 16, 8
            blurred = run(streak, driver=driver)
            assert sum(blurred[(22 * width + x) * 4 + 3] for x in range(36, 41)) > 0
            # Blur without a spectral split spreads both ways and keeps the light's center.
            centered = streak.copy()
            centered[4], centered[9], centered[10] = 0, 1, 64
            symmetric = run(centered, driver=driver)
            weights = [symmetric[(22 * width + x) * 4 + 3] for x in range(width)]
            centroid = sum(x * weight for x, weight in enumerate(weights)) / sum(weights)
            assert abs(centroid - 30) < 0.6, centroid
            assert sum(weights[20:28]) > 0 and sum(weights[33:41]) > 0
            radial = parameters.copy()
            radial[7] = 1
            radial_result = run(radial, driver=driver)
            assert abs(radial_result[(22 * width + 30) * 4] - 0.5) < 1e-5
            # A different output size, translated origins and upward rows: no implicit same-size or row-order assumption.
            identity = parameters.copy()
            identity[4], identity[9], identity[10] = 0, 1, 1
            identity[11:16] = [27, 26, 0, 45, -1]
            result = run(identity, w=9, h=9, driver=driver)
            expected = []
            for y in range(9):
                start = ((19 + y) * width + 27) * 4
                expected.extend(source[start:start + 9 * 4])
            assert max(abs(a - b) for a, b in zip(result, expected)) < 1e-5
            # Outside an unextended side is clear; an enabled canvas edge repeats its nearest texel.
            constant = [0.2, 0.3, 0.4, 0.5] * (width * height)
            identity[11:16] = [-3, -3, 0, 0, 1]
            clear = run(identity, pixels=constant, w=2, h=2, driver=driver)
            assert max(abs(v) for v in clear) < 1e-6
            identity[8] = 15
            edge = run(identity, pixels=constant, w=2, h=2, driver=driver)
            assert max(abs(a - b) for a, b in zip(edge, [0.2, 0.3, 0.4, 0.5] * 4)) < 1e-5
        if gpu:
            assert lib.compositor_vulkan_raster_submissions(gpu) >= 6
            # sin/fract jitter can differ between GPU and libm. Hold the overall signal to the same mean/spread;
            # the pixel/geometry assertions above apply independently to each backend.
            ramp = []
            for y in range(height):
                for x in range(width):
                    disc = ((x - 40) / 14) ** 2 + ((y - 22) / 12) ** 2 < 1
                    ramp.extend([x / (width - 1), y / (height - 1), 40 / 255 if disc else (255 - x * 3) / 255, 1])
            cpu = run(parameters, pixels=ramp)
            hardware = run(parameters, pixels=ramp, driver=gpu)
            for channel in range(4):
                def statistics(values):
                    samples = values[channel::4]
                    mean = sum(samples) / len(samples)
                    spread = math.sqrt(sum((v - mean) ** 2 for v in samples) / len(samples))
                    return mean, spread
                for a, b in zip(statistics(cpu), statistics(hardware)):
                    assert abs(a - b) <= 2 / 255, (channel, a, b)
        print(f"Dispersion OK (CPU{' and hardware Vulkan' if gpu else ''}: spectrum, streaks, radial, alpha, ROI and edges)")
    finally:
        lib.compositor_vulkan_raster_destroy(gpu)


if __name__ == '__main__':
    main(sys.argv[1])
