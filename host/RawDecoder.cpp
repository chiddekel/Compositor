// Camera RAW decoding for the compat CoreImage `CIRAWFilter` (upstream's RawImporter develops through it), on LibRaw.
//
// Built for very large files (hundreds of MB): a file is opened and unpacked once (`compositor_raw_open`) and every
// develop re-processes that in-memory sensor data — the Develop sheet's sliders never re-read the file. Previews
// (`draft`) use LibRaw's half-size mode: no demosaic, a quarter of the pixels and memory. Full develops demosaic with
// LibRaw's OpenMP build across all cores. Output is premultiplied (opaque) RGBA8 sRGB, what the compat layer expects.
//
// White balance follows CIRAWFilter's model: `temperature` / `tint` start at the camera's as-shot values
// (estimated from its white-balance multipliers against daylight), and moving them scales the as-shot multipliers —
// warmer lifts red and lowers blue, positive tint lowers green (towards magenta), as in Photoshop / Lightroom.

#if __has_include(<libraw/libraw.h>)
#include <libraw/libraw.h>
#include "PerfTrace.h"
#include <QImage>
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <thread>
#include <vector>

namespace {

// LibRaw with the protected internals the direct preview needs.
struct Raw : LibRaw {
    bool fujiRotated() { return libraw_internal_data.internal_output_params.fuji_width != 0; }
    bool phaseOneCompressed() { return is_phaseone_compressed() != 0; }
};

struct RawHandle {
    Raw raw;
    float asShotMul[4] = {1, 1, 1, 1};
    float asShotTemperature = 5000;
    float asShotTint = 0;
    // Draft previews: the file decoded once at half size, in linear camera RGB with unit white balance, averaged down
    // to the preview size. Every slider change re-applies the pipeline to this small buffer (see developPreview).
    std::vector<float> preview;   // w * h * 3, 0...1
    int previewWidth = 0, previewHeight = 0;
};

// dcraw's gamma_curve (LibRaw uses the same): a power law with a linear toe, `pwr` = 1/gamma, `ts` = toe slope.
struct GammaCurve {
    double g[6] = {};
    GammaCurve(double pwr, double ts) {
        double bnd[2] = {0, 0}, r;
        g[0] = pwr; g[1] = ts; g[2] = g[3] = g[4] = 0;
        bnd[g[1] >= 1] = 1;
        if (g[1] && (g[1] - 1) * (g[0] - 1) <= 0) {
            for (int i = 0; i < 48; i++) {
                g[2] = (bnd[0] + bnd[1]) / 2;
                if (g[0]) bnd[(std::pow(g[2] / g[1], -g[0]) - 1) / g[0] - 1 / g[2] > -1] = g[2];
                else bnd[g[2] / std::exp(1 - 1 / g[2]) < g[1]] = g[2];
            }
            g[3] = g[2] / g[1];
            if (g[0]) g[4] = g[2] * (1 / g[0] - 1);
        }
        if (g[0]) g[5] = 1 / (g[1] * g[3] * g[3] / 2 - g[4] * (1 - g[3]) + (1 - std::pow(g[3], 1 + g[0])) * (1 + g[4]) / (1 + g[0])) - 1;
        else g[5] = 1 / (g[1] * g[3] * g[3] / 2 + 1 - g[2] - g[3] - g[2] * g[3] * (std::log(g[3]) - 1)) - 1;
    }
    double operator()(double r) const {   // forward curve, r in 0...1
        if (r < g[3]) return r * g[1];
        return g[0] ? std::pow(r, g[0]) * (1 + g[4]) - g[4] : std::log(r) * g[2] + 1;
    }
};

constexpr float kDaylight = 5000.0f;   // CIRAWFilter's neutral default

}  // namespace

