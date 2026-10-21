#undef NDEBUG
#include "../backends/brush/include/CompositorBrushBackend.h"
#include <array>
#include <cassert>
#include <cmath>
#include <cstdio>
#include <limits>

int main() {
    constexpr size_t pixels = 32 * 32;
    CompositorBrushUniforms u{1, 0, 0, 1, 0, 0, 4, 1, 32, 32, 1, 0.25f, 32, 32, 1, 1};
    CompositorBrushSegment segment{5, 16, 26, 16};
    CompositorBrushDynamics dynamic{4, 1, 1, 0.25f};
    std::array<float, pixels> prior{}, next{}, cap{}, nextCap{}, reference{};
    std::array<uint8_t, pixels> preview{}, plain{};
    auto render = [&] { return compositor_brush_pressure_cpu(&u, &segment, &dynamic, 1, prior.data(), cap.data(),
        pixels, next.data(), nextCap.data(), preview.data()); };
    assert(render() == 0);
    assert(preview[16 * 32 + 6] > 230 && preview[16 * 32 + 25] < 85);
    assert(preview[18 * 32 + 6] > 0 && preview[18 * 32 + 25] == 0);
    // Uniform dynamics preserve the legacy brush, including soft density integration.
    dynamic = {4, 4, 1, 1};
    for (float hardness : {0.0f, 0.5f, 1.0f}) {
        u.hardness = hardness;
        assert(render() == 0);
        assert(compositor_brush_cpu(&u, &segment, 1, prior.data(), pixels, reference.data(), plain.data()) == 0);
        for (size_t i = 0; i < pixels; ++i) assert(std::abs(int(preview[i]) - int(plain[i])) <= 1);
    }
    // A light soft stroke builds up density, but never exceeds its strongest pressure.
    u.hardness = 0; dynamic = {4, 4, 0.5f, 0.5f};
    for (int pass = 0; pass < 4; ++pass) { assert(render() == 0); prior = next; cap = nextCap; }
    assert(preview[16 * 32 + 16] >= 125 && preview[16 * 32 + 16] <= 128);
    // A provisional stronger tail must not leak its cap into the permanent tile.
    u.settled_count = 0; dynamic.strength0 = dynamic.strength1 = 1;
    assert(render() == 0);
    assert(nextCap == cap);
    dynamic.strength0 = dynamic.strength1 = 0;
    assert(render() == 0);
    assert(preview[16 * 32 + 16] <= 128);
    // Invalid input preserves every output, so the caller can retry without publishing a partial tile.
    const auto saved = next; const auto savedCap = nextCap; const auto savedPreview = preview;
    dynamic.radius0 = std::numeric_limits<float>::quiet_NaN();
    assert(render() == -1);
    assert(next == saved && nextCap == savedCap && preview == savedPreview);
    std::puts("Pressure brush: varying tip, legacy parity, opacity cap, tail replacement and invalid-input checks passed");
}
