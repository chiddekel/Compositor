// Lens correction from the lensfun database, for RAW files that carry no profile of their own (RawLensProfile.h).
//
// Apple's RAW engine corrects a lens it knows from its own camera/lens database even when the file holds no profile:
// a Canon CR2 or a Nikon NEF gets Lens Correction from the camera and lens named in its EXIF. lensfun (LGPL-3, with a
// CC-BY-SA 3.0 database of measured lenses) plays that part here. Its distortion, transverse chromatic aberration and
// vignetting models are all radial, so they are sampled into the same per-channel radial splines the maker-note
// profiles use and applied by the same resampler: one correction path, whatever the profile's source.
//
// Built only with lensfun (COMPOSITOR_HAS_LENSFUN: the Flatpak's `lensfun` module, or scripts/build-lensfun.sh).

#pragma once
#include "RawLensProfile.h"

#if defined(COMPOSITOR_HAS_LENSFUN)
#include <lensfun/lensfun.h>

#include <cstdlib>
#include <mutex>
#include <string>
#include <sys/stat.h>

namespace rawlens {

// What the file says about how it was taken (EXIF), as LibRaw reports it.
struct Shot {
    std::string cameraMaker, cameraModel, lensMaker, lensModel;
    float focal = 0, aperture = 0;   // mm, f-number (0 when unknown)
};

namespace detail {

inline bool isDirectory(const std::string &path) {
    struct stat info {};
    return !path.empty() && stat(path.c_str(), &info) == 0 && S_ISDIR(info.st_mode);
}

// COMPOSITOR_LENSFUN_DB, the Flatpak's copy, or the dev loop's build (scripts/build-lensfun.sh).
inline std::string lensfunDatabaseDirectory() {
    if (const char *chosen = std::getenv("COMPOSITOR_LENSFUN_DB"); chosen && isDirectory(chosen)) return chosen;
    if (isDirectory("/app/share/lensfun/version_1")) return "/app/share/lensfun/version_1";
    std::string here = __FILE__;
    here = here.substr(0, here.find_last_of('/'));
    const std::string checkout = here + "/../build/lensfun/install/share/lensfun/version_1";
    return isDirectory(checkout) ? checkout : std::string();
}

}  // namespace detail

// The database, loaded once (about 1,000 lenses; a few milliseconds). Null when there is none.
inline const lfDatabase *lensfunDatabase() {
    static std::once_flag once;
    static lfDatabase *database = nullptr;
    std::call_once(once, [] {
        const std::string directory = detail::lensfunDatabaseDirectory();
        if (directory.empty()) return;
        auto *loaded = new lfDatabase();
        if (loaded->LoadDirectory(directory.c_str())) database = loaded;
        else delete loaded;
    });
    return database;
}

// The camera and lens lensfun knows for `shot`, best match first; false when either is unknown. Lenses are matched
// against the camera's mount (so an EF lens isn't taken for an RF one of the same name).
inline bool lensfunLookup(const lfDatabase *database, const Shot &shot, const lfCamera *&camera, const lfLens *&lens) {
    camera = nullptr; lens = nullptr;
    if (!database || shot.cameraModel.empty() || shot.lensModel.empty() || !(shot.focal > 0)) return false;
    if (const lfCamera **cameras = database->FindCamerasExt(shot.cameraMaker.c_str(), shot.cameraModel.c_str())) {
        camera = cameras[0];
        lf_free(cameras);
    }
    if (!camera) return false;
    const char *maker = shot.lensMaker.empty() ? nullptr : shot.lensMaker.c_str();
    if (const lfLens **lenses = database->FindLenses(camera, maker, shot.lensModel.c_str())) {
        lens = lenses[0];
        lf_free(lenses);
    }
    return lens != nullptr;
}

// Samples lensfun's correction for `width` × `height` along the half diagonal into a radial profile: per channel, the
// source radius over the destination radius (the radius normalised to the half diagonal, as the maker-note profiles
// use), and the vignetting the source is divided by. Scaled, like the others, so no empty border shows. An invalid
// profile when lensfun doesn't know the camera and lens, or has no calibration that changes anything for this shot.
inline Profile lensfunProfile(const Shot &shot, int width, int height, const lfDatabase *database = lensfunDatabase()) {
    Profile profile;
    const lfCamera *camera = nullptr;
    const lfLens *lens = nullptr;
    if (width < 8 || height < 8 || !lensfunLookup(database, shot, camera, lens)) return profile;
    lfModifier modifier(lens, camera->CropFactor, width, height);
    const float aperture = shot.aperture > 0 ? shot.aperture : 8.0f;
    const int applied = modifier.Initialize(lens, LF_PF_F32, shot.focal, aperture, 1000.0f, 1.0f, LF_RECTILINEAR,
                                            LF_MODIFY_DISTORTION | LF_MODIFY_TCA | LF_MODIFY_VIGNETTING, false);
    if (!(applied & (LF_MODIFY_DISTORTION | LF_MODIFY_TCA | LF_MODIFY_VIGNETTING))) return profile;

    const float cx = 0.5f * float(width - 1), cy = 0.5f * float(height - 1);
    const float halfW = 0.5f * float(width), halfH = 0.5f * float(height);
    const float diagonal = std::hypot(halfW, halfH);
    constexpr int kKnots = 33;
    bool changes = false;
    for (int i = 0; i < kKnots; ++i) {
        // Toward the corner; the first knot sits just off the centre, where every ratio is its limit.
        const float r = std::max(1.0f / 512.0f, float(i) / float(kKnots - 1));
        const float x = cx + r * halfW, y = cy + r * halfH;
        alignas(16) float source[6] = {x, y, x, y, x, y};
        if (applied & (LF_MODIFY_DISTORTION | LF_MODIFY_TCA)) modifier.ApplySubpixelGeometryDistortion(x, y, 1, 1, source);
        for (int c = 0; c < 3; ++c) {
            const float ratio = std::hypot(source[2 * c] - cx, source[2 * c + 1] - cy) / (r * diagonal);
            if (!std::isfinite(ratio) || ratio <= 0) return Profile();
            profile.distortion[c].x.push_back(r);
            profile.distortion[c].y.push_back(ratio);
            changes = changes || std::abs(ratio - 1) > 1e-5f;
        }
        float pixel[3] = {0.25f, 0.25f, 0.25f};
        if (applied & LF_MODIFY_VIGNETTING)
            modifier.ApplyColorModification(pixel, x, y, 1, 1, LF_CR_3(RED, GREEN, BLUE), int(sizeof pixel));
        const float gain = pixel[1] / 0.25f;
        if (!std::isfinite(gain) || gain <= 0) return Profile();
        profile.vignette.x.push_back(r);
        profile.vignette.y.push_back(1.0f / gain);
        changes = changes || std::abs(gain - 1) > 1e-5f;
    }
    if (!changes) return Profile();
    profile.source = Profile::Lensfun;
    detail::autoscale(profile.distortion, std::min(halfW, halfH) / diagonal);
    return profile;
}

}  // namespace rawlens
#endif
