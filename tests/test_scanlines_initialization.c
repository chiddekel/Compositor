#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "DitherPixels.h"

void *__real_malloc(size_t size);

// Unwritten float scratch storage must not affect the screen between beams.
void *__wrap_malloc(size_t size) {
    void *memory = __real_malloc(size);
    if (memory) {
        memset(memory, 0, size);
        const float poison = NAN;
        for (size_t offset = 0; offset + sizeof(poison) <= size; offset += sizeof(poison))
            memcpy((uint8_t *)memory + offset, &poison, sizeof(poison));
    }
    return memory;
}

int main(void) {
    uint8_t pixels[16 * 32 * 4];
    for (size_t i = 0; i < sizeof(pixels); i += 4) {
        pixels[i] = pixels[i + 1] = pixels[i + 2] = 0;
        pixels[i + 3] = 255;
    }
    ScanlinesParams parameters = {0};
    parameters.spacing = 8;
    parameters.thickness = 0.7f;
    parameters.smoothness = 0.5f;
    parameters.dark[1] = 255;
    parameters.light[0] = parameters.light[1] = parameters.light[2] = 255;
    if (!scanlines_apply(pixels, 16, 32, 16 * 4, &parameters)) return 2;
    for (size_t i = 0; i < sizeof(pixels); i += 4) {
        if (pixels[i] || pixels[i + 1] != 255 || pixels[i + 2] || pixels[i + 3] != 255) {
            fprintf(stderr, "Scanlines unlit screen differs at pixel %zu: %u/%u/%u/%u\n",
                    i / 4, pixels[i], pixels[i + 1], pixels[i + 2], pixels[i + 3]);
            return 1;
        }
    }
    puts("Scanlines scratch initialization OK: all 512 unlit green-screen pixels exact with NaN-poisoned malloc");
    return 0;
}
