
#include <metal_stdlib>
using namespace metal;

// ===== Uniforms =====
struct MandelbrotUniforms {
    float2 origin;   // normal origin
    float2 step;     // normal step (units per pixel)
    int    maxIt;    // iterations
    uint2  size;     // output size in pixels
    int    pixelStep;// block size for progressive rendering
    int    palette;  // 0=HSV, 1=Fire, 2=Ocean
    int    deepMode; // 0=off, 1=on
    float2 originHi; // deep zoom hi components (re, im)
    float2 originLo; // deep zoom lo components (re, im)
    float2 stepHi;   // deep zoom step hi (dx, dy)
    float2 stepLo;   // deep zoom step lo (dx, dy)
};

// ===== Helpers =====
inline float smooth_iter(int it, float zr2_plus_zi2, int maxIt) {
    if (it >= maxIt) return 0.0f;
    float v = max(zr2_plus_zi2, 1e-16f);
    float nu = (float)it + 1.0f - log2(0.5f * log(v));
    return clamp(nu / (float)maxIt, 0.0f, 1.0f);
}

// Double-single minimal helpers
struct DS { float hi; float lo; };
inline DS ds_add(DS a, DS b) {
    float s = a.hi + b.hi;
    float v = s - a.hi;
    float t = ((b.hi - v) + (a.hi - (s - v))) + a.lo + b.lo;
    float hi = s + t;
    float lo = t - (hi - s);
    return (DS){hi, lo};
}
inline DS ds_mul_f(DS a, float b) {
    float hi = a.hi * b;
    float lo = a.lo * b + fma(a.hi, b, -hi);
    float rhi = hi + lo;
    float rlo = lo - (rhi - hi);
    return (DS){rhi, rlo};
}
inline float ds_to_float(DS a) { return a.hi + a.lo; }

// Palettes
inline float3 palette_hsv(float t) {
    float h = t * 5.0f;
    float f = fract(h);
    float q = 1.0f - f;
    switch ((int)floor(h) % 6) {
        case 0: return float3(1.0, f, 0.0);
        case 1: return float3(q, 1.0, 0.0);
        case 2: return float3(0.0, 1.0, f);
        case 3: return float3(0.0, q, 1.0);
        case 4: return float3(f, 0.0, 1.0);
        default:return float3(1.0, 0.0, q);
    }
}
inline float3 palette_cosine(float t, float3 a, float3 b, float3 c, float3 d) {
    return a + b * cos(6.28318f * (c * t + d));
}

// ===== Kernel =====
kernel void mandelbrotKernel(const device MandelbrotUniforms& u [[buffer(0)]],
                             texture2d<float, access::write> outTex [[texture(0)]],
                             uint2 gid [[thread_position_in_grid]])
{
    int stepPix = max(1, u.pixelStep);
    uint baseX = gid.x * (uint)stepPix;
    uint baseY = gid.y * (uint)stepPix;
    if (baseX >= u.size.x || baseY >= u.size.y) return;

    // Coordinate at the upper-left of this block
    float cr, ci;
    if (u.deepMode == 0) {
        cr = u.origin.x + (float)baseX * u.step.x;
        ci = u.origin.y + (float)baseY * u.step.y;
    } else {
        DS oR = (DS){u.originHi.x, u.originLo.x};
        DS oI = (DS){u.originHi.y, u.originLo.y};
        DS sR = (DS){u.stepHi.x,   u.stepLo.x};
        DS sI = (DS){u.stepHi.y,   u.stepLo.y};
        DS bx = ds_mul_f(sR, (float)baseX);
        DS by = ds_mul_f(sI, (float)baseY);
        DS r  = ds_add(oR, bx);
        DS i  = ds_add(oI, by);
        cr = ds_to_float(r);
        ci = ds_to_float(i);
    }

    // Escape-time loop (single-precision iteration)
    float zr = 0.0f, zi = 0.0f;
    float zr2 = 0.0f, zi2 = 0.0f;
    int it = 0;
    const int maxIt = u.maxIt;
    while (it < maxIt && (zr2 + zi2) <= 4.0f) {
        zi = 2.0f * zr * zi + ci;
        zr = zr2 - zi2 + cr;
        zr2 = zr * zr;
        zi2 = zi * zi;
        ++it;
    }

    float t = smooth_iter(it, zr2 + zi2, maxIt);
    float3 rgb;
    if (it >= maxIt) {
        rgb = float3(0.0);
    } else {
        if (u.palette == 0) {
            rgb = palette_hsv(t);
        } else if (u.palette == 1) {
            rgb = palette_cosine(t,
                                 float3(0.2, 0.0, 0.0),
                                 float3(0.8, 0.7, 0.0),
                                 float3(1.0, 1.0, 1.0),
                                 float3(0.0, 0.15, 0.20));
        } else {
            rgb = palette_cosine(t,
                                 float3(0.1, 0.2, 0.4),
                                 float3(0.3, 0.4, 0.6),
                                 float3(1.0, 1.0, 1.0),
                                 float3(0.0, 0.25, 0.20));
        }
    }

    // Fill the block
    for (int oy = 0; oy < stepPix; ++oy) {
        uint yy = baseY + (uint)oy;
        if (yy >= u.size.y) break;
        for (int ox = 0; ox < stepPix; ++ox) {
            uint xx = baseX + (uint)ox;
            if (xx >= u.size.x) break;
            outTex.write(float4(rgb, 1.0), uint2(xx, yy));
        }
    }
}
