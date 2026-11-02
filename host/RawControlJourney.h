#pragma once
#include <QByteArray>
#include <QTemporaryDir>
#include <QDebug>
#include <memory>
#include <functional>
#include <stdexcept>
#include <vector>
#include <cstdint>
#include <cstdlib>
#if __has_include(<libraw/libraw.h>)
#include <tiffio.h>
extern "C" {
struct CompositorRaw;
CompositorRaw *compositor_raw_open(const char *, int32_t *, int32_t *, float *, float *);
void compositor_raw_close(CompositorRaw *);
int compositor_raw_install(void);
int32_t compositor_raw_capabilities(CompositorRaw *, uint32_t *, float *, int32_t *, int32_t *);
int32_t compositor_raw_develop(CompositorRaw *, float, float, float, float, float, int32_t, int32_t, float, int32_t,
                              uint8_t **, int32_t *, int32_t *);
}
#endif

inline void verifyRawControls(const std::function<void(const QString &)> &verifySheet) {
#if __has_include(<libraw/libraw.h>)
    const auto require = [](bool ok, const char *message) { if (!ok) throw std::runtime_error(message); };
    require(compositor_raw_install() == 1, "RAW callbacks were not registered");
    QTemporaryDir temporary;
    require(temporary.isValid(), "RAW fixture directory unavailable");
    const auto makeDng = [&](int side) {
        const QString path = temporary.filePath(QString("sensor-%1.dng").arg(side));
        auto file = std::unique_ptr<TIFF, decltype(&TIFFClose)>(TIFFOpen(path.toUtf8().constData(), "w"), TIFFClose);
        require(bool(file), "DNG fixture could not open");
        const uint8_t version[4] = {1, 4, 0, 0}, backward[4] = {1, 1, 0, 0};
        const uint16_t repeat[2] = {2, 2};
        const uint8_t pattern[4] = {0, 1, 1, 2}, planes[3] = {0, 1, 2};
        const float matrix[9] = {3.2406f, -1.5372f, -0.4986f, -0.9689f, 1.8758f, 0.0415f, 0.0557f, -0.2040f, 1.0570f};
        const float neutral[3] = {1, 1, 0.5f}, black = 0;
        const uint32_t white = 65535;
        TIFFSetField(file.get(), TIFFTAG_IMAGEWIDTH, side);
        TIFFSetField(file.get(), TIFFTAG_IMAGELENGTH, side);
        TIFFSetField(file.get(), TIFFTAG_BITSPERSAMPLE, 16);
        TIFFSetField(file.get(), TIFFTAG_SAMPLESPERPIXEL, 1);
        TIFFSetField(file.get(), TIFFTAG_PHOTOMETRIC, PHOTOMETRIC_CFA);
        TIFFSetField(file.get(), TIFFTAG_PLANARCONFIG, PLANARCONFIG_CONTIG);
        TIFFSetField(file.get(), TIFFTAG_COMPRESSION, COMPRESSION_NONE);
        TIFFSetField(file.get(), TIFFTAG_ROWSPERSTRIP, side);
        TIFFSetField(file.get(), TIFFTAG_DNGVERSION, version);
        TIFFSetField(file.get(), TIFFTAG_DNGBACKWARDVERSION, backward);
        TIFFSetField(file.get(), TIFFTAG_UNIQUECAMERAMODEL, "Compositor test sensor");
        TIFFSetField(file.get(), TIFFTAG_MAKE, "Compositor");
        TIFFSetField(file.get(), TIFFTAG_MODEL, "Test sensor");
        TIFFSetField(file.get(), TIFFTAG_CFAREPEATPATTERNDIM, repeat);
        TIFFSetField(file.get(), TIFFTAG_CFAPATTERN, 4, pattern);
        TIFFSetField(file.get(), TIFFTAG_CFAPLANECOLOR, 3, planes);
        TIFFSetField(file.get(), TIFFTAG_CFALAYOUT, 1);
        TIFFSetField(file.get(), TIFFTAG_BLACKLEVEL, 1, &black);
        TIFFSetField(file.get(), TIFFTAG_WHITELEVEL, 1, &white);
        TIFFSetField(file.get(), TIFFTAG_COLORMATRIX1, 9, matrix);
        TIFFSetField(file.get(), TIFFTAG_ASSHOTNEUTRAL, 3, neutral);
        TIFFSetField(file.get(), TIFFTAG_CALIBRATIONILLUMINANT1, 21);
        uint32_t random = 17;
        std::vector<uint16_t> row(side);
        for (int y = 0; y < side; ++y) {
            for (int x = 0; x < side; ++x) {
                random = random * 1664525u + 1013904223u;
                const int grain = int((random >> 16) % 8001) - 4000;
                const int channel = pattern[(y % 2) * 2 + x % 2];
                const int base = channel == 2 ? 16000 : 22000;
                row[x] = channel == 0 && x >= side / 2 && x < side * 3 / 4 ? 65535 : uint16_t(base + grain);
            }
            require(TIFFWriteScanline(file.get(), row.data(), y) >= 0, "DNG fixture scanline write failed");
        }
        return path;
    };
    for (int side : {256, 96, 64}) {
        const QString path = makeDng(side);
        int32_t width = 0, height = 0; float temperature = 0, tint = 0;
        auto raw = std::unique_ptr<CompositorRaw, decltype(&compositor_raw_close)>(
            compositor_raw_open(path.toUtf8().constData(), &width, &height, &temperature, &tint), compositor_raw_close);
        require(bool(raw) && width == side && height == side, "LibRaw could not unpack the generated DNG");
        uint32_t flags = 0; float noiseDefault = -1; int32_t lensDefault = -1, highlightDefault = -1;
        require(compositor_raw_capabilities(raw.get(), &flags, &noiseDefault, &lensDefault, &highlightDefault) == 0,
                "RAW capabilities query failed");
        require((flags & 2u) == 0 && lensDefault == 0, "RAW advertised unsupported lens correction");
        require(((flags & 1u) != 0) == (side >= 130) && (flags & 4u) != 0, "RAW capability flags ignored sensor support");
        require(noiseDefault == 0 && highlightDefault == 0, "RAW defaults did not match its engine");
        const auto develop = [&](float noise, bool highlight, bool draft, float previewScale = 0.25f) {
            uint8_t *pixels = nullptr; int32_t w = 0, h = 0;
            const int status = compositor_raw_develop(raw.get(), 0, temperature, tint, 0.25f, noise, 1, highlight ? 1 : 0,
                                                       draft ? previewScale : 1.0f, draft ? 1 : 0, &pixels, &w, &h);
            auto owned = std::unique_ptr<uint8_t, decltype(&std::free)>(pixels, std::free);
            if (status != 0 || !pixels || w != (draft ? int(side * previewScale) : side) || h != w)
                qWarning("RAW fixture side=%d noise=%.2f highlight=%d draft=%d status=%d output=%dx%d", side, noise, highlight, draft, status, w, h);
            require(status == 0 && pixels && w == (draft ? int(side * previewScale) : side) && h == w, "RAW controls develop failed or changed dimensions");
            return QByteArray(reinterpret_cast<const char *>(pixels), w * h * 4);
        };
        const QByteArray baseline = develop(0, false, true);
        const QByteArray smallerBaseline = develop(0, false, true, 0.125f);
        for (bool draft : {true, false}) {
            const QByteArray noNoise = develop(0, true, draft), denoised = develop(0.8f, true, draft);
            require((noNoise != denoised) == (side >= 130), "RAW noise reduction was missing or applied despite unsupported capability");
            if (side >= 130) require(develop(0.8f, false, draft) != denoised, "RAW highlight recovery did not change partially clipped data");
        }
        require(develop(0, false, true, 0.125f) == smallerBaseline, "RAW reset changed the resized default preview pixels");
        require(develop(0, false, true) == baseline, "RAW reset changed the default preview pixels");
        uint32_t afterFlags = 0;
        require(compositor_raw_capabilities(raw.get(), &afterFlags, &noiseDefault, &lensDefault, &highlightDefault) == 0 && afterFlags == flags,
                "RAW processing changed capability flags");
        if (side == 256) verifySheet(path);
    }
    qInfo("Qt RAW controls OK (generated Bayer DNGs, preview/full noise and highlight pixels, honest capabilities, unsupported lens correction)");
#else
    throw std::runtime_error("RAW backend missing from native contract verification");
#endif
}
