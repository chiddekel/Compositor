// RAW lens correction end to end: generated DNGs carrying an OpcodeList3 (FixVignetteRadial, WarpRectilinear) go through
// LibRaw and the decoder exactly as an import does — capabilities, the full develop and the draft preview — and a DNG
// without a profile stays uncorrected, as on the Mac. `CompositorHostBootstrap --raw-lens-smoke`.
#include <QByteArray>
#include <QDebug>
#include <QString>
#include <QTemporaryDir>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <functional>
#include <memory>
#include <stdexcept>
#include <vector>

#if __has_include(<libraw/libraw.h>)
#include <tiffio.h>
extern "C" {
struct CompositorRaw;
CompositorRaw *compositor_raw_open(const char *, int32_t *, int32_t *, float *, float *);
void compositor_raw_close(CompositorRaw *);
int32_t compositor_raw_capabilities(CompositorRaw *, uint32_t *, float *, int32_t *, int32_t *);
int32_t compositor_raw_develop(CompositorRaw *, float, float, float, float, float, int32_t, int32_t, float, int32_t,
                              uint8_t **, int32_t *, int32_t *);
}

namespace {

void require(bool ok, const char *message) { if (!ok) throw std::runtime_error(message); }

struct Bytes {
    std::vector<uint8_t> data;
    void u32(uint32_t v) { for (int i = 3; i >= 0; --i) data.push_back(uint8_t(v >> (8 * i))); }
    void f64(double v) { uint64_t b; std::memcpy(&b, &v, 8); for (int i = 7; i >= 0; --i) data.push_back(uint8_t(b >> (8 * i))); }
    void op(uint32_t id, const Bytes &params) {
        u32(id); u32(0x01030000); u32(0); u32(uint32_t(params.data.size()));
        data.insert(data.end(), params.data.begin(), params.data.end());
    }
};

std::vector<uint8_t> vignetteList(double k0) {
    Bytes params;
    params.f64(k0); for (int i = 0; i < 4; ++i) params.f64(0);
    params.f64(0.5); params.f64(0.5);
    Bytes list; list.u32(1); list.op(3, params);
    return list.data;
}

std::vector<uint8_t> warpList(double kr0) {
    Bytes params;
    params.u32(1);
    params.f64(kr0); for (int i = 0; i < 5; ++i) params.f64(0);
    params.f64(0.5); params.f64(0.5);
    Bytes list; list.u32(1); list.op(1, params);
    return list.data;
}

// The camera and lens a DNG names (IFD0 Make/Model, EXIF LensModel/FocalLength/FNumber), for the lens database.
struct Shot {
    const char *make = "Compositor", *model = "Lens sensor", *lens = nullptr;
    double focal = 0, aperture = 0;
};

// A Bayer DNG, neutral grey, with a bright vertical line at `lineX` when >= 0, and the given OpcodeList3.
QString makeDng(const QTemporaryDir &dir, const char *name, int w, int h, int lineX, const std::vector<uint8_t> &opcodes,
                const Shot &shot = {}) {
    const QString path = dir.filePath(name);
    auto file = std::unique_ptr<TIFF, decltype(&TIFFClose)>(TIFFOpen(path.toUtf8().constData(), "w"), TIFFClose);
    require(bool(file), "lens DNG could not open");
    const uint8_t version[4] = {1, 4, 0, 0}, backward[4] = {1, 3, 0, 0};
    const uint16_t repeat[2] = {2, 2};
    const uint8_t pattern[4] = {0, 1, 1, 2}, planes[3] = {0, 1, 2};
    const float matrix[9] = {1, 0, 0, 0, 1, 0, 0, 0, 1};
    const float neutral[3] = {1, 1, 1}, black = 0;
    const uint32_t white = 65535;
    TIFF *t = file.get();
    TIFFSetField(t, TIFFTAG_IMAGEWIDTH, w);
    TIFFSetField(t, TIFFTAG_IMAGELENGTH, h);
    TIFFSetField(t, TIFFTAG_BITSPERSAMPLE, 16);
    TIFFSetField(t, TIFFTAG_SAMPLESPERPIXEL, 1);
    TIFFSetField(t, TIFFTAG_PHOTOMETRIC, PHOTOMETRIC_CFA);
    TIFFSetField(t, TIFFTAG_PLANARCONFIG, PLANARCONFIG_CONTIG);
    TIFFSetField(t, TIFFTAG_COMPRESSION, COMPRESSION_NONE);
    TIFFSetField(t, TIFFTAG_ROWSPERSTRIP, h);
    TIFFSetField(t, TIFFTAG_DNGVERSION, version);
    TIFFSetField(t, TIFFTAG_DNGBACKWARDVERSION, backward);
    TIFFSetField(t, TIFFTAG_UNIQUECAMERAMODEL, "Compositor lens sensor");
    TIFFSetField(t, TIFFTAG_MAKE, shot.make);
    TIFFSetField(t, TIFFTAG_MODEL, shot.model);
    TIFFSetField(t, TIFFTAG_CFAREPEATPATTERNDIM, repeat);
    TIFFSetField(t, TIFFTAG_CFAPATTERN, 4, pattern);
    TIFFSetField(t, TIFFTAG_CFAPLANECOLOR, 3, planes);
    TIFFSetField(t, TIFFTAG_CFALAYOUT, 1);
    TIFFSetField(t, TIFFTAG_BLACKLEVEL, 1, &black);
    TIFFSetField(t, TIFFTAG_WHITELEVEL, 1, &white);
    TIFFSetField(t, TIFFTAG_COLORMATRIX1, 9, matrix);
    TIFFSetField(t, TIFFTAG_ASSHOTNEUTRAL, 3, neutral);
    TIFFSetField(t, TIFFTAG_CALIBRATIONILLUMINANT1, 21);
    if (!opcodes.empty()) {
        // libtiff knows OpcodeList3's number but has no field definition for it: declare it (undefined, counted).
        static const TIFFFieldInfo opcodeList3[] = {
            {TIFFTAG_OPCODELIST3, TIFF_VARIABLE2, TIFF_VARIABLE2, TIFF_UNDEFINED, FIELD_CUSTOM, 1, 1, const_cast<char *>("OpcodeList3")}};
        require(TIFFMergeFieldInfo(t, opcodeList3, 1) == 0, "OpcodeList3 field could not be declared");
        require(TIFFSetField(t, TIFFTAG_OPCODELIST3, uint32_t(opcodes.size()), opcodes.data()) == 1, "OpcodeList3 not written");
    }
    std::vector<uint16_t> row(w);
    for (int y = 0; y < h; ++y) {
        for (int x = 0; x < w; ++x) row[x] = lineX >= 0 && std::abs(x - lineX) <= 1 ? 52000 : 9000;
        require(TIFFWriteScanline(t, row.data(), y) >= 0, "lens DNG scanline write failed");
    }
    if (shot.lens) {
        // EXIF IFD after the image: written as its own directory, then pointed to from IFD0.
        require(TIFFWriteDirectory(t) == 1, "lens DNG IFD0 not written");
        require(TIFFCreateEXIFDirectory(t) == 0, "EXIF directory could not be created");
        TIFFSetField(t, EXIFTAG_LENSMODEL, shot.lens);
        TIFFSetField(t, EXIFTAG_FOCALLENGTH, shot.focal);
        TIFFSetField(t, EXIFTAG_FNUMBER, shot.aperture);
        uint64_t exif = 0;
        require(TIFFWriteCustomDirectory(t, &exif) == 1, "EXIF directory not written");
        require(TIFFSetDirectory(t, 0) == 1, "lens DNG IFD0 not found again");
        TIFFSetField(t, TIFFTAG_EXIFIFD, exif);
        require(TIFFRewriteDirectory(t) == 1, "lens DNG IFD0 not rewritten with its EXIF pointer");
    }
    return path;
}

struct Developed {
    std::vector<uint8_t> rgba;
    int w = 0, h = 0;
    int at(int x, int y, int c = 1) const { return rgba[(size_t(y) * w + x) * 4 + c]; }
    double block(int x0, int y0, int n) const {
        double sum = 0;
        for (int y = y0; y < y0 + n; ++y) for (int x = x0; x < x0 + n; ++x) sum += at(x, y);
        return sum / (n * n);
    }
    int brightestColumn(int y) const {
        int best = 0;
        for (int x = 1; x < w; ++x) if (at(x, y) > at(best, y)) best = x;
        return best;
    }
};

using Raw = std::unique_ptr<CompositorRaw, decltype(&compositor_raw_close)>;

Raw open(const QString &path) {
    int32_t w = 0, h = 0; float temperature = 0, tint = 0;
    Raw raw(compositor_raw_open(path.toUtf8().constData(), &w, &h, &temperature, &tint), compositor_raw_close);
    require(bool(raw), "lens DNG did not open");
    return raw;
}

Developed develop(CompositorRaw *raw, bool lens, float scale, bool draft) {
    uint8_t *pixels = nullptr; int32_t w = 0, h = 0;
    // Boost 0: no auto-brightening, so lens on and off are compared on the same tone curve.
    require(compositor_raw_develop(raw, 0, 5000, 0, 0, 0, lens ? 1 : 0, 0, scale, draft ? 1 : 0, &pixels, &w, &h) == 0 && pixels,
            "lens DNG develop failed");
    Developed out;
    out.rgba.assign(pixels, pixels + size_t(w) * h * 4);
    out.w = w; out.h = h;
    std::free(pixels);
    return out;
}

void verify() {
    QTemporaryDir dir;
    require(dir.isValid(), "lens fixture directory unavailable");
    const int w = 320, h = 240;

    // No profile: unsupported, off by default, and asking for it changes nothing.
    {
        Raw raw = open(makeDng(dir, "plain.dng", w, h, -1, {}));
        uint32_t flags = 0; float noise = 0; int32_t lens = -1, highlight = 0;
        require(compositor_raw_capabilities(raw.get(), &flags, &noise, &lens, &highlight) == 0, "capabilities failed");
        require((flags & 2u) == 0 && lens == 0, "a DNG without OpcodeList3 claims a lens profile");
        require(develop(raw.get(), true, 1, false).rgba == develop(raw.get(), false, 1, false).rgba,
                "lens correction changed a file that has no profile");
    }

    // FixVignetteRadial: supported, on by default, corners brightened in the full develop and the draft preview.
    {
        Raw raw = open(makeDng(dir, "vignette.dng", w, h, -1, vignetteList(1.0)));
        uint32_t flags = 0; float noise = 0; int32_t lens = -1, highlight = 0;
        require(compositor_raw_capabilities(raw.get(), &flags, &noise, &lens, &highlight) == 0, "capabilities failed");
        require((flags & 2u) != 0 && lens == 1, "OpcodeList3 vignette not offered as lens correction (on by default)");
        for (const auto &[scale, draft] : {std::pair{1.0f, false}, std::pair{0.25f, true}}) {
            const Developed off = develop(raw.get(), false, scale, draft), on = develop(raw.get(), true, scale, draft);
            const int n = std::max(2, off.w / 20);
            const double offCorner = off.block(0, 0, n), onCorner = on.block(0, 0, n);
            const double offCentre = off.block(off.w / 2 - n / 2, off.h / 2 - n / 2, n), onCentre = on.block(on.w / 2 - n / 2, on.h / 2 - n / 2, n);
            qInfo("lens vignette %s: corner %.1f -> %.1f, centre %.1f -> %.1f", draft ? "draft" : "full", offCorner, onCorner, offCentre, onCentre);
            require(onCorner > offCorner + 20, "vignette correction did not brighten the corners");
            require(std::abs(onCentre - offCentre) < 4, "vignette correction changed the centre");
        }
    }

#if defined(COMPOSITOR_HAS_LENSFUN)
    // No profile in the file, but a camera and lens the lens database knows (lensfun): offered and on by default, as
    // Apple's RAW engine does from its own database; the corners brighten (the lens vignettes wide open). An unknown
    // lens on the same camera is not offered.
    {
        const Shot known{"Canon", "Canon EOS 5D Mark III", "EF70-200mm f/2.8L IS II USM", 70, 2.8};
        Raw raw = open(makeDng(dir, "lensfun.dng", w, h, -1, {}, known));
        uint32_t flags = 0; float noise = 0; int32_t lens = -1, highlight = 0;
        require(compositor_raw_capabilities(raw.get(), &flags, &noise, &lens, &highlight) == 0, "capabilities failed");
        require((flags & 2u) != 0 && lens == 1, "a lens the database knows is not offered as lens correction");
        const Developed off = develop(raw.get(), false, 1, false), on = develop(raw.get(), true, 1, false);
        const int n = std::max(2, off.w / 20);
        const double offCorner = off.block(0, 0, n), onCorner = on.block(0, 0, n);
        qInfo("lensfun vignette: corner %.1f -> %.1f", offCorner, onCorner);
        require(onCorner > offCorner + 10, "the database's vignetting correction did not brighten the corners");
        Shot unknown = known;
        unknown.lens = "Compositor 50mm f/1.0 Imaginary";
        Raw other = open(makeDng(dir, "unknown-lens.dng", w, h, -1, {}, unknown));
        require(compositor_raw_capabilities(other.get(), &flags, &noise, &lens, &highlight) == 0, "capabilities failed");
        require((flags & 2u) == 0 && lens == 0, "an unknown lens was offered lens correction");
    }
#endif

    // WarpRectilinear: kr0 < 1 magnifies about the centre, so a line right of centre moves outwards.
    {
        const int line = w * 3 / 4;
        Raw raw = open(makeDng(dir, "warp.dng", w, h, line, warpList(0.9)));
        for (const auto &[scale, draft] : {std::pair{1.0f, false}, std::pair{0.5f, true}}) {
            const Developed off = develop(raw.get(), false, scale, draft), on = develop(raw.get(), true, scale, draft);
            const int offColumn = off.brightestColumn(off.h / 2), onColumn = on.brightestColumn(on.h / 2);
            const double centre = 0.5 * off.w, expected = centre + (offColumn + 0.5 - centre) / 0.9 - 0.5;
            qInfo("lens warp %s: line column %d -> %d (expected %.1f)", draft ? "draft" : "full", offColumn, onColumn, expected);
            require(std::abs(onColumn - expected) <= 1.5, "warp did not move the line where WarpRectilinear puts it");
        }
    }
}

}  // namespace

extern "C" int compositor_host_raw_lens_smoke(int, char **) {
    try {
        verify();
#if defined(COMPOSITOR_HAS_LENSFUN)
        qInfo("RAW lens correction OK (DNG OpcodeList3 vignette and warp, lensfun database profile, full and draft develops, no-profile files untouched)");
#else
        qInfo("RAW lens correction OK (DNG OpcodeList3 vignette and warp, full and draft develops, no-profile files untouched)");
#endif
        return 0;
    } catch (const std::exception &e) {
        qCritical("RAW lens journey failed: %s", e.what());
        return 1;
    }
}
#else
extern "C" int compositor_host_raw_lens_smoke(int, char **) { qCritical("built without LibRaw"); return 1; }
#endif
