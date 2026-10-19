// Lens correction from the profile a camera RAW file carries, for the compat `CIRAWFilter.isLensCorrectionEnabled`.
//
// Upstream's Develop sheet promises "the lens's distortion and vignetting taken out, from the profile in the file, where
// it has one" — what Apple's RAW engine reads from the file itself. The same sources are read here:
//
//   DNG                 OpcodeList3: WarpRectilinear (radial + tangential, per plane) and FixVignetteRadial, as the
//                       DNG specification (1.4+) defines them, applied in list order in sensor coordinates.
//   Sony ARW            DistortionCorrParams / ChromaticAberrationCorrParams / VignettingCorrParams (0x7037/0x7035/0x7032)
//   Fujifilm RAF        GeometricDistortionParams / ChromaticAberrationParams / VignettingParams (0xf00b/0xf00f/0xf010),
//                       CropMode (0x104d) for the 1.25x crop
//   OM System/Olympus   ImageProcessing 0x150a (distortion) and 0x150c (chromatic aberration)
//   Panasonic RW2       DistortionInfo (0x0119)
//
// The maker-note encodings and their radial models (radius normalised to the half diagonal, centred) follow the
// public descriptions by ExifTool and darktable. Like Apple's output, a corrected image keeps its size: the radial
// models are scaled so no empty border shows. Files without any of these get no lens correction, as on the Mac.
//
// Pure C++ (no LibRaw or Qt), so the parsing and the resampling are unit-tested directly (tests/test_raw_lens.cpp).

#pragma once
#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <thread>
#include <type_traits>
#include <vector>

