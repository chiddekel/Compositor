#include "include/Dispersion.h"
#include <algorithm>
#include <cmath>

namespace {
float smooth(float a, float b, float x) {
    x=std::clamp((x-a)/(b-a),0.0f,1.0f); return x*x*(3-2*x);
}
}
extern "C" int compositor_dispersion_render(CompositorVulkanRaster *gpu, unsigned width, unsigned height,
    const float *source, const float *p, float *output) {
    if (!width || !height || width>65536 || height>65536 || !source || !p || !output) return -1;
    for (int i=0;i<20;++i) if (!std::isfinite(p[i])) return -1;
    if (p[16]<1 || p[17]<1 || p[16]>65536 || p[17]>65536 ||
        p[16]!=std::floor(p[16]) || p[17]!=std::floor(p[17]) || std::abs(p[15])!=1 ||
        p[9]<1 || p[9]>4096 || p[10]<1 || p[10]>4096 || p[8]<0 || p[8]>15) return -1;
    if (gpu && compositor_vulkan_raster_render(gpu,width,height,10,0,source,nullptr,nullptr,p,output)==0) return 1;
    const int sw=int(p[16]), sh=int(p[17]), sides=int(p[8]);
    const unsigned n=unsigned(p[9]), m=unsigned(p[10]);
    auto tap=[&](float qx,float qy,int channel) {
        float x=qx-p[13], y=p[15]*(qy-p[14]);
        if ((x<0 && !(sides&1)) || (x>sw && !(sides&2)) ||
            (y<0 && !(sides&4)) || (y>sh && !(sides&8))) return 0.0f;
        x=std::clamp(x-0.5f,0.0f,float(sw-1)); y=std::clamp(y-0.5f,0.0f,float(sh-1));
        int x0=int(std::floor(x)), y0=int(std::floor(y));
        int x1=std::min(x0+1,sw-1), y1=std::min(y0+1,sh-1);
        float tx=x-x0, ty=y-y0;
        auto sample=[&](int xx,int yy) { return source[(size_t(yy)*sw+xx)*4+channel]; };
        return (sample(x0,y0)*(1-tx)+sample(x1,y0)*tx)*(1-ty)
             + (sample(x0,y1)*(1-tx)+sample(x1,y1)*tx)*ty;
    };
    for (unsigned y=0;y<height;++y) for (unsigned x=0;x<width;++x) {
        float ax=p[11]+float(x)+0.5f, ay=p[12]+p[15]*(float(y)+0.5f);
        float dx=p[7] ? (ax-p[0])/std::max(p[6],1.0f) : p[2];
        float dy=p[7] ? (ay-p[1])/std::max(p[6],1.0f) : p[3];
        float noise=std::sin(float(x)*12.9898f+float(y)*78.233f)*43758.5453f;
        float jitter=noise-std::floor(noise), color[3]{}, alpha[3]{}, total[3]{};
        for (unsigned i=0;i<n;++i) {
            float t=n==1 ? 0 : (float(i)+jitter)/float(n)*2-1;
            float weight[3]{smooth(-0.3f,1,t),1-smooth(0,1,std::abs(t))+0.05f,smooth(-0.3f,1,-t)};
            for (unsigned j=0;j<m;++j) {
                float u=m==1 ? 0 : (float(j)+jitter)/float(m);
                float qx=ax-dx*(p[4]*t+p[5]*u), qy=ay-dy*(p[4]*t+p[5]*u);
                float a=tap(qx,qy,3);
                for (int c=0;c<3;++c) {
                    color[c]+=weight[c]*tap(qx,qy,c); alpha[c]+=weight[c]*a; total[c]+=weight[c];
                }
            }
        }
        float a=std::max({alpha[0]/total[0],alpha[1]/total[1],alpha[2]/total[2]});
        size_t at=(size_t(y)*width+x)*4;
        for (int c=0;c<3;++c) output[at+c]=std::min(color[c]/total[c],a);
        output[at+3]=a;
    }
    return 0;
}
