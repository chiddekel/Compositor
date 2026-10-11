extern "C" {
#include "PatchPixels.h"
}
#include <vector>
#include <algorithm>
#include <cstdio>
#include <cstring>
#include <sys/wait.h>
#include <unistd.h>
#include <signal.h>
extern "C" int compositor_test_patch_alloc_failure(int);
int main() {
    const int side = 48;
    std::vector<uint8_t> original(side * side * 4), mask(side * side, 0);
    for (int y = 0; y < side; ++y) for (int x = 0; x < side; ++x) {
        const int p = (y * side + x) * 4;
        original[p] = uint8_t((x / 3) % 2 ? 200 : 20);
        original[p + 1] = uint8_t((y / 3) % 2 ? 180 : 30); original[p + 2] = 90; original[p + 3] = 255;
        if (x >= 16 && x < 32 && y >= 16 && y < 32) {
            mask[y * side + x] = 255; original[p] = 240; original[p + 1] = 10; original[p + 2] = 10;
        }
    }
    auto left = original, right = original;
    if (patch_fill(left.data(), side * 4, mask.data(), side, side, side, 17) != 1 ||
        patch_fill(right.data(), side * 4, mask.data(), side, side, side, 17) != 1 || left != right) return 1;
    bool changed = false;
    for (int p = 0; p < side * side; ++p) {
        bool differs = std::memcmp(left.data() + p * 4, original.data() + p * 4, 4) != 0;
        if (!mask[p] && differs) return 2;
        changed = changed || differs;
    }
    if (!changed) return 3;
    std::fill(mask.begin(), mask.end(), 255);
    left = original;
    if (patch_fill(left.data(), side * 4, mask.data(), side, side, side, 17) != 0 || left != original) return 4;
    for (int allocation = 0; allocation < 10; ++allocation)
        if (!compositor_test_patch_alloc_failure(allocation)) return 5;
    for (bool maskStride : {false, true}) {
        pid_t child = fork();
        if (child < 0) return 6;
        if (child == 0) {
            patch_fill(original.data(), side * 4 + (maskStride ? 0 : 4), mask.data(), side + (maskStride ? 1 : 0), side, side, 17);
            _exit(0);
        }
        int status = 0;
        if (waitpid(child, &status, 0) != child || !WIFSIGNALED(status) || WTERMSIG(status) != SIGABRT) return 7;
    }
    std::puts("PatchMatch native OK (seed determinism, outside-hole bytes, no-source refusal, allocation faults, stride guards)");
    return 0;
}