namespace rawlens {

// A piecewise-linear function of the normalised radius; flat beyond its first and last knots.
struct Spline {
    std::vector<float> x, y;
    bool empty() const { return x.empty(); }
    float operator()(float r) const {
        if (x.empty()) return 1.0f;
        if (r <= x.front()) return y.front();
        for (size_t i = 1; i < x.size(); ++i)
            if (r <= x[i]) {
                const float span = x[i] - x[i - 1];
                return span > 0 ? y[i - 1] + (r - x[i - 1]) * (y[i] - y[i - 1]) / span : y[i];
            }
        return y.back();
    }
};

struct DngOp {
    enum Kind { Warp, Vignette } kind = Warp;
    int planes = 1;
    double kr[3][4] = {};   // WarpRectilinear radial terms per plane
    double kt[3][2] = {};   // ... and tangential terms
    double k[5] = {};       // FixVignetteRadial k0...k4
    double cx = 0.5, cy = 0.5;
};

// What a file carries, gathered while LibRaw parses it (values converted to numbers in the file's byte order).
struct Tags {
    std::vector<uint8_t> dngOpcodeList3;
    std::vector<double> sonyDistortion, sonyChromatic, sonyVignetting;
    std::vector<double> fujiDistortion, fujiChromatic, fujiVignetting;
    int fujiCropMode = 0;
    std::vector<double> olympusDistortion, olympusChromatic;
    std::vector<int16_t> panasonicDistortion;
};

struct Profile {
    enum Source { None, Dng, Sony, Fuji, Olympus, Panasonic, Lensfun } source = None;
    std::vector<DngOp> dng;     // DNG: the opcodes, in list order
    Spline vignette;            // radial: the source pixel is divided by this at its radius
    Spline distortion[3];       // radial: source radius / destination radius, per channel, at the destination radius
    bool valid() const { return source != None; }
};

// Orientation of a buffer relative to the sensor, as LibRaw's `flip`: bit 4 transposes, 2 mirrors rows, 1 columns.
struct Orientation {
    int flip = 0;
};

namespace detail {

inline uint32_t be32(const uint8_t *p) { return uint32_t(p[0]) << 24 | uint32_t(p[1]) << 16 | uint32_t(p[2]) << 8 | p[3]; }
inline double beDouble(const uint8_t *p) {
    uint64_t bits = 0;
    for (int i = 0; i < 8; ++i) bits = bits << 8 | p[i];
    double value;
    std::memcpy(&value, &bits, sizeof value);
    return value;
}

// Fits the radial distortion model so the corrected frame has no empty border (the largest source/destination ratio
// along the frame edge, from the short side to the corner), then folds that scale into the spline.
inline void autoscale(Spline (&distortion)[3], float shortOverDiagonal) {
    float scale = 0;
    for (int i = 0; i < 200; ++i) {
        const float r = shortOverDiagonal + (1.0f - shortOverDiagonal) * float(i) / 199.0f;
        for (const Spline &s : distortion) scale = std::max(scale, s(r));
    }
    if (!(scale > 0) || !std::isfinite(scale)) return;
    for (Spline &s : distortion) {
        for (float &knot : s.x) knot *= scale;
        for (float &value : s.y) value /= scale;
    }
}

inline bool finite(const std::vector<double> &values) {
    return std::all_of(values.begin(), values.end(), [](double v) { return std::isfinite(v); });
}

}  // namespace detail

// DNG OpcodeList3 (big-endian, DNG 1.4 §6): WarpRectilinear (id 1) and FixVignetteRadial (id 3) are kept; any other
// opcode is skipped. False when the list is malformed or holds neither.
inline bool parseOpcodeList3(const uint8_t *data, size_t size, std::vector<DngOp> &ops) {
    ops.clear();
    if (!data || size < 4) return false;
    uint32_t count = detail::be32(data);
    size_t offset = 4;
    while (count-- > 0) {
        if (offset + 16 > size) return false;
        const uint32_t id = detail::be32(data + offset), bytes = detail::be32(data + offset + 12);
        const uint8_t *param = data + offset + 16;
        if (bytes > size - offset - 16) return false;
        if (id == 1 && bytes >= 4) {
            const uint32_t planes = detail::be32(param);
            if ((planes == 1 || planes == 3) && bytes >= 4 + 8 * (6 * planes + 2)) {
                DngOp op;
                op.kind = DngOp::Warp;
                op.planes = int(planes);
                for (uint32_t p = 0; p < planes; ++p) {
                    for (int i = 0; i < 4; ++i) op.kr[p][i] = detail::beDouble(param + 4 + 8 * (p * 6 + i));
                    for (int i = 0; i < 2; ++i) op.kt[p][i] = detail::beDouble(param + 4 + 8 * (p * 6 + 4 + i));
                }
                op.cx = detail::beDouble(param + 4 + 8 * (planes * 6));
                op.cy = detail::beDouble(param + 4 + 8 * (planes * 6 + 1));
                ops.push_back(op);
            }
        } else if (id == 3 && bytes >= 8 * 7) {
            DngOp op;
            op.kind = DngOp::Vignette;
            for (int i = 0; i < 5; ++i) op.k[i] = detail::beDouble(param + 8 * i);
            op.cx = detail::beDouble(param + 40);
            op.cy = detail::beDouble(param + 48);
            ops.push_back(op);
        }
        offset += 16 + bytes;
    }
    const auto sane = [](const DngOp &op) {
        bool ok = std::isfinite(op.cx) && std::isfinite(op.cy);
        for (int p = 0; p < 3; ++p) {
            for (double v : op.kr[p]) ok = ok && std::isfinite(v);
            for (double v : op.kt[p]) ok = ok && std::isfinite(v);
        }
        for (double v : op.k) ok = ok && std::isfinite(v);
        return ok;
    };
    ops.erase(std::remove_if(ops.begin(), ops.end(), [&](const DngOp &op) { return !sane(op); }), ops.end());
    return !ops.empty();
}

// The profile a file's tags describe: DNG opcodes first, then the maker's own. `width` / `height` are the developed
// frame's (either orientation; only their ratio matters to the radial models).
inline Profile buildProfile(const Tags &tags, int width, int height) {
    Profile profile;
    if (!tags.dngOpcodeList3.empty()
        && parseOpcodeList3(tags.dngOpcodeList3.data(), tags.dngOpcodeList3.size(), profile.dng)) {
        profile.source = Profile::Dng;
        return profile;
    }
    const float halfW = 0.5f * float(std::max(1, width)), halfH = 0.5f * float(std::max(1, height));
    const float shortOverDiagonal = std::min(halfW, halfH) / std::hypot(halfW, halfH);
    constexpr int kKnots = 16;

    // Sony: nc knots at (i + 0.5) / (nc - 1); distortion / CA in 2^-14 / 2^-21 steps, vignetting in log2 steps.
    const auto &sd = tags.sonyDistortion, &sc = tags.sonyChromatic, &sv = tags.sonyVignetting;
    if (!sd.empty() && !sc.empty() && !sv.empty() && detail::finite(sd) && detail::finite(sc) && detail::finite(sv)) {
        const int nc = int(sd[0]);
        if (nc >= 2 && nc <= 16 && int(sc[0]) == 2 * nc && int(sv[0]) == nc && int(sd.size()) >= nc + 1
            && int(sc.size()) >= 2 * nc + 1 && int(sv.size()) >= nc + 1) {
            profile.source = Profile::Sony;
            for (int i = 0; i < nc; ++i) {
                const float knot = (float(i) + 0.5f) / float(nc - 1);
                const float d = float(sd[i + 1]) * std::ldexp(1.0f, -14) + 1;
                const float red = float(sc[i + 1]) * std::ldexp(1.0f, -21) + 1, blue = float(sc[nc + i + 1]) * std::ldexp(1.0f, -21) + 1;
                for (Spline &s : profile.distortion) s.x.push_back(knot);
                profile.distortion[0].y.push_back(d * red);
                profile.distortion[1].y.push_back(d);
                profile.distortion[2].y.push_back(d * blue);
                profile.vignette.x.push_back(knot);
                profile.vignette.y.push_back(std::pow(2.0f, 0.5f - std::pow(2.0f, float(sv[i + 1]) * std::ldexp(1.0f, -13) - 1)));
            }
            detail::autoscale(profile.distortion, shortOverDiagonal);
            return profile;
        }
    }

    // Fujifilm: knots and values given against the source radius (distortion in percent, vignetting in percent of
    // the centre's brightness); converted to a destination-radius spline.
    const auto &fd = tags.fujiDistortion, &fc = tags.fujiChromatic, &fv = tags.fujiVignetting;
    if (!fd.empty() && !fc.empty() && !fv.empty() && detail::finite(fd) && detail::finite(fc) && detail::finite(fv)) {
        int nc = 0;
        std::vector<float> knots, dist, red, blue, vig;
        bool ok = true;
        if (fd.size() == 19 && fc.size() == 29 && fv.size() == 19) {          // X-Trans IV / V
            nc = 9;
            for (int i = 0; i < nc && ok; ++i) {
                ok = fd[i + 1] == fc[i + 1] && fd[i + 1] == fv[i + 1];
                knots.push_back(float(fd[i + 1])); dist.push_back(float(fd[i + 10]));
                red.push_back(float(fc[i + 10])); blue.push_back(float(fc[i + 19])); vig.push_back(float(fv[i + 10]));
            }
        } else if (fd.size() == 23 && fc.size() == 31 && fv.size() == 23) {   // X-Trans I / II / III
            nc = 11;
            for (int i = 0; i < nc && ok; ++i) {
                const double chromaticKnot = i == 0 ? 0 : fc[i];               // no first knot in the CA table
                ok = fd[i + 1] == chromaticKnot && fd[i + 1] == fv[i + 1];
                knots.push_back(float(fd[i + 1])); dist.push_back(float(fd[i + 12]));
                red.push_back(i == 0 ? 0.0f : float(fc[i + 10])); blue.push_back(i == 0 ? 0.0f : float(fc[i + 20]));
                vig.push_back(float(fv[i + 12]));
            }
        } else {
            ok = false;
        }
        if (ok && nc > 0) {
            const float crop = tags.fujiCropMode == 2 || tags.fujiCropMode == 4 ? 1.25f : 1.0f;
            Spline sourceDistortion, sourceRed, sourceBlue;
            if (knots[0] > 0) {
                sourceDistortion.x.push_back(0); sourceDistortion.y.push_back(1);
                sourceRed.x.push_back(0); sourceRed.y.push_back(0);
                sourceBlue.x.push_back(0); sourceBlue.y.push_back(0);
                profile.vignette.x.push_back(0); profile.vignette.y.push_back(1);
            }
            for (int i = 0; i < nc; ++i) {
                const float knot = crop * knots[i];
                sourceDistortion.x.push_back(knot); sourceDistortion.y.push_back(dist[i] / 100 + 1);
                sourceRed.x.push_back(knot); sourceRed.y.push_back(red[i]);
                sourceBlue.x.push_back(knot); sourceBlue.y.push_back(blue[i]);
                profile.vignette.x.push_back(knot); profile.vignette.y.push_back(vig[i] / 100);
            }
            for (int i = 0; i < kKnots; ++i) {
                const float source = float(i) / float(kKnots - 1);
                const float m = sourceDistortion(source);
                const float destination = m > 0 ? source / m : source;
                for (Spline &s : profile.distortion) s.x.push_back(destination);
                profile.distortion[0].y.push_back(m * (sourceRed(source) + 1));
                profile.distortion[1].y.push_back(m);
                profile.distortion[2].y.push_back(m * (sourceBlue(source) + 1));
            }
            profile.source = Profile::Fuji;
            detail::autoscale(profile.distortion, shortOverDiagonal);
            return profile;
        }
    }

    // OM System / Olympus: Rin = Rout·s·(1 + k2 (Rout·s)² + k4 (Rout·s)⁴ + k6 (Rout·s)⁶), corner-normalised, and the
    // CA polynomial on the distorted radius.
    const auto &od = tags.olympusDistortion, &oc = tags.olympusChromatic;
    const bool olympusDistortion = od.size() == 4 && detail::finite(od) && (od[0] != 0 || od[1] != 0 || od[2] != 0);
    const bool olympusChromatic = oc.size() == 6 && detail::finite(oc)
        && std::any_of(oc.begin(), oc.end(), [](double v) { return v != 0; });
    if (olympusDistortion || olympusChromatic) {
        const float s = olympusDistortion ? float(od[3]) : 1, k2 = olympusDistortion ? float(od[0]) : 0,
                    k4 = olympusDistortion ? float(od[1]) : 0, k6 = olympusDistortion ? float(od[2]) : 0;
        for (int i = 0; i < kKnots; ++i) {
            const float r = float(i) / float(kKnots - 1);
            const float rs2 = (r * s) * (r * s);
            const float ratio = s * (1 + rs2 * (k2 + rs2 * (k4 + rs2 * k6)));
            float red = ratio, blue = ratio;
            if (olympusChromatic && r > 0) {
                const float rd = ratio * r, rd2 = rd * rd;
                red += rd * (float(oc[0]) + rd2 * (float(oc[1]) + rd2 * float(oc[2]))) / r;
                blue += rd * (float(oc[3]) + rd2 * (float(oc[4]) + rd2 * float(oc[5]))) / r;
            }
            for (Spline &sp : profile.distortion) sp.x.push_back(r);
            profile.distortion[0].y.push_back(red);
            profile.distortion[1].y.push_back(ratio);
            profile.distortion[2].y.push_back(blue);
        }
        profile.source = Profile::Olympus;
        detail::autoscale(profile.distortion, shortOverDiagonal);
        return profile;
    }

    // Panasonic: Ru = Rd + scale·(a Rd³ + b Rd⁵ + c Rd⁷), half-diagonal normalised; inverted by fixed-point iteration.
    const auto &pd = tags.panasonicDistortion;
    if (pd.size() == 16 && (pd[7] & 0x0f) == 1) {
        const float scale = 1.0f / (1.0f + float(pd[5]) / 32768.0f);
        const float a = float(pd[8]) / 32768.0f, b = float(pd[4]) / 32768.0f, c = float(pd[11]) / 32768.0f;
        for (int i = 0; i < kKnots; ++i) {
            const float r = float(i) / float(kKnots - 1);
            float rd = r;
            for (int k = 0; k < 3; ++k) {
                const float rd2 = rd * rd;
                const float f = 1.0f + scale * (a * rd2 + b * rd2 * rd2 + c * rd2 * rd2 * rd2);
                rd = f > 1e-6f ? r / f : r;
            }
            for (Spline &sp : profile.distortion) { sp.x.push_back(r); sp.y.push_back(r > 0 ? rd / r : 1.0f); }
        }
        profile.source = Profile::Panasonic;
        detail::autoscale(profile.distortion, shortOverDiagonal);
        return profile;
    }
    return profile;
}

namespace detail {

// Buffer pixel (continuous, pixel centres at +0.5) <-> sensor pixel, for a buffer of w x h in `o`'s orientation.
struct Frame {
    int w, h, sw, sh;
    bool transpose, mirrorRows, mirrorCols;
    Frame(int width, int height, Orientation o)
        : w(width), h(height), transpose(o.flip & 4), mirrorRows(o.flip & 2), mirrorCols(o.flip & 1) {
        sw = transpose ? h : w; sh = transpose ? w : h;
    }
    void toSensor(double bx, double by, double &sx, double &sy) const {
        double u = bx / w, v = by / h;          // normalised in the buffer
        if (transpose) std::swap(u, v);
        if (mirrorRows) v = 1 - v;
        if (mirrorCols) u = 1 - u;
        sx = u * sw; sy = v * sh;
    }
    void toBuffer(double sx, double sy, double &bx, double &by) const {
        double u = sx / sw, v = sy / sh;
        if (mirrorCols) u = 1 - u;
        if (mirrorRows) v = 1 - v;
        if (transpose) std::swap(u, v);
        bx = u * w; by = v * h;
    }
};

template <typename F>
void parallelRows(int h, F &&rows) {
    const int threads = std::max(1, std::min<int>(h, int(std::thread::hardware_concurrency())));
    if (threads == 1) { rows(0, h); return; }
    std::vector<std::thread> workers;
    for (int t = 0; t < threads; ++t)
        workers.emplace_back([&, t] { rows(int(int64_t(h) * t / threads), int(int64_t(h) * (t + 1) / threads)); });
    for (std::thread &worker : workers) worker.join();
}

// Bilinear sample of one channel at a continuous position (pixel centres at +0.5), clamped to the frame.
template <typename T>
float sample(const std::vector<T> &plane, int w, int h, double x, double y) {
    x = std::clamp(x - 0.5, 0.0, double(w - 1));
    y = std::clamp(y - 0.5, 0.0, double(h - 1));
    const int x0 = int(x), y0 = int(y), x1 = std::min(w - 1, x0 + 1), y1 = std::min(h - 1, y0 + 1);
    const float fx = float(x - x0), fy = float(y - y0);
    const float top = float(plane[size_t(y0) * w + x0]) * (1 - fx) + float(plane[size_t(y0) * w + x1]) * fx;
    const float bottom = float(plane[size_t(y1) * w + x0]) * (1 - fx) + float(plane[size_t(y1) * w + x1]) * fx;
    return top * (1 - fy) + bottom * fy;
}

template <typename T>
T store(float v, float maxValue) {
    v = std::clamp(v, 0.0f, maxValue);
    if constexpr (std::is_integral_v<T>) return T(std::lround(v));
    else return T(v);
}

// Resamples each of the first `channels` channels: output pixel (bx, by) takes channel c from source(c, bx, by).
template <typename T, typename Source>
void warp(T *data, int w, int h, int stride, int channels, float maxValue, Source &&source) {
    std::vector<T> plane(size_t(w) * h);
    for (int c = 0; c < channels; ++c) {
        for (size_t i = 0; i < plane.size(); ++i) plane[i] = data[i * stride + c];
        parallelRows(h, [&](int y0, int y1) {
            for (int y = y0; y < y1; ++y)
                for (int x = 0; x < w; ++x) {
                    double sx, sy;
                    source(c, x + 0.5, y + 0.5, sx, sy);
                    data[(size_t(y) * w + x) * stride + c] = store<T>(sample(plane, w, h, sx, sy), maxValue);
                }
        });
    }
}

}  // namespace detail

// Corrects `data` (w x h pixels, `stride` values per pixel, the first `channels` of them colour, linear light, 0...
// `maxValue`) in place. `orientation` says how the buffer sits relative to the sensor (DNG opcodes are in sensor
// coordinates; the radial maker-note models are symmetric and need no orientation).
template <typename T>
void apply(const Profile &profile, T *data, int w, int h, int stride, int channels, float maxValue,
           Orientation orientation = {}) {
    if (!profile.valid() || !data || w < 2 || h < 2 || channels < 1 || stride < channels) return;
    channels = std::min(channels, 3);
    if (profile.source == Profile::Dng) {
        const detail::Frame frame(w, h, orientation);
        for (const DngOp &op : profile.dng) {
            const double cx = op.cx * frame.sw, cy = op.cy * frame.sh;
            const double mx = std::max(cx, frame.sw - cx), my = std::max(cy, frame.sh - cy);
            const double m = std::hypot(mx, my);
            if (!(m > 0)) continue;
            if (op.kind == DngOp::Vignette) {
                detail::parallelRows(h, [&](int y0, int y1) {
                    for (int y = y0; y < y1; ++y)
                        for (int x = 0; x < w; ++x) {
                            double sx, sy;
                            frame.toSensor(x + 0.5, y + 0.5, sx, sy);
                            const double dx = (sx - cx) / m, dy = (sy - cy) / m, r2 = dx * dx + dy * dy;
                            const double gain = 1 + r2 * (op.k[0] + r2 * (op.k[1] + r2 * (op.k[2] + r2 * (op.k[3] + r2 * op.k[4]))));
                            T *px = data + (size_t(y) * w + x) * stride;
                            for (int c = 0; c < channels; ++c) px[c] = detail::store<T>(float(px[c] * gain), maxValue);
                        }
                });
            } else {
                detail::warp(data, w, h, stride, channels, maxValue, [&](int c, double bx, double by, double &ox, double &oy) {
                    const int p = op.planes == 3 ? c : 0;
                    double sx, sy;
                    frame.toSensor(bx, by, sx, sy);
                    const double dx = (sx - cx) / m, dy = (sy - cy) / m, r2 = dx * dx + dy * dy;
                    const double f = op.kr[p][0] + r2 * (op.kr[p][1] + r2 * (op.kr[p][2] + r2 * op.kr[p][3]));
                    const double tx = op.kt[p][0] * 2 * dx * dy + op.kt[p][1] * (r2 + 2 * dx * dx);
                    const double ty = op.kt[p][1] * 2 * dx * dy + op.kt[p][0] * (r2 + 2 * dy * dy);
                    frame.toBuffer(cx + m * (f * dx + tx), cy + m * (f * dy + ty), ox, oy);
                });
            }
        }
        return;
    }
    const double halfW = 0.5 * w, halfH = 0.5 * h, inverseDiagonal = 1.0 / std::hypot(halfW, halfH);
    if (!profile.vignette.empty()) {
        detail::parallelRows(h, [&](int y0, int y1) {
            for (int y = y0; y < y1; ++y)
                for (int x = 0; x < w; ++x) {
                    const float r = float(std::hypot(x + 0.5 - halfW, y + 0.5 - halfH) * inverseDiagonal);
                    const float divisor = std::max(1e-4f, profile.vignette(r));
                    T *px = data + (size_t(y) * w + x) * stride;
                    for (int c = 0; c < channels; ++c) px[c] = detail::store<T>(float(px[c]) / divisor, maxValue);
                }
        });
    }
    if (!profile.distortion[1].empty()) {
        detail::warp(data, w, h, stride, channels, maxValue, [&](int c, double bx, double by, double &ox, double &oy) {
            const double dx = bx - halfW, dy = by - halfH;
            const float ratio = profile.distortion[channels == 3 ? c : 1](float(std::hypot(dx, dy) * inverseDiagonal));
            ox = halfW + ratio * dx; oy = halfH + ratio * dy;
        });
    }
}

}  // namespace rawlens
