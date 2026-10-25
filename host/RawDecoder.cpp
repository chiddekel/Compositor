// Camera RAW decoding for the compat CoreImage `CIRAWFilter` (upstream's RawImporter develops through it), on LibRaw.
//
// Built for very large files (hundreds of MB): a file is opened and unpacked once (`compositor_raw_open`) and every
// develop re-processes that in-memory sensor data — the Develop sheet's sliders never re-read the file. Previews
// (`draft`) use LibRaw's half-size mode: no demosaic, a quarter of the pixels and memory. Full develops demosaic with
// LibRaw's OpenMP build across all cores. Full imports can retain opaque RGBA16 sRGB; draft previews use RGBA8.
//
// White balance follows CIRAWFilter's model: `temperature` / `tint` start at the camera's as-shot values
// (estimated from its white-balance multipliers against daylight), and moving them scales the as-shot multipliers —
// warmer lifts red and lowers blue, positive tint lowers green (towards magenta), as in Photoshop / Lightroom.

#if __has_include(<libraw/libraw.h>)
#include <libraw/libraw.h>
#include "PerfTrace.h"
#include "RawLensProfile.h"
#include "RawLensfun.h"
#include <QImage>
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <limits>
#include <thread>
#include <vector>

namespace {

// LibRaw with the protected internals the direct preview needs.
struct Raw : LibRaw {
    bool fujiRotated() { return libraw_internal_data.internal_output_params.fuji_width != 0; }
    bool phaseOneCompressed() { return is_phaseone_compressed() != 0; }
    // After changing the developed pixels: the histogram auto-brightening reads, rebuilt as convert_to_rgb fills it.
    void rebuildHistogram() {
        auto *histogram = libraw_internal_data.output_data.histogram;
        if (!histogram || !imgdata.image) return;
        std::memset(histogram, 0, sizeof(int) * LIBRAW_HISTOGRAM_SIZE * 4);
        const size_t count = size_t(imgdata.sizes.width) * imgdata.sizes.height;
        const int colors = std::min<int>(imgdata.idata.colors, 4);
        for (size_t i = 0; i < count; ++i)
            for (int c = 0; c < colors; ++c) histogram[c][imgdata.image[i][c] >> 3]++;
    }
};

// Reads `len` values of TIFF `type` at the stream's position, in the file's byte order (`order`: 'II' or 'MM').
static std::vector<double> readTagValues(void *stream, int type, int len, unsigned order) {
    static const int sizes[] = {0, 1, 1, 2, 4, 8, 1, 1, 2, 4, 8, 4, 8};
    std::vector<double> values;
    if (type < 1 || type > 12 || len <= 0 || len > 4096) return values;
    const size_t size = size_t(sizes[type]) * len;
    std::vector<uint8_t> bytes(size);
    auto *in = static_cast<LibRaw_abstract_datastream *>(stream);
    if (!in || in->read(bytes.data(), 1, size) != int(size)) return values;
    const bool little = order == 0x4949;
    const auto word = [&](const uint8_t *p, int n) {
        uint64_t v = 0;
        for (int i = 0; i < n; ++i) v |= uint64_t(p[little ? i : n - 1 - i]) << (8 * i);
        return v;
    };
    for (int i = 0; i < len; ++i) {
        const uint8_t *p = bytes.data() + size_t(sizes[type]) * i;
        switch (type) {
            case 1: case 2: case 7: values.push_back(p[0]); break;
            case 6: values.push_back(int8_t(p[0])); break;
            case 3: values.push_back(uint16_t(word(p, 2))); break;
            case 8: values.push_back(int16_t(word(p, 2))); break;
            case 4: values.push_back(uint32_t(word(p, 4))); break;
            case 9: values.push_back(int32_t(word(p, 4))); break;
            case 5: { const double d = uint32_t(word(p + 4, 4)); values.push_back(d ? uint32_t(word(p, 4)) / d : 0); break; }
            case 10: { const double d = int32_t(word(p + 4, 4)); values.push_back(d ? int32_t(word(p, 4)) / d : 0); break; }
            case 11: { const uint32_t b = uint32_t(word(p, 4)); float f; std::memcpy(&f, &b, 4); values.push_back(f); break; }
            case 12: { const uint64_t b = word(p, 8); double f; std::memcpy(&f, &b, 8); values.push_back(f); break; }
        }
    }
    return values;
}

// LibRaw hands every TIFF / maker-note tag it walks to these; the lens-profile ones are kept (RawLensProfile.h).
static void collectLensTag(void *context, int tag, int type, int len, unsigned order, void *stream, INT64) {
    auto *tags = static_cast<rawlens::Tags *>(context);
    const int id = tag & 0xffff, space = (tag >> 16) & 0xf;
    if (space == 0) {   // a plain TIFF IFD (ARW SubIFD, RAF FujiIFD)
        switch (id) {
            case 0x7037: tags->sonyDistortion = readTagValues(stream, type, len, order); break;
            case 0x7035: tags->sonyChromatic = readTagValues(stream, type, len, order); break;
            case 0x7032: tags->sonyVignetting = readTagValues(stream, type, len, order); break;
            case 0xf00b: tags->fujiDistortion = readTagValues(stream, type, len, order); break;
            case 0xf00f: tags->fujiChromatic = readTagValues(stream, type, len, order); break;
            case 0xf010: tags->fujiVignetting = readTagValues(stream, type, len, order); break;
        }
    } else if (space == 3 && id == 0x0119 && len == 32) {   // Panasonic RW2 IFD0: DistortionInfo, 16 x int16
        const std::vector<double> bytes = readTagValues(stream, 7, 32, order);
        if (bytes.size() == 32) {
            tags->panasonicDistortion.resize(16);
            for (int i = 0; i < 16; ++i) {
                const unsigned lo = unsigned(bytes[2 * i]), hi = unsigned(bytes[2 * i + 1]);
                tags->panasonicDistortion[i] = int16_t(order == 0x4949 ? (hi << 8 | lo) : (lo << 8 | hi));
            }
        }
    }
}

static void collectLensMakernote(void *context, int tag, int type, int len, unsigned order, void *stream, INT64) {
    auto *tags = static_cast<rawlens::Tags *>(context);
    const int id = tag & 0xffff, parent = (tag >> 16) & 0xffff;
    if (parent == 0x2040 && id == 0x150a) tags->olympusDistortion = readTagValues(stream, type, len, order);
    else if (parent == 0x2040 && id == 0x150c) tags->olympusChromatic = readTagValues(stream, type, len, order);
    else if (parent == 0 && id == 0x104d) {   // Fujifilm CropMode
        const std::vector<double> mode = readTagValues(stream, type, len, order);
        if (!mode.empty()) tags->fujiCropMode = int(mode[0]);
    }
}

struct RawHandle {
    Raw raw;
    libraw_image_sizes_t sensorSizes = {};
    libraw_colordata_t sensorColor = {};
    int nativeWidth = 0, nativeHeight = 0;
    uint32_t capabilities = 0;
    uint8_t sensorCFA[48][48] = {};
    bool mosaicPreview = false;
    float asShotMul[4] = {1, 1, 1, 1};
    float asShotTemperature = 5000;
    float asShotTint = 0;
    float defaultNoiseReduction = 0;
    int defaultHighlightMode = 0;
    // The lens profile the file carries (empty when it has none); applied when lens correction is on.
    rawlens::Tags lensTags;
    rawlens::Profile lens;
    // Draft previews: the file decoded once at half size, in linear camera RGB with unit white balance, averaged down
    // to the preview size. Every slider change re-applies the pipeline to this small buffer (see developPreview).
    std::vector<float> preview;   // w * h * 3, 0...1
    int previewWidth = 0, previewHeight = 0;
    std::vector<float> correctedPreview;   // `preview` with the lens profile applied, made on first use
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

template <typename Sample>
bool copyOpaqueRGBA(const uint8_t *source, uint8_t *destination, int width, int height, size_t rowBytes) {
    const int threads = std::max(1, std::min<int>(height, int(std::thread::hardware_concurrency())));
    std::vector<std::thread> workers;
    try {
        workers.reserve(threads);
        for (int t = 0; t < threads; ++t) {
            workers.emplace_back([=] {
                for (int y = height * t / threads; y < height * (t + 1) / threads; ++y) {
                    const auto *in = reinterpret_cast<const Sample *>(source) + size_t(y) * width * 3;
                    auto *out = reinterpret_cast<Sample *>(destination + size_t(y) * rowBytes);
                    for (int x = 0; x < width; ++x) {
                        out[x * 4] = in[x * 3]; out[x * 4 + 1] = in[x * 3 + 1]; out[x * 4 + 2] = in[x * 3 + 2];
                        out[x * 4 + 3] = std::numeric_limits<Sample>::max();
                    }
                }
            });
        }
    } catch (...) {
        for (auto &worker : workers) worker.join();
        return false;
    }
    for (auto &worker : workers) worker.join();
    return true;
}

constexpr float kDaylight = 5000.0f;   // CIRAWFilter's neutral default

}  // namespace

extern "C" {

#ifdef LIBRAW_WITH_RAWSPEED3
// RawSpeed asks its host how many threads it may use (darktable provides this; so do we).
int rawspeed_get_number_of_processor_cores() { return std::max(1, int(std::thread::hardware_concurrency())); }
#endif

typedef struct CompositorRaw CompositorRaw;

// Opens and unpacks `path`. Reports the developed (oriented) pixel size and the as-shot temperature / tint.
CompositorRaw *compositor_raw_open(const char *path, int32_t *width, int32_t *height, float *temperature, float *tint) {
    if (!path) return nullptr;
    PERF_SCOPE("raw.open+unpack");
    auto handle = std::make_unique<RawHandle>();
    handle->raw.set_exifparser_handler(collectLensTag, &handle->lensTags);
    handle->raw.set_makernotes_handler(collectLensMakernote, &handle->lensTags);
    // LibRaw picks its I/O by size: large files are streamed through its buffered big-file reader, not read whole.
    if (handle->raw.open_file(path) != LIBRAW_SUCCESS) return nullptr;
#ifdef LIBRAW_WITH_RAWSPEED3
    // Built with RawSpeed (scripts/build-rawspeed.sh): LibRaw hands the formats RawSpeed decodes faster to it, and
    // falls back to its own decoder for anything else. COMPOSITOR_RAWSPEED=0 keeps LibRaw's decoders only.
    // RawSpeed decodes from memory, so LibRaw reads the whole file first (and skips it for files over 2 GB).
    handle->raw.imgdata.rawparams.use_rawspeed = qEnvironmentVariable("COMPOSITOR_RAWSPEED") == QLatin1String("0")
        ? 0 : LIBRAW_RAWSPEEDV3_USE;
#endif
    {
        PERF_SCOPE("raw.unpack");
        if (handle->raw.unpack() != LIBRAW_SUCCESS) return nullptr;
    }
    const libraw_data_t &d = handle->raw.imgdata;
    int w = d.sizes.width, h = d.sizes.height;
    if (d.sizes.flip & 4) std::swap(w, h);   // 90° rotations swap the developed size
    handle->sensorSizes = d.sizes;
    handle->sensorColor = d.color;
    handle->nativeWidth = w; handle->nativeHeight = h;
    handle->mosaicPreview = d.rawdata.raw_image && d.idata.filters && !handle->raw.fujiRotated() && d.idata.colors == 3;
    if (handle->mosaicPreview)
        for (int row = 0; row < 48; ++row)
            for (int col = 0; col < 48; ++col) {
                const int channel = handle->raw.COLOR(row, col);
                handle->sensorCFA[row][col] = uint8_t(channel == 3 ? 1 : channel);
            }
    // LibRaw packs mosaic channels into a half-size working image for wavelet denoising.
    const bool shrink = d.idata.filters && !d.rawdata.color4_image && !d.rawdata.color3_image
                      && !d.rawdata.float4_image && !d.rawdata.float3_image;
    const int noiseW = shrink ? (w + 1) / 2 : w, noiseH = shrink ? (h + 1) / 2 : h;
    const uint64_t count = uint64_t(noiseW) * noiseH;
    handle->capabilities = (noiseW >= 65 && noiseH >= 65 && count < 0x15540000ULL ? 1u : 0u)
                         | (d.idata.colors >= 3 && w >= 8 && h >= 8 ? 4u : 0u);
    // Lens profile: DNG OpcodeList3 (kept by LibRaw for the selected raw IFD) or the maker's tags gathered above.
    // SuperCCD's 45-degree sensor layout has no such profile.
    if (const auto &opcodes = d.color.dng_levels.rawopcodes[2]; opcodes.data && opcodes.len > 0)
        handle->lensTags.dngOpcodeList3.assign(static_cast<const uint8_t *>(opcodes.data),
                                               static_cast<const uint8_t *>(opcodes.data) + opcodes.len);
    if (!handle->raw.fujiRotated() && d.idata.colors >= 3) handle->lens = rawlens::buildProfile(handle->lensTags, w, h);
#if defined(COMPOSITOR_HAS_LENSFUN)
    // No profile in the file: the camera and lens it names, from the lens database (as Apple's RAW engine does).
    if (!handle->lens.valid() && !handle->raw.fujiRotated() && d.idata.colors >= 3) {
        PERF_SCOPE("raw.open: lensfun profile");
        rawlens::Shot shot;
        shot.cameraMaker = d.idata.make;
        shot.cameraModel = d.idata.model;
        shot.lensMaker = d.lens.LensMake;
        shot.lensModel = d.lens.Lens[0] ? d.lens.Lens : d.lens.makernotes.Lens;
        shot.focal = d.other.focal_len;
        shot.aperture = d.other.aperture;
        handle->lens = rawlens::lensfunProfile(shot, w, h);
    }
#endif
    handle->raw.set_exifparser_handler(nullptr, nullptr);
    handle->raw.set_makernotes_handler(nullptr, nullptr);
    if (handle->lens.valid()) handle->capabilities |= 2u;
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
    if (!d.rawdata.raw_image || !handle->mosaicPreview) return false;
    if (qEnvironmentVariable("COMPOSITOR_RAW_PREVIEW") == QLatin1String("libraw")) return false;   // A/B switch
    PERF_SCOPE("raw.preview from mosaic");
    const int width = handle->sensorSizes.width, height = handle->sensorSizes.height;
    const int top = handle->sensorSizes.top_margin, left = handle->sensorSizes.left_margin;
    const size_t pitch = handle->sensorSizes.raw_pitch / 2;
    if (width <= 0 || height <= 0 || size_t(left + width) > pitch) return false;
    // The CFA repeats within 48 x 48 for every layout LibRaw reports (Bayer 2x2 / 16x16 tables, X-Trans 6x6).
    const auto &cfa = handle->sensorCFA;
    // Black: the common level plus each colour's offset (and a repeating pattern, when the camera has one).
    const unsigned *cb = handle->sensorColor.cblack;
    const unsigned common = std::min({cb[0], cb[1], cb[2], cb[3]});
    const float base = float(handle->sensorColor.black + common);
    const float range = std::max(1.0f, float(handle->sensorColor.maximum) - base);
    const float channelBlack[4] = {base + float(cb[0] - common), base + float(cb[1] - common),
                                   base + float(cb[2] - common), base + float(cb[3] - common)};
    // Phase One compressed (IIQ): the black level is the file's base less per-column and per-row calibration, as
    // LibRaw's phase_one_subtract_black applies it before developing (raw coordinates, split at split_col/row).
    const auto &p1 = handle->sensorColor.phase_one_data;
    // (Unpacked by RawSpeed, the data sits in raw_image until LibRaw's first develop moves it to raw_alloc.)
    const bool phaseOne = handle->raw.phaseOneCompressed()
        && (d.rawdata.raw_alloc || (d.process_warnings & LIBRAW_WARN_RAWSPEED3_PROCESSED));
    const uint16_t *phaseOneData = static_cast<const uint16_t *>(d.rawdata.raw_alloc ? d.rawdata.raw_alloc : d.rawdata.raw_image);
    const short (*p1Column)[2] = phaseOne ? d.rawdata.ph1_cblack : nullptr;
    const short (*p1Row)[2] = phaseOne ? d.rawdata.ph1_rblack : nullptr;
    const int patternH = int(cb[4]), patternW = int(cb[5]);
    const bool pattern = patternH > 0 && patternW > 0 && patternH * patternW <= LIBRAW_CBLACK_SIZE - 6;
    // Accumulate in the sensor's orientation; rows of the grid are split between threads, so no sums are shared.
    const bool transpose = handle->sensorSizes.flip & 4;
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
                const uint16_t *row = (phaseOne ? phaseOneData : d.rawdata.raw_image)
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
            if (handle->sensorSizes.flip & 2) r = gridH - 1 - r;
            if (handle->sensorSizes.flip & 1) c = gridW - 1 - c;
            const size_t from = (size_t(r) * gridW + c) * 3, to = (size_t(row) * targetW + col) * 3;
            for (int k = 0; k < 3; ++k) handle->preview[to + k] = counts[from + k] > 0 ? sums[from + k] / counts[from + k] : 0.0f;
        }
    }
    handle->previewWidth = targetW; handle->previewHeight = targetH;
    handle->correctedPreview.clear();
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
    p.threshold = handle->defaultNoiseReduction * 1000.0f; p.highlight = handle->defaultHighlightMode;
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
    handle->correctedPreview.clear();
    return true;
}

