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
/* Operations: 1 source-over, 2 mask blend, 3 color matrix (v0-v3 rows, v4 bias), 4 color clamp (v0 min, v1 max),
 * 5 unpremultiply, 6 maximum component, 7 crop (v0 = x0,y0,x1,y1). `background` and `mask` are read only by 1 and 2. */
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
    }
    return outPixel;
}