extern "C" {

typedef struct CompositorRaw CompositorRaw;

// Opens and unpacks `path`. Reports the developed (oriented) pixel size and the as-shot temperature / tint.
CompositorRaw *compositor_raw_open(const char *path, int32_t *width, int32_t *height, float *temperature, float *tint) {
    if (!path) return nullptr;
    PERF_SCOPE("raw.open+unpack");
    auto handle = std::make_unique<RawHandle>();
    // LibRaw picks its I/O by size: large files are streamed through its buffered big-file reader, not read whole.
    if (handle->raw.open_file(path) != LIBRAW_SUCCESS) return nullptr;
    if (handle->raw.unpack() != LIBRAW_SUCCESS) return nullptr;
    const libraw_data_t &d = handle->raw.imgdata;
    int w = d.sizes.width, h = d.sizes.height;
    if (d.sizes.flip & 4) std::swap(w, h);   // 90° rotations swap the developed size
    if (width) *width = w;
    if (height) *height = h;
    // As-shot white balance: camera multipliers against the daylight (pre_mul) ones. Warm light (tungsten) makes the
    // camera boost blue, so a red-over-blue gain *below* daylight's means a lower colour temperature.
    const float *cam = d.color.cam_mul, *day = d.color.pre_mul;
    for (int i = 0; i < 4; ++i) handle->asShotMul[i] = cam[i] > 0 ? cam[i] : 1;
    if (handle->asShotMul[3] <= 0) handle->asShotMul[3] = handle->asShotMul[1];
    if (cam[0] > 0 && cam[2] > 0 && day[0] > 0 && day[2] > 0) {
        const double ratio = (cam[0] / cam[2]) / (day[0] / day[2]);
        handle->asShotTemperature = float(std::clamp(kDaylight * std::pow(ratio, 0.8), 2000.0, 12000.0));
        const double greenRatio = (cam[1] / std::sqrt(cam[0] * cam[2])) / (day[1] / std::sqrt(day[0] * day[2]));
        handle->asShotTint = float(std::clamp(-300.0 * std::log(greenRatio), -150.0, 150.0));
    }
    if (temperature) *temperature = handle->asShotTemperature;
    if (tint) *tint = handle->asShotTint;
    return reinterpret_cast<CompositorRaw *>(handle.release());
}

void compositor_raw_close(CompositorRaw *raw) { delete reinterpret_cast<RawHandle *>(raw); }

// Header only (no unpack): the developed size, for size checks before committing to a decode. 0 on success.
int32_t compositor_raw_probe(const char *path, int32_t *width, int32_t *height) {
    if (!path) return -1;
    auto raw = std::make_unique<LibRaw>();
    if (raw->open_file(path) != LIBRAW_SUCCESS) return -2;
    int w = raw->imgdata.sizes.width, h = raw->imgdata.sizes.height;
    if (raw->imgdata.sizes.flip & 4) std::swap(w, h);
    if (width) *width = w;
    if (height) *height = h;
    return 0;
}

// The preview straight from the unpacked sensor data (Bayer or X-Trans): every photosite, black-subtracted and
// normalised to the white level, box-averaged per colour into the preview grid, then oriented — what LibRaw's
// half-size develop gives with unit white balance, without its full-frame copies. All cores, a fraction of a second
// for 150 MP. False when the layout isn't a plain mosaic (the LibRaw path below handles those).
static bool buildPreviewFromMosaic(RawHandle *handle, int targetW, int targetH) {
    const libraw_data_t &d = handle->raw.imgdata;
    const unsigned filters = d.idata.filters;
    if (!d.rawdata.raw_image || !filters || handle->raw.fujiRotated() || d.idata.colors != 3) return false;
    if (qEnvironmentVariable("COMPOSITOR_RAW_PREVIEW") == QLatin1String("libraw")) return false;   // A/B switch
    PERF_SCOPE("raw.preview from mosaic");
    const int width = d.sizes.width, height = d.sizes.height;
    const int top = d.sizes.top_margin, left = d.sizes.left_margin;
    const size_t pitch = d.sizes.raw_pitch / 2;
    if (width <= 0 || height <= 0 || size_t(left + width) > pitch) return false;
    // The CFA repeats within 48 x 48 for every layout LibRaw reports (Bayer 2x2 / 16x16 tables, X-Trans 6x6).
    uint8_t cfa[48][48];
    for (int r = 0; r < 48; ++r)
        for (int c = 0; c < 48; ++c) { const int k = handle->raw.COLOR(r, c); cfa[r][c] = uint8_t(k == 3 ? 1 : k); }
    // Black: the common level plus each colour's offset (and a repeating pattern, when the camera has one).
    const unsigned *cb = d.color.cblack;
    const unsigned common = std::min({cb[0], cb[1], cb[2], cb[3]});
    const float base = float(d.color.black + common);
    const float range = std::max(1.0f, float(d.color.maximum) - base);
    const float channelBlack[4] = {base + float(cb[0] - common), base + float(cb[1] - common),
                                   base + float(cb[2] - common), base + float(cb[3] - common)};
    // Phase One compressed (IIQ): the black level is the file's base less per-column and per-row calibration, as
    // LibRaw's phase_one_subtract_black applies it before developing (raw coordinates, split at split_col/row).
    const auto &p1 = d.color.phase_one_data;
    const bool phaseOne = handle->raw.phaseOneCompressed() && d.rawdata.raw_alloc;
    const short (*p1Column)[2] = phaseOne ? d.rawdata.ph1_cblack : nullptr;
    const short (*p1Row)[2] = phaseOne ? d.rawdata.ph1_rblack : nullptr;
    const int patternH = int(cb[4]), patternW = int(cb[5]);
    const bool pattern = patternH > 0 && patternW > 0 && patternH * patternW <= LIBRAW_CBLACK_SIZE - 6;
    // Accumulate in the sensor's orientation; rows of the grid are split between threads, so no sums are shared.
    const bool transpose = d.sizes.flip & 4;
    const int gridW = transpose ? targetH : targetW, gridH = transpose ? targetW : targetH;
    std::vector<float> sums(size_t(gridW) * gridH * 3, 0.0f), counts(size_t(gridW) * gridH * 3, 0.0f);
    std::vector<int> column(width);
    for (int x = 0; x < width; ++x) column[x] = std::min(gridW - 1, int(int64_t(x) * gridW / width));
    const int threads = std::max(1, std::min<int>(gridH, int(std::thread::hardware_concurrency())));
    std::vector<std::thread> workers;
    for (int t = 0; t < threads; ++t) {
        workers.emplace_back([&, t] {
            const int g0 = int(int64_t(gridH) * t / threads), g1 = int(int64_t(gridH) * (t + 1) / threads);
            const int y0 = int((int64_t(g0) * height + gridH - 1) / gridH), y1 = int((int64_t(g1) * height + gridH - 1) / gridH);
            for (int y = y0; y < y1; ++y) {
                const int gy = std::min(gridH - 1, int(int64_t(y) * gridH / height));
                const uint16_t *row = (phaseOne ? static_cast<const uint16_t *>(d.rawdata.raw_alloc) : d.rawdata.raw_image)
                                      + size_t(y + top) * pitch + left;
                const int rawRow = y + top;
                float *sumRow = &sums[size_t(gy) * gridW * 3], *countRow = &counts[size_t(gy) * gridW * 3];
                const uint8_t *colours = cfa[y % 48];
                const unsigned *patternRow = pattern ? &cb[6 + (y % patternH) * patternW] : nullptr;
                for (int x = 0; x < width; ++x) {
                    const int c = colours[x % 48];
                    float v = float(row[x]) - channelBlack[c];
                    if (patternRow) v -= float(patternRow[x % patternW]);
                    if (phaseOne) {
                        const int rawCol = x + left;
                        float black = float(p1.t_black);
                        if (p1Column && p1Row)
                            black -= float(p1Column[rawRow][rawCol >= p1.split_col] + p1Row[rawCol][rawRow >= p1.split_row]);
                        v = std::max(0.0f, float(row[x]) - black) - channelBlack[c];
                    }
                    const size_t i = size_t(column[x]) * 3 + c;
                    sumRow[i] += std::clamp(v / range, 0.0f, 1.0f);
                    countRow[i] += 1;
                }
            }
        });
    }
    for (std::thread &worker : workers) worker.join();
    // Oriented as LibRaw orients its output (flip_index): transpose, then mirror rows / columns.
    handle->preview.assign(size_t(targetW) * targetH * 3, 0.0f);
    for (int row = 0; row < targetH; ++row) {
        for (int col = 0; col < targetW; ++col) {
            int r = row, c = col;
            if (transpose) std::swap(r, c);
            if (d.sizes.flip & 2) r = gridH - 1 - r;
            if (d.sizes.flip & 1) c = gridW - 1 - c;
            const size_t from = (size_t(r) * gridW + c) * 3, to = (size_t(row) * targetW + col) * 3;
            for (int k = 0; k < 3; ++k) handle->preview[to + k] = counts[from + k] > 0 ? sums[from + k] / counts[from + k] : 0.0f;
        }
    }
    handle->previewWidth = targetW; handle->previewHeight = targetH;
    return true;
}

// Decodes the half-size linear camera-RGB preview once, averaged down to `targetW` x `targetH`.
static bool buildPreview(RawHandle *handle, int targetW, int targetH) {
    if (handle->previewWidth == targetW && handle->previewHeight == targetH && !handle->preview.empty()) return true;
    if (buildPreviewFromMosaic(handle, targetW, targetH)) return true;
    PERF_SCOPE("raw.preview decode (once per file)");
    libraw_output_params_t &p = handle->raw.imgdata.params;
    p.half_size = 1; p.output_bps = 16; p.output_color = 0;   // raw camera colour, linear, no white balance
    p.use_camera_wb = 0; p.use_auto_wb = 0;
    for (float &m : p.user_mul) m = 1;
    p.gamm[0] = 1; p.gamm[1] = 1; p.no_auto_bright = 1; p.exp_correc = 0;
    if (handle->raw.dcraw_process() != LIBRAW_SUCCESS) return false;
    int error = 0;
    libraw_processed_image_t *image = handle->raw.dcraw_make_mem_image(&error);
    if (!image || error != LIBRAW_SUCCESS || image->colors != 3 || image->bits != 16) {
        if (image) LibRaw::dcraw_clear_mem(image);
        return false;
    }
    const int sw = image->width, sh = image->height;
    const auto *src = reinterpret_cast<const uint16_t *>(image->data);
    handle->preview.assign(size_t(targetW) * targetH * 3, 0.0f);
    // Box average: every source pixel lands in exactly one preview pixel.
    std::vector<float> weight(size_t(targetW) * targetH, 0.0f);
    for (int y = 0; y < sh; ++y) {
        const int ty = std::min(targetH - 1, int(int64_t(y) * targetH / sh));
        for (int x = 0; x < sw; ++x) {
            const int tx = std::min(targetW - 1, int(int64_t(x) * targetW / sw));
            const size_t t = size_t(ty) * targetW + tx, i = (size_t(y) * sw + x) * 3;
            float *out = &handle->preview[t * 3];
            out[0] += src[i]; out[1] += src[i + 1]; out[2] += src[i + 2];
            weight[t] += 1;
        }
    }
    for (size_t t = 0; t < weight.size(); ++t) {
        const float k = weight[t] > 0 ? 1.0f / (weight[t] * 65535.0f) : 0;
        for (int c = 0; c < 3; ++c) handle->preview[t * 3 + c] *= k;
    }
    LibRaw::dcraw_clear_mem(image);
    handle->previewWidth = targetW; handle->previewHeight = targetH;
    return true;
}

// The develop pipeline on the cached preview: white balance, camera -> sRGB, exposure, auto-brightening and the tone
// curve, as LibRaw's full develop applies them — milliseconds, whatever the file size.
static int32_t developPreview(RawHandle *handle, float exposure, float temperature, float tint, float boost,
                              int targetW, int targetH, uint8_t **pixels) {
    if (!buildPreview(handle, targetW, targetH)) return -2;
    PERF_SCOPE("raw.preview develop (per change)");
    const libraw_data_t &d = handle->raw.imgdata;
    const float warm = std::pow(std::max(1.0f, temperature) / handle->asShotTemperature, 0.6f);
    const float magenta = std::exp(-(tint - handle->asShotTint) / 300.0f);
    float mul[3] = {handle->asShotMul[0] * warm, handle->asShotMul[1] * magenta, handle->asShotMul[2] / warm};
    const float lowest = std::min({mul[0], mul[1], mul[2]});
    for (float &m : mul) m /= lowest > 0 ? lowest : 1;   // as LibRaw's scale_colors: no channel is scaled down
    const float shift = std::clamp(std::pow(2.0f, exposure), 0.25f, 8.0f);
    const size_t count = size_t(targetW) * targetH;
    std::vector<float> rgb(count * 3);
    for (size_t i = 0; i < count; ++i) {
        const float *cam = &handle->preview[i * 3];
        const float r = std::min(1.0f, cam[0] * mul[0]), g = std::min(1.0f, cam[1] * mul[1]), b = std::min(1.0f, cam[2] * mul[2]);
        for (int c = 0; c < 3; ++c) {
            const float v = d.color.rgb_cam[c][0] * r + d.color.rgb_cam[c][1] * g + d.color.rgb_cam[c][2] * b;
            rgb[i * 3 + c] = std::clamp(v * shift, 0.0f, 1.0f);
        }
    }
    // Auto-brightening (LibRaw's rule): the level below which 99 % of each channel falls becomes white.
    const float b = std::clamp(boost, 0.0f, 1.0f);
    float white = 1.0f;
    if (b >= 0.5f) {
        std::vector<int> histogram(0x2000, 0);
        for (size_t i = 0; i < count * 3; ++i) histogram[std::min(0x1fff, int(rgb[i] * 0x1fff))]++;
        const int perc = int(count * 0.01);
        int total = 0, level = 0x1fff;
        for (; level > 32; --level) if ((total += histogram[level]) > perc * 3) break;
        white = std::max(0.05f, float(level) / 0x1fff);
    }
    const GammaCurve curve(1.0 / (2.2 + 0.02 * b), 4.5 * b);
    auto *out = static_cast<uint8_t *>(std::malloc(count * 4));
    if (!out) return -3;
    for (size_t i = 0; i < count; ++i) {
        for (int c = 0; c < 3; ++c)
            out[i * 4 + c] = uint8_t(std::lround(255.0 * std::clamp(curve(std::min(1.0f, rgb[i * 3 + c] / white)), 0.0, 1.0)));
        out[i * 4 + 3] = 255;
    }
    *pixels = out;
    return 0;
}

// The full develop's demosaic: AHD (LibRaw's best general-purpose, OpenMP) unless COMPOSITOR_RAW_DEMOSAIC picks
// another of LibRaw's — linear, vng, ppg, ahd, dcb, dht, aahd — to trade quality for speed on very large files.
static int fullDemosaic() {
    static const int quality = [] {
        const QString name = qEnvironmentVariable("COMPOSITOR_RAW_DEMOSAIC").toLower();
        static const struct { const char *name; int quality; } table[] = {
            {"linear", 0}, {"vng", 1}, {"ppg", 2}, {"ahd", 3}, {"dcb", 4}, {"dht", 11}, {"aahd", 12}};
        for (const auto &entry : table) if (name == QLatin1String(entry.name)) return entry.quality;
        return 3;
    }();
    return quality;
}

// Develops the opened file. `scale` (0 < scale <= 1) is the output size relative to the full size; `draft` allows the
// fast half-size path. Returns 0 and a malloc'd premultiplied RGBA8 buffer (the caller frees it).
int32_t compositor_raw_develop(CompositorRaw *raw, float exposure, float temperature, float tint, float boost,
                               float scale, int32_t draft, uint8_t **pixels, int32_t *outWidth, int32_t *outHeight) {
    auto *handle = reinterpret_cast<RawHandle *>(raw);
    if (!handle || !pixels || !outWidth || !outHeight) return -1;
    if (draft && scale <= 0.5f) {   // preview: the cached small buffer, re-developed in milliseconds
        int fullW = handle->raw.imgdata.sizes.width, fullH = handle->raw.imgdata.sizes.height;
        if (handle->raw.imgdata.sizes.flip & 4) std::swap(fullW, fullH);
        const int w = std::max(1, int(std::lround(fullW * scale))), h = std::max(1, int(std::lround(fullH * scale)));
        const int32_t status = developPreview(handle, exposure, temperature, tint, boost, w, h, pixels);
        if (status == 0) { *outWidth = w; *outHeight = h; }
        return status;
    }
    libraw_output_params_t &p = handle->raw.imgdata.params;
    p.output_bps = 8;
    p.output_color = 1;                 // sRGB
    p.use_camera_wb = 0;
    p.use_auto_wb = 0;
    p.half_size = (draft && scale <= 0.5f) ? 1 : 0;
    p.user_qual = p.half_size ? 0 : fullDemosaic();
    // White balance: the as-shot multipliers, moved by the temperature / tint offsets.
    const float warm = std::pow(std::max(1.0f, temperature) / handle->asShotTemperature, 0.6f);
    const float magenta = std::exp(-(tint - handle->asShotTint) / 300.0f);
    p.user_mul[0] = handle->asShotMul[0] * warm;
    p.user_mul[1] = handle->asShotMul[1] * magenta;
    p.user_mul[2] = handle->asShotMul[2] / warm;
    p.user_mul[3] = handle->asShotMul[3] * magenta;
    // Exposure in linear space, keeping highlights from clipping hard when pushed up.
    p.exp_correc = exposure != 0 ? 1 : 0;
    p.exp_shift = std::clamp(std::pow(2.0f, exposure), 0.25f, 8.0f);
    p.exp_preser = 0.8f;
    // Boost: 1 is the standard tone curve (LibRaw's BT.709 gamma with auto-brightening), 0 a flatter, plain power curve.
    const float b = std::clamp(boost, 0.0f, 1.0f);
    p.gamm[0] = 1.0 / (2.2 + 0.02 * b);
    p.gamm[1] = 4.5 * b;
    p.no_auto_bright = b < 0.5f ? 1 : 0;

    PERF_SCOPE(p.half_size ? "raw.develop(draft, half size)" : "raw.develop(full)");
    {
        PERF_SCOPE("raw.develop: dcraw_process");
        if (handle->raw.dcraw_process() != LIBRAW_SUCCESS) return -2;
    }
    int error = 0;
    libraw_processed_image_t *image = nullptr;
    {
        PERF_SCOPE("raw.develop: make_mem_image");
        image = handle->raw.dcraw_make_mem_image(&error);
    }
    if (!image || error != LIBRAW_SUCCESS || image->colors != 3 || image->bits != 8) {
        if (image) LibRaw::dcraw_clear_mem(image);
        return -2;
    }
    PERF_SCOPE("raw.develop: to RGBA");
    const libraw_data_t &d = handle->raw.imgdata;
    int fullW = d.sizes.width, fullH = d.sizes.height;
    if (d.sizes.flip & 4) std::swap(fullW, fullH);
    const int targetW = std::max(1, int(std::lround(fullW * std::min(1.0f, scale))));
    const int targetH = std::max(1, int(std::lround(fullH * std::min(1.0f, scale))));
    if (image->width == targetW && image->height == targetH) {
        // Full size (the import): RGB -> opaque RGBA straight into the caller's buffer, rows split across cores.
        const size_t pixelsTotal = size_t(targetW) * targetH;
        auto *out = static_cast<uint8_t *>(std::malloc(pixelsTotal * 4));
        if (!out) { LibRaw::dcraw_clear_mem(image); return -3; }
        const uint8_t *in = image->data;
        const int threads = std::max(1, std::min<int>(targetH, int(std::thread::hardware_concurrency())));
        std::vector<std::thread> workers;
        for (int t = 0; t < threads; ++t) {
            workers.emplace_back([=] {
                const size_t from = pixelsTotal * t / threads, to = pixelsTotal * (t + 1) / threads;
                for (size_t i = from; i < to; ++i) {
                    out[i * 4] = in[i * 3]; out[i * 4 + 1] = in[i * 3 + 1]; out[i * 4 + 2] = in[i * 3 + 2]; out[i * 4 + 3] = 255;
                }
            });
        }
        for (std::thread &worker : workers) worker.join();
        LibRaw::dcraw_clear_mem(image);
        *pixels = out;
        *outWidth = targetW;
        *outHeight = targetH;
        return 0;
    }
    // Down to the requested size (the half-size path is already most of the way there).
    QImage developed(image->data, image->width, image->height, image->width * 3, QImage::Format_RGB888);
    QImage rgba = (developed.width() != targetW || developed.height() != targetH)
        ? developed.scaled(targetW, targetH, Qt::IgnoreAspectRatio, Qt::SmoothTransformation).convertToFormat(QImage::Format_RGBA8888)
        : developed.convertToFormat(QImage::Format_RGBA8888);
    LibRaw::dcraw_clear_mem(image);
    const size_t rowBytes = size_t(rgba.width()) * 4, bytes = rowBytes * rgba.height();
    auto *copy = static_cast<uint8_t *>(std::malloc(bytes));
    if (!copy) return -3;
    for (int y = 0; y < rgba.height(); ++y) std::memcpy(copy + y * rowBytes, rgba.constScanLine(y), rowBytes);
    *pixels = copy;
    *outWidth = rgba.width();
    *outHeight = rgba.height();
    return 0;
}

typedef CompositorRaw *(*CompositorRawOpenFn)(const char *, int32_t *, int32_t *, float *, float *);
typedef int32_t (*CompositorRawDevelopFn)(CompositorRaw *, float, float, float, float, float, int32_t, uint8_t **, int32_t *, int32_t *);
typedef void (*CompositorRawCloseFn)(CompositorRaw *);
typedef int32_t (*CompositorRawProbeFn)(const char *, int32_t *, int32_t *);
void compositor_raw_register(CompositorRawProbeFn probe, CompositorRawOpenFn open, CompositorRawDevelopFn develop,
                             CompositorRawCloseFn close) __attribute__((weak));

// Called at startup (with the image codecs): hands the decoder to the compat layer.
int compositor_raw_install(void) {
    if (!compositor_raw_register) return 0;
    compositor_raw_register(compositor_raw_probe, compositor_raw_open, compositor_raw_develop, compositor_raw_close);
    return 1;
}

}  // extern "C"

#else
extern "C" int compositor_raw_install(void) { return 0; }   // built without LibRaw: RAW files stay unreadable
#endif