// The develop pipeline on the cached preview: white balance, camera -> sRGB, exposure, auto-brightening and the tone
// curve, as LibRaw's full develop applies them — milliseconds, whatever the file size.
static int32_t developPreview(RawHandle *handle, float exposure, float temperature, float tint, float boost,
                              bool lensCorrection, int targetW, int targetH, uint8_t **pixels) {
    if (!buildPreview(handle, targetW, targetH)) return -2;
    PERF_SCOPE("raw.preview develop (per change)");
    const std::vector<float> *source = &handle->preview;
    if (lensCorrection && handle->lens.valid()) {
        if (handle->correctedPreview.size() != handle->preview.size()) {
            PERF_SCOPE("raw.preview lens correction (once per size)");
            handle->correctedPreview = handle->preview;
            rawlens::apply(handle->lens, handle->correctedPreview.data(), targetW, targetH, 3, 3, 4.0f,
                           rawlens::Orientation{handle->sensorSizes.flip});
        }
        source = &handle->correctedPreview;
    }
    const float warm = std::pow(std::max(1.0f, temperature) / handle->asShotTemperature, 0.6f);
    const float magenta = std::exp(-(tint - handle->asShotTint) / 300.0f);
    float mul[3] = {handle->asShotMul[0] * warm, handle->asShotMul[1] * magenta, handle->asShotMul[2] / warm};
    const float lowest = std::min({mul[0], mul[1], mul[2]});
    for (float &m : mul) m /= lowest > 0 ? lowest : 1;   // as LibRaw's scale_colors: no channel is scaled down
    const float shift = std::clamp(std::pow(2.0f, exposure), 0.25f, 8.0f);
    const size_t count = size_t(targetW) * targetH;
    std::vector<float> rgb(count * 3);
    for (size_t i = 0; i < count; ++i) {
        const float *cam = &(*source)[i * 3];
        const float r = std::min(1.0f, cam[0] * mul[0]), g = std::min(1.0f, cam[1] * mul[1]), b = std::min(1.0f, cam[2] * mul[2]);
        for (int c = 0; c < 3; ++c) {
            const float v = handle->sensorColor.rgb_cam[c][0] * r + handle->sensorColor.rgb_cam[c][1] * g + handle->sensorColor.rgb_cam[c][2] * b;
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
int32_t compositor_raw_capabilities(CompositorRaw *raw, uint32_t *flags, float *noise, int32_t *lens, int32_t *highlight) {
    auto *handle = reinterpret_cast<RawHandle *>(raw);
    if (!handle || !flags || !noise || !lens || !highlight) return -1;
    *flags = handle->capabilities;
    *noise = handle->defaultNoiseReduction;
    *lens = handle->lens.valid() ? 1 : 0;   // as Apple's: on by default where the file has a profile
    *highlight = handle->defaultHighlightMode > 2 ? 1 : 0;
    return 0;
}

static int32_t rawDevelop(CompositorRaw *raw, float exposure, float temperature, float tint, float boost,
                               float noiseReduction, int32_t lensCorrection, int32_t highlightRecovery,
                               float scale, int32_t draft, uint8_t **pixels, int32_t *outWidth, int32_t *outHeight,
                               int bitsPerComponent) {
    auto *handle = reinterpret_cast<RawHandle *>(raw);
    if (!handle || !pixels || !outWidth || !outHeight || !std::isfinite(exposure) || !std::isfinite(temperature)
        || !std::isfinite(tint) || !std::isfinite(boost) || !std::isfinite(scale) || scale <= 0) return -1;
    uint32_t capabilities = 0; float defaultNoise = 0; int32_t defaultLens = 0, defaultHighlight = 0;
    compositor_raw_capabilities(raw, &capabilities, &defaultNoise, &defaultLens, &defaultHighlight);
    const float noise = capabilities & 1u && std::isfinite(noiseReduction) ? std::clamp(noiseReduction, 0.0f, 1.0f) : defaultNoise;
    const bool recover = capabilities & 4u ? highlightRecovery != 0 : defaultHighlight != 0;
    const bool correctLens = capabilities & 2u ? lensCorrection != 0 : defaultLens != 0;
    if (bitsPerComponent == 8 && draft && scale <= 0.5f && noise == defaultNoise && recover == (defaultHighlight != 0)) {   // cached preview
        const int fullW = handle->nativeWidth, fullH = handle->nativeHeight;
        const int w = std::max(1, int(std::lround(fullW * scale))), h = std::max(1, int(std::lround(fullH * scale)));
        const int32_t status = developPreview(handle, exposure, temperature, tint, boost, correctLens, w, h, pixels);
        if (status == 0) { *outWidth = w; *outHeight = h; }
        return status;
    }
    libraw_output_params_t &p = handle->raw.imgdata.params;
    p.threshold = noise * 1000.0f;
    p.highlight = recover ? 3 : handle->defaultHighlightMode;
    p.output_bps = bitsPerComponent;
    p.output_color = 1;                 // sRGB
    p.use_camera_wb = 0;
    p.use_auto_wb = 0;
    p.half_size = (draft && scale <= 0.5f && (!noise || (handle->nativeWidth >= 130 && handle->nativeHeight >= 130))) ? 1 : 0;
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
        const int status = handle->raw.dcraw_process();
        if (status != LIBRAW_SUCCESS) { qWarning("RAW develop failed: %s", libraw_strerror(status)); return -2; }
    }
    if (correctLens && handle->lens.valid() && handle->raw.imgdata.image) {
        // The developed pixels are linear, in sensor orientation (LibRaw orients them when it writes the output).
        PERF_SCOPE("raw.develop: lens correction");
        libraw_data_t &d = handle->raw.imgdata;
        rawlens::apply(handle->lens, &d.image[0][0], d.sizes.width, d.sizes.height, 4, std::min<int>(d.idata.colors, 3), 65535.0f);
        handle->raw.rebuildHistogram();
    }
    int error = 0;
    libraw_processed_image_t *image = nullptr;
    {
        PERF_SCOPE("raw.develop: make_mem_image");
        image = handle->raw.dcraw_make_mem_image(&error);
    }
    if (!image || error != LIBRAW_SUCCESS || image->colors != 3 || image->bits != bitsPerComponent) {
        qWarning("RAW output failed: error=%d colors=%d bits=%d", error, image ? image->colors : 0, image ? image->bits : 0);
        if (image) LibRaw::dcraw_clear_mem(image);
        return -2;
    }
    PERF_SCOPE("raw.develop: to RGBA");
    const int fullW = handle->nativeWidth, fullH = handle->nativeHeight;
    const int targetW = std::max(1, int(std::lround(fullW * std::min(1.0f, scale))));
    const int targetH = std::max(1, int(std::lround(fullH * std::min(1.0f, scale))));
    if (image->width == targetW && image->height == targetH) {
        // Full size (the import): RGB -> opaque RGBA straight into the caller's buffer, rows split across cores.
        const size_t pixelsTotal = size_t(targetW) * targetH;
        const size_t rowBytes = size_t(targetW) * 4 * (bitsPerComponent / 8);
        if (pixelsTotal > std::numeric_limits<size_t>::max() / (4 * (bitsPerComponent / 8))) {
            LibRaw::dcraw_clear_mem(image); return -1;
        }
        auto *out = static_cast<uint8_t *>(std::malloc(rowBytes * targetH));
        if (!out) { LibRaw::dcraw_clear_mem(image); return -3; }
        const bool copied = bitsPerComponent == 16 ? copyOpaqueRGBA<uint16_t>(image->data, out, targetW, targetH, rowBytes)
                                                  : copyOpaqueRGBA<uint8_t>(image->data, out, targetW, targetH, rowBytes);
        if (!copied) { std::free(out); LibRaw::dcraw_clear_mem(image); return -3; }
        LibRaw::dcraw_clear_mem(image);
        *pixels = out;
        *outWidth = targetW;
        *outHeight = targetH;
        return 0;
    }
    // Down to the requested size (the half-size path is already most of the way there).
    QImage rgba;
    if (bitsPerComponent == 16) {
        rgba = QImage(image->width, image->height, QImage::Format_RGBA64);
        if (rgba.isNull()) { LibRaw::dcraw_clear_mem(image); return -3; }
        if (!copyOpaqueRGBA<uint16_t>(image->data, rgba.bits(), image->width, image->height, size_t(rgba.bytesPerLine()))) {
            LibRaw::dcraw_clear_mem(image); return -3;
        }
        if (rgba.width() != targetW || rgba.height() != targetH)
            rgba = rgba.scaled(targetW, targetH, Qt::IgnoreAspectRatio, Qt::SmoothTransformation).convertToFormat(QImage::Format_RGBA64);
    } else {
        QImage developed(image->data, image->width, image->height, image->width * 3, QImage::Format_RGB888);
        rgba = (developed.width() != targetW || developed.height() != targetH)
            ? developed.scaled(targetW, targetH, Qt::IgnoreAspectRatio, Qt::SmoothTransformation).convertToFormat(QImage::Format_RGBA8888)
            : developed.convertToFormat(QImage::Format_RGBA8888);
    }
    LibRaw::dcraw_clear_mem(image);
    if (rgba.isNull()) return -3;
    const size_t rowBytes = size_t(rgba.width()) * 4 * (bitsPerComponent / 8), bytes = rowBytes * rgba.height();
    auto *copy = static_cast<uint8_t *>(std::malloc(bytes));
    if (!copy) return -3;
    for (int y = 0; y < rgba.height(); ++y) std::memcpy(copy + y * rowBytes, rgba.constScanLine(y), rowBytes);
    *pixels = copy;
    *outWidth = rgba.width();
    *outHeight = rgba.height();
    return 0;
}

int32_t compositor_raw_develop(CompositorRaw *raw, float exposure, float temperature, float tint, float boost,
                               float noiseReduction, int32_t lensCorrection, int32_t highlightRecovery,
                               float scale, int32_t draft, uint8_t **pixels, int32_t *width, int32_t *height) {
    return rawDevelop(raw, exposure, temperature, tint, boost, noiseReduction, lensCorrection, highlightRecovery,
                      scale, draft, pixels, width, height, 8);
}

int32_t compositor_raw_develop16(CompositorRaw *raw, float exposure, float temperature, float tint, float boost,
                                 float noiseReduction, int32_t lensCorrection, int32_t highlightRecovery,
                                 float scale, int32_t draft, uint16_t **pixels, int32_t *width, int32_t *height) {
    if (!pixels) return -1;
    uint8_t *bytes = nullptr;
    const int32_t status = rawDevelop(raw, exposure, temperature, tint, boost, noiseReduction, lensCorrection, highlightRecovery,
                                     scale, draft, &bytes, width, height, 16);
    if (status == 0) *pixels = reinterpret_cast<uint16_t *>(bytes);
    return status;
}

typedef CompositorRaw *(*CompositorRawOpenFn)(const char *, int32_t *, int32_t *, float *, float *);
typedef int32_t (*CompositorRawDevelopFn)(CompositorRaw *, float, float, float, float, float, int32_t, int32_t, float, int32_t, uint8_t **, int32_t *, int32_t *);
typedef int32_t (*CompositorRawDevelop16Fn)(CompositorRaw *, float, float, float, float, float, int32_t, int32_t, float, int32_t, uint16_t **, int32_t *, int32_t *);
typedef int32_t (*CompositorRawCapabilitiesFn)(CompositorRaw *, uint32_t *, float *, int32_t *, int32_t *);
typedef void (*CompositorRawCloseFn)(CompositorRaw *);
typedef int32_t (*CompositorRawProbeFn)(const char *, int32_t *, int32_t *);
void compositor_raw_register(CompositorRawProbeFn probe, CompositorRawOpenFn open, CompositorRawDevelopFn develop,
                             CompositorRawCloseFn close, CompositorRawCapabilitiesFn capabilities) __attribute__((weak));
void compositor_raw_register_v2(CompositorRawProbeFn probe, CompositorRawOpenFn open, CompositorRawDevelopFn develop,
                                CompositorRawCloseFn close, CompositorRawCapabilitiesFn capabilities,
                                CompositorRawDevelop16Fn develop16) __attribute__((weak));

// Called at startup (with the image codecs): hands the decoder to the compat layer.
int compositor_raw_install(void) {
    if (compositor_raw_register_v2)
        compositor_raw_register_v2(compositor_raw_probe, compositor_raw_open, compositor_raw_develop, compositor_raw_close,
                                   compositor_raw_capabilities, compositor_raw_develop16);
    else if (compositor_raw_register)
        compositor_raw_register(compositor_raw_probe, compositor_raw_open, compositor_raw_develop, compositor_raw_close, compositor_raw_capabilities);
    else return 0;
    return 1;
}

}  // extern "C"

#else
extern "C" int compositor_raw_install(void) { return 0; }   // built without LibRaw: RAW files stay unreadable
#endif
