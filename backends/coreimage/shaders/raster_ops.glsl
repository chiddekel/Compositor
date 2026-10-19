// Per-pixel raster operations shared by the single-operation and fused graph shaders, so both compute every value with
// the same arithmetic. Requires GL_ARB_gpu_shader_fp64 (exact division) and warp_precision.glsl's float controls.
float rowValue(vec4 row, vec4 c, float bias) {
    precise float v=row.x*c.x+row.y*c.y+row.z*c.z+row.w*c.w+bias;
    return v;
}
float divide(float numerator, float denominator) { return float(double(numerator)/double(denominator)); }
vec4 straight(vec4 s) {
    return s.a>0?vec4(divide(s.r,s.a),divide(s.g,s.a),divide(s.b,s.a),s.a):vec4(0);
}
uint mix32(uint x) {
    x ^= x >> 16; x *= 0x7feb352du;
    x ^= x >> 15; x *= 0x846ca68bu;
    x ^= x >> 16;
    return x;
}
float unitNoise(uint key) { return float(mix32(key) >> 8) * (1.0 / 16777216.0); }
float latticeNoise(int ix, int iy, uint seed) {
    uint h = mix32(uint(ix) * 0x9E3779B1u ^ mix32(uint(iy) * 0x85EBCA77u ^ seed));
    return float(h & 0xFFFFu) / 65535.0 + float(h >> 16) / 65535.0 - 1.0;
}
float grainField(float u, float v, float scale, uint seed) {
    float cellX = floor(u / scale), cellY = floor(v / scale);
    float tx = u / scale - cellX, ty = v / scale - cellY;
    tx = tx * tx * (3.0 - 2.0 * tx);
    ty = ty * ty * (3.0 - 2.0 * ty);
    int ix = int(cellX), iy = int(cellY);
    float n00 = latticeNoise(ix, iy, seed), n10 = latticeNoise(ix + 1, iy, seed);
    float n01 = latticeNoise(ix, iy + 1, seed), n11 = latticeNoise(ix + 1, iy + 1, seed);
    float top = n00 + (n10 - n00) * tx, bottom = n01 + (n11 - n01) * tx;
    return (top + (bottom - top) * ty) * 1.6;
}
/* Operations: 1 source-over, 2 mask blend, 3 color matrix (v0-v3 rows, v4 bias), 4 color clamp (v0 min, v1 max),
 * 5 unpremultiply, 6 maximum component, 7 crop (v0 = x0,y0,x1,y1), 8 add_noise, 9 add_grain. `background` and `mask`
 * are read only by 1 and 2. */
vec4 rasterOperation(uint operation, uint channel, vec4 source, vec4 background, vec4 mask,
                     vec4 v0, vec4 v1, vec4 v2, vec4 v3, vec4 v4, uvec2 p) {
    precise vec4 s=source;
    precise vec4 outPixel=s;
    if (operation==1) {
        precise float keep=1-s.a;
        outPixel=s+background*keep;
    } else if (operation==2) {
        precise vec4 m=mask;
        if (m.a<=0) outPixel=background;
        else {
            precise float luminance=0.2126*m.r+0.7152*m.g+0.0722*m.b;
            precise float weight=channel==3?m.a:channel==4
                ?divide(luminance,m.a):m.a==1?m.r:divide(m.r,m.a);
            if (weight<=0) outPixel=background;
            else if (weight>=1) outPixel=s;
            else {
                precise float keep=1-weight;
                outPixel=s*weight+background*keep;
            }
        }
    } else if (operation==3) {
        precise vec4 c=straight(s);
        precise float a=rowValue(v3,c,v4.a);
        outPixel=vec4(rowValue(v0,c,v4.r)*a,
            rowValue(v1,c,v4.g)*a,rowValue(v2,c,v4.b)*a,a);
    } else if (operation==4) {
        precise vec4 c=straight(s);
        c=min(v1,max(v0,c));
        outPixel=vec4(c.rgb*c.a,c.a);
    } else if (operation==5) {
        outPixel=vec4(straight(s).rgb,s.a);
    } else if (operation==6) {
        float m=max(s.r,max(s.g,s.b));
        outPixel=vec4(m,m,m,s.a);
    } else if (operation==7) {
        vec4 rect=v0;
        if (float(p.x)<rect.x || float(p.y)<rect.y || float(p.x)>=rect.z || float(p.y)>=rect.w) outPixel=vec4(0);
    } else if (operation==8) {
        if (s.a * 255.0 > 0.0) {
            uint seed = floatBitsToUint(v0.w);
            uint px = uint(floatBitsToInt(v1.x) + int(p.x));
            uint py = uint(floatBitsToInt(v1.y) + int(p.y));
            uint base = mix32(seed ^ mix32(px * 0x9e3779b9u ^ mix32(py * 0x85ebca6bu)));
            float spread = v0.x / 100.0 * 127.5;
            bool gaussian = v0.y != 0.0;
            bool monochromatic = v0.z != 0.0;
            vec3 result;
            for (int c = 0; c < 3; ++c) {
                uint key = monochromatic ? base : base + uint(c) * 0x9e3779b9u;
                float n;
                if (gaussian) {
                    float u1 = unitNoise(key), u2 = unitNoise(key ^ 0x68e31da4u);
                    n = sqrt(-2.0 * log(1.0 - u1)) * cos(6.2831853 * u2) * spread * (2.0 / 3.0);
                } else {
                    n = (unitNoise(key) * 2.0 - 1.0) * spread;
                }
                float value = clamp(s[c] * 255.0 / s.a + n, 0.0, 255.0);
                result[c] = value / 255.0 * s.a;
            }
            outPixel = vec4(result, s.a);
        }
    } else if (operation==9) {
        if (s.a > 0.0) {
            uint seed = floatBitsToUint(v1.w);
            float u = v1.x + (float(floatBitsToInt(v2.x) + int(p.x)) + 0.5) * v1.z;
            float v = v1.y + (float(floatBitsToInt(v2.y) + int(p.y)) + 0.5) * v1.z;
            float smoothGrain = grainField(u, v, v0.z, seed);
            float fineGrain = grainField(u, v, v0.w, mix32(seed ^ 0xA511E9B3u));
            float noise = smoothGrain + (fineGrain - smoothGrain) * v0.y;
            vec3 rgb = s.rgb / s.a * 255.0;
            float level = min(1.0, (0.2126 * rgb.r + 0.7152 * rgb.g + 0.0722 * rgb.b) / 255.0);
            float delta = noise * v0.x * (0.4 + 2.4 * level * (1.0 - level));
            outPixel = vec4(clamp(rgb + delta, 0.0, 255.0) / 255.0 * s.a, s.a);
        }
    }
    return outPixel;
}
