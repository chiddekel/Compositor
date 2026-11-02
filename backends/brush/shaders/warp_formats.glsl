// Native working-copy formats: RGBA8, unsigned RGBA16, IEEE half RGBA.
vec4 decodeColor(uint a,uint b,uint format) {
    if (format==0) return vec4(a&255u,(a>>8)&255u,(a>>16)&255u,a>>24);
    if (format==1) return vec4(a&65535u,a>>16,b&65535u,b>>16);
    return vec4(unpackHalf2x16(a),unpackHalf2x16(b));
}
uint roundedChannel(float value,float maximum) {
    float clipped=clamp(value,0,maximum), integral=floor(clipped);
    // Adding 0.5 can round a value just below a tie up to the next integer.
    return uint(integral)+uint(clipped-integral>=0.5);
}
uint halfBits(float value) {
    uint bits=floatBitsToUint(value), sign=(bits>>16)&32768u;
    uint mantissa=bits&8388607u, exponent=(bits>>23)&255u;
    if (exponent==255u) return sign|31744u|(mantissa==0u?0u:((mantissa>>13)|512u));
    int e=int(exponent)-112;
    if (e>=31) return sign|31744u;
    if (e < -10) return sign;
    uint shift=13u;
    if (e<=0) { mantissa|=8388608u; shift=uint(14-e); }
    uint result=mantissa>>shift, remainder=mantissa&((1u<<shift)-1u), tie=1u<<(shift-1u);
    if (remainder>tie || (remainder==tie && (result&1u)!=0u)) ++result;
    // Explicit nearest-even conversion, independent of native packHalf rounding modes.
    return sign|(e<=0?result:((uint(e)<<10)+result));
}
uvec2 encodeColor(vec4 value,uint format) {
    if (format==0) {
        uvec4 v=uvec4(roundedChannel(value.x,255),roundedChannel(value.y,255),
                      roundedChannel(value.z,255),roundedChannel(value.w,255));
        return uvec2(v.x|(v.y<<8)|(v.z<<16)|(v.w<<24),0);
    }
    uvec4 v;
    if (format==1) v=uvec4(roundedChannel(value.x,65535),roundedChannel(value.y,65535),
                          roundedChannel(value.z,65535),roundedChannel(value.w,65535));
    else v=uvec4(halfBits(value.x),halfBits(value.y),halfBits(value.z),halfBits(value.w));
    return uvec2(v.x|(v.y<<16),v.z|(v.w<<16));
}
