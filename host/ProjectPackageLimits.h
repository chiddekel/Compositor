#pragma once
#include <cstddef>
#include <cstdint>

extern "C" {
size_t compositor_project_max_surface_pixels();
size_t compositor_project_pixel_budget();
int64_t compositor_project_account_asset(size_t width, size_t height, size_t used);
}

namespace compositor {
// Encoded file limits match ProjectStore; these are not decoded raster limits.
constexpr int64_t projectMetadataBytes = 4LL * 1024 * 1024;
constexpr int64_t projectEncodedAssetBytes = 512LL * 1024 * 1024;

inline bool accountProjectAsset(size_t width, size_t height, size_t &used) {
    const int64_t total = compositor_project_account_asset(width, height, used);
    if (total < 0) return false;
    used = static_cast<size_t>(total);
    return true;
}
}
