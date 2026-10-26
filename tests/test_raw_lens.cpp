// RAW lens correction from the file's own profile (host/RawLensProfile.h): DNG OpcodeList3 parsing and its sensor-
// space geometry, the maker-note models (Sony, Fujifilm, OM System / Olympus, Panasonic), plus DNG white points.
#include "../host/RawLensProfile.h"
#include "../host/RawWhitePoint.h"

#include <cstdio>
#include <cstdlib>
#include <limits>
#include <vector>

namespace {

int failures = 0;
void check(bool ok, const char *what) {
    if (!ok) { std::fprintf(stderr, "FAIL: %s\n", what); ++failures; }
}

struct Writer {
    std::vector<uint8_t> bytes;
    void u32(uint32_t v) { for (int i = 3; i >= 0; --i) bytes.push_back(uint8_t(v >> (8 * i))); }
    void f64(double v) { uint64_t b; std::memcpy(&b, &v, 8); for (int i = 7; i >= 0; --i) bytes.push_back(uint8_t(b >> (8 * i))); }
};

std::vector<uint8_t> opcodeList(const std::vector<std::vector<uint8_t>> &ops) {
    Writer w;
    w.u32(uint32_t(ops.size()));
    for (const auto &op : ops) w.bytes.insert(w.bytes.end(), op.begin(), op.end());
    return w.bytes;
}

std::vector<uint8_t> warpOp(const std::vector<std::array<double, 6>> &planes, double cx, double cy) {
    Writer params;
    params.u32(uint32_t(planes.size()));
    for (const auto &p : planes) for (double v : p) params.f64(v);
    params.f64(cx); params.f64(cy);
    Writer op;
    op.u32(1); op.u32(0x01030000); op.u32(0); op.u32(uint32_t(params.bytes.size()));
    op.bytes.insert(op.bytes.end(), params.bytes.begin(), params.bytes.end());
    return op.bytes;
}

std::vector<uint8_t> vignetteOp(std::array<double, 5> k, double cx, double cy) {
    Writer params;
    for (double v : k) params.f64(v);
    params.f64(cx); params.f64(cy);
    Writer op;
    op.u32(3); op.u32(0x01030000); op.u32(0); op.u32(uint32_t(params.bytes.size()));
    op.bytes.insert(op.bytes.end(), params.bytes.begin(), params.bytes.end());
    return op.bytes;
}

std::vector<uint8_t> unknownOp() {
    Writer op;
    op.u32(9); op.u32(0x01030000); op.u32(1); op.u32(8); op.f64(0);
    return op.bytes;
}

rawlens::Profile dngProfile(const std::vector<uint8_t> &list, int w, int h) {
    rawlens::Tags tags;
    tags.dngOpcodeList3 = list;
    return rawlens::buildProfile(tags, w, h);
}

// A test card: a distinct value per pixel, so any geometric change shows.
std::vector<float> card(int w, int h, int stride) {
    std::vector<float> image(size_t(w) * h * stride, 0.0f);
    for (int y = 0; y < h; ++y)
        for (int x = 0; x < w; ++x)
            for (int c = 0; c < stride; ++c) image[(size_t(y) * w + x) * stride + c] = float(x * 7 + y * 13 + c);
    return image;
}

void dngParsing() {
    std::vector<rawlens::DngOp> ops;
    const auto list = opcodeList({vignetteOp({0.5, 0, 0, 0, 0}, 0.5, 0.5), unknownOp(), warpOp({{1, 0.02, 0, 0, 0, 0}}, 0.4, 0.6)});
    check(rawlens::parseOpcodeList3(list.data(), list.size(), ops), "DNG list parses");
    check(ops.size() == 2 && ops[0].kind == rawlens::DngOp::Vignette && ops[1].kind == rawlens::DngOp::Warp,
          "DNG keeps vignette then warp, skips the unknown opcode, in list order");
    check(ops.size() == 2 && ops[0].k[0] == 0.5 && ops[1].kr[0][1] == 0.02 && ops[1].cx == 0.4 && ops[1].cy == 0.6,
          "DNG parameters are read big-endian");
    auto truncated = list;
    truncated.resize(truncated.size() - 9);
    check(!rawlens::parseOpcodeList3(truncated.data(), truncated.size(), ops), "a truncated list is refused");
    const auto onlyUnknown = opcodeList({unknownOp()});
    check(!rawlens::parseOpcodeList3(onlyUnknown.data(), onlyUnknown.size(), ops), "a list without lens opcodes is no profile");
    const auto badPlanes = opcodeList({warpOp({{1, 0, 0, 0, 0, 0}, {1, 0, 0, 0, 0, 0}}, 0.5, 0.5)});
    check(!rawlens::parseOpcodeList3(badPlanes.data(), badPlanes.size(), ops), "a warp with 2 planes is refused");
    const auto nonFinite = opcodeList({vignetteOp({NAN, 0, 0, 0, 0}, 0.5, 0.5)});
    check(!rawlens::parseOpcodeList3(nonFinite.data(), nonFinite.size(), ops), "non-finite coefficients are refused");
    check(!dngProfile({}, 10, 10).valid(), "no tags, no profile");
}

void dngVignette() {
    const int w = 40, h = 30;
    const auto profile = dngProfile(opcodeList({vignetteOp({1, 0, 0, 0, 0}, 0.5, 0.5)}), w, h);
    check(profile.source == rawlens::Profile::Dng, "vignette list gives a DNG profile");
    std::vector<float> image(size_t(w) * h * 3, 100.0f);
    rawlens::apply(profile, image.data(), w, h, 3, 3, 1e9f);
    const float centre = image[(size_t(h / 2) * w + w / 2) * 3], corner = image[0];
    // gain = 1 + k0 r^2, r = 1 at the corner of the frame
    check(centre > 99.0f && centre < 101.5f, "centre keeps its brightness");
    check(corner > 190.0f && corner < 200.5f, "corner is brightened by 1 + k0 r^2");
}

void dngWarpIdentityAndOrientation() {
    const int w = 24, h = 16;
    const auto identity = dngProfile(opcodeList({warpOp({{1, 0, 0, 0, 0, 0}}, 0.5, 0.5)}), w, h);
    auto image = card(w, h, 3);
    const auto before = image;
    rawlens::apply(identity, image.data(), w, h, 3, 3, 1e9f);
    float worst = 0;
    for (size_t i = 0; i < image.size(); ++i) worst = std::max(worst, std::abs(image[i] - before[i]));
    check(worst < 1e-3f, "identity warp leaves the image unchanged");

    // An off-centre warp with tangential terms is defined in sensor coordinates: correcting a transposed buffer
    // (LibRaw flip 4) must give the transpose of correcting the sensor-oriented one.
    const auto list = opcodeList({warpOp({{1, 0.08, -0.02, 0, 0.01, -0.015}}, 0.35, 0.6)});
    const auto profile = dngProfile(list, w, h);
    auto sensor = card(w, h, 1);
    std::vector<float> turned(sensor.size());
    for (int y = 0; y < h; ++y) for (int x = 0; x < w; ++x) turned[size_t(x) * h + y] = sensor[size_t(y) * w + x];
    rawlens::apply(profile, sensor.data(), w, h, 1, 1, 1e9f);
    rawlens::apply(profile, turned.data(), h, w, 1, 1, 1e9f, rawlens::Orientation{4});
    worst = 0;
    for (int y = 0; y < h; ++y) for (int x = 0; x < w; ++x)
        worst = std::max(worst, std::abs(turned[size_t(x) * h + y] - sensor[size_t(y) * w + x]));
    check(worst < 1e-2f, "warp follows the sensor through a transposed buffer");
    // ... and through mirrored rows and columns (flip 3 = rotated 180 degrees)
    auto upright = card(w, h, 1);
    std::vector<float> rotated(upright.rbegin(), upright.rend());
    rawlens::apply(profile, upright.data(), w, h, 1, 1, 1e9f);
    rawlens::apply(profile, rotated.data(), w, h, 1, 1, 1e9f, rawlens::Orientation{3});
    worst = 0;
    for (size_t i = 0; i < upright.size(); ++i) worst = std::max(worst, std::abs(rotated[upright.size() - 1 - i] - upright[i]));
    check(worst < 1e-2f, "warp follows the sensor through a 180-degree buffer");
    check(std::abs(upright[size_t(h / 2) * w + 2] - card(w, h, 1)[size_t(h / 2) * w + 2]) > 0.5f, "a real warp moves pixels");
}

void stridesAndChannels() {
    const int w = 16, h = 12;
    const auto profile = dngProfile(opcodeList({vignetteOp({1, 0, 0, 0, 0}, 0.5, 0.5)}), w, h);
    std::vector<uint16_t> image(size_t(w) * h * 4, 40000);
    rawlens::apply(profile, image.data(), w, h, 4, 3, 65535.0f);
    check(image[0] == 65535 && image[3] == 40000, "16-bit: clipped at white, the fourth value untouched");
}

void sony() {
    rawlens::Tags tags;
    const int nc = 16;
    tags.sonyDistortion.assign(nc + 1, 0); tags.sonyDistortion[0] = nc;
    tags.sonyChromatic.assign(2 * nc + 1, 0); tags.sonyChromatic[0] = 2 * nc;
    tags.sonyVignetting.assign(nc + 1, 0); tags.sonyVignetting[0] = nc;
    auto profile = rawlens::buildProfile(tags, 60, 40);
    check(profile.source == rawlens::Profile::Sony, "Sony tags give a Sony profile");
    check(std::abs(profile.vignette(0.9f) - 1.0f) < 1e-6f && std::abs(profile.distortion[1](0.7f) - 1.0f) < 1e-6f,
          "zero Sony coefficients mean no correction");
    for (int i = 1; i <= nc; ++i) tags.sonyVignetting[i] = 8192.0 * (i - 1) / (nc - 1);   // darker towards the edge
    for (int i = 1; i <= nc; ++i) tags.sonyDistortion[i] = 400.0 * (i - 1) / (nc - 1);    // pincushion stretch
    profile = rawlens::buildProfile(tags, 60, 40);
    std::vector<float> flat(60 * 40 * 3, 100.0f);
    rawlens::apply(profile, flat.data(), 60, 40, 3, 3, 1e9f);
    check(flat[0] > flat[(20 * 60 + 30) * 3] + 10, "Sony vignetting brightens the corners");
    tags.sonyChromatic[0] = 2 * nc - 2;
    check(!rawlens::buildProfile(tags, 60, 40).valid(), "Sony counts that disagree are refused");
}

void fuji() {
    rawlens::Tags tags;
    // X-Trans IV layout: [count, 9 knots, 9 values] / [count, 9 knots, 9 red, 9 blue] / [count, 9 knots, 9 values]
    const double knots[9] = {0, 0.125, 0.25, 0.375, 0.5, 0.625, 0.75, 0.875, 1};
    tags.fujiDistortion = {9}; tags.fujiChromatic = {9}; tags.fujiVignetting = {9};
    for (double k : knots) { tags.fujiDistortion.push_back(k); tags.fujiChromatic.push_back(k); tags.fujiVignetting.push_back(k); }
    for (int i = 0; i < 9; ++i) { tags.fujiDistortion.push_back(-1.5 * knots[i]); tags.fujiVignetting.push_back(100 - 30 * knots[i]); }
    for (int i = 0; i < 19; ++i) tags.fujiChromatic.push_back(0);   // 9 red, 9 blue and a trailing value
    auto profile = rawlens::buildProfile(tags, 60, 40);
    check(profile.source == rawlens::Profile::Fuji, "Fujifilm tags give a Fujifilm profile");
    check(std::abs(profile.vignette(1.0f) - 0.7f) < 1e-5f, "Fujifilm vignetting is percent of the centre");
    std::vector<float> flat(60 * 40 * 3, 100.0f);
    rawlens::apply(profile, flat.data(), 60, 40, 3, 3, 1e9f);
    check(flat[0] > 120.0f, "Fujifilm vignetting brightens the corners");
    tags.fujiVignetting[3] = 0.3;   // a knot that differs from the distortion table
    check(!rawlens::buildProfile(tags, 60, 40).valid(), "Fujifilm tables with different knots are refused");
    tags.fujiVignetting.pop_back();
    check(!rawlens::buildProfile(tags, 60, 40).valid(), "Fujifilm tables of unknown length are refused");
}

void olympusAndPanasonic() {
    rawlens::Tags tags;
    tags.olympusDistortion = {0, 0, 0, 1};
    check(!rawlens::buildProfile(tags, 60, 40).valid(), "Olympus '0 0 0 1' is no correction");
    tags.olympusDistortion = {-0.05, 0.01, 0, 0.98};
    auto profile = rawlens::buildProfile(tags, 60, 40);
    check(profile.source == rawlens::Profile::Olympus, "Olympus distortion gives a profile");
    // After autoscale the frame's edge maps inside the source: no sample comes from outside the image.
    check(profile.distortion[1](1.0f) <= 1.0f + 1e-5f, "Olympus correction is scaled to fill the frame");

    rawlens::Tags pana;
    pana.panasonicDistortion.assign(16, 0);
    pana.panasonicDistortion[8] = 1200; pana.panasonicDistortion[12] = 2500;
    check(!rawlens::buildProfile(pana, 60, 40).valid(), "Panasonic correction flag off: no profile");
    pana.panasonicDistortion[7] = 1;
    profile = rawlens::buildProfile(pana, 60, 40);
    check(profile.source == rawlens::Profile::Panasonic, "Panasonic DistortionInfo gives a profile");
    check(profile.vignette.empty() && !profile.distortion[1].empty(), "Panasonic corrects distortion only");
    auto image = card(60, 40, 3);
    const auto before = image;
    rawlens::apply(profile, image.data(), 60, 40, 3, 3, 1e9f);
    check(image != before, "Panasonic distortion moves pixels");
}

void dngOutranksMaker() {
    rawlens::Tags tags;
    tags.dngOpcodeList3 = opcodeList({vignetteOp({0.2, 0, 0, 0, 0}, 0.5, 0.5)});
    tags.olympusDistortion = {-0.05, 0.01, 0, 0.98};
    check(rawlens::buildProfile(tags, 60, 40).source == rawlens::Profile::Dng, "a DNG's opcodes win over maker notes");
}

void dngNeutralWhitePoint() {
    const double identity[3][3] = {{1,0,0}, {0,1,0}, {0,0,1}}, equalEnergy[3] = {1,1,1};
    const auto white = rawwhite::fromCamera(identity, equalEnergy);
    // Independent native CIRAWFilter defaults from all six identity-calibrated DNG controls.
    check(white && std::abs(white->temperature - 5454.008789) < 0.1, "DNG equal-energy native temperature");
    check(white && std::abs(white->tint + 12.993514) < 0.001, "DNG equal-energy native tint");
    const double daylight[3] = {0.95047,1,1.08883};
    const auto d65 = rawwhite::fromCamera(identity, daylight);
    check(d65 && d65->temperature > 6400 && d65->temperature < 6600, "D65 is approximately 6504 K");
    const double mixed[3][3] = {{1,0.1,0}, {0.2,1,0.1}, {0,0.1,0.7}}, cameraNeutral[3] = {1.1,1.3,0.8};
    const auto calibrated = rawwhite::fromCamera(mixed, cameraNeutral);
    check(white && calibrated && std::abs(white->temperature - calibrated->temperature) < 1e-8
        && std::abs(white->tint - calibrated->tint) < 1e-8, "camera calibration preserves the solved white point");
    const double swapped[3][3] = {{0,1,0}, {1,0,0}, {0,0,1}};
    const auto pivoted = rawwhite::fromCamera(swapped, equalEnergy);
    check(white && pivoted && std::abs(white->temperature - pivoted->temperature) < 1e-8, "white point solver pivots rows");
    for (double scale : {1e-8, 1e8}) {
        double scaled[3][3] = {{scale,0,0}, {0,scale,0}, {0,0,scale}};
        const auto result = rawwhite::fromCamera(scaled, equalEnergy);
        check(white && result && std::abs(white->temperature - result->temperature) < 1e-8, "profile normalization does not change chromaticity");
    }
    const double singular[3][3] = {{1,0,0}, {1,0,0}, {0,0,1}};
    check(!rawwhite::fromCamera(singular, equalEnergy), "singular profile retains fallback");
    const double negativeZ[3][3] = {{1,0,0}, {0,1,0}, {0,0,-1}};
    check(!rawwhite::fromCamera(negativeZ, equalEnergy), "nonphysical white point retains fallback");
    const double invalid[3] = {1,std::numeric_limits<double>::quiet_NaN(),1};
    check(!rawwhite::fromCamera(identity, invalid), "nonfinite neutral retains fallback");
    const double zero[3] = {1,0,1};
    check(!rawwhite::fromCamera(identity, zero), "zero neutral retains fallback");
}

}  // namespace

int main() {
    dngParsing();
    dngVignette();
    dngWarpIdentityAndOrientation();
    stridesAndChannels();
    sony();
    fuji();
    olympusAndPanasonic();
    dngOutranksMaker();
    dngNeutralWhitePoint();
    if (failures) { std::fprintf(stderr, "%d RAW lens/white-point check(s) failed\n", failures); return 1; }
    std::puts("RAW lens profiles and calibrated white points OK (DNG opcodes, Sony, Fujifilm, OM System, Panasonic)");
    return 0;
}
