//
//  Mandelbrot.metal
//  Mandelbrot Metal
//
//  Created by Michael Stebel on 8/13/25.
//

#include <metal_stdlib>
using namespace metal;

// =============================================================
// Uniforms — MUST MATCH Swift's MandelbrotUniforms field order
// =============================================================
struct MandelbrotUniforms {
    float2 origin;        // base float mapping (normal precision)
    float2 step;
    int    maxIt;
    uint2  size;          // render target size (pixels)
    int    pixelStep;     // reserved

    int    subpixelSamples; // 1 or 4
    int    palette;         // 0=HSV,1=Fire,2=Ocean,3=LUT
    int    deepMode;        // 0=float mapping, 1=double-single mapping
    int    _pad0;           // alignment padding

    float  contrast;        // contrast shaping for normalized t (1.0 = neutral)

    // Double-single mapping splits
    float2 originHi;
    float2 originLo;
    float2 stepHi;
    float2 stepLo;

    // Perturbation (optional; kernel ignores if refCount==0)
    int    perturbation;  // 0/1
    int    refCount;      // orbit length
    float2 c0;            // reference c
    int2   _pad1;         // alignment padding
};

// =============================================================
// Small helpers
// =============================================================
inline float fractf(float x) { return x - floor(x); }
inline float  lerpf(float a, float b, float t) { return a + (b - a) * t; }
inline float3 lerp3(float3 a, float3 b, float t) { return a + (b - a) * t; }
inline float  saturate(float x) { return clamp(x, 0.0f, 1.0f); }

// =============================================================
// Simple palettes + optional LUT
// =============================================================
inline float3 hsv(float h, float s, float v) {
    float r = abs(h * 6.0 - 3.0) - 1.0;
    float g = 2.0 - abs(h * 6.0 - 2.0);
    float b = 2.0 - abs(h * 6.0 - 4.0);
    float3 rgb = clamp(float3(r,g,b), 0.0, 1.0);
    return ((rgb - 1.0) * s + 1.0) * v;
}
inline float3 paletteHSV(float t) { return hsv(fractf(t), 1.0, 1.0); }

inline float3 paletteFire(float t) {
    float3 a = float3(0.0, 0.0, 0.0);
    float3 b = float3(1.0, 0.0, 0.0);
    float3 c = float3(1.0, 0.5, 0.0);
    float3 d = float3(1.0, 1.0, 0.0);
    float3 e = float3(1.0, 1.0, 1.0);
    if (t < 0.15)       return lerp3(a, b, t / 0.15);
    else if (t < 0.50)  return lerp3(b, c, (t - 0.15) / 0.35);
    else if (t < 0.85)  return lerp3(c, d, (t - 0.50) / 0.35);
    else                return lerp3(d, e, (t - 0.85) / 0.15);
}

inline float3 paletteOcean(float t) {
    float3 a = float3(0.0, 0.0, 0.0);
    float3 b = float3(0.0, 0.0, 1.0);
    float3 c = float3(0.0, 0.5, 0.6);
    float3 d = float3(0.0, 1.0, 1.0);
    float3 e = float3(1.0, 1.0, 1.0);
    if (t < 0.15)       return lerp3(a, b, t / 0.15);
    else if (t < 0.45)  return lerp3(b, c, (t - 0.15) / 0.30);
    else if (t < 0.75)  return lerp3(c, d, (t - 0.45) / 0.30);
    else                return lerp3(d, e, (t - 0.75) / 0.25);
}

inline float3 paletteLUT(texture2d<float, access::sample> lut, float t, sampler s) {
    uint w = lut.get_width();
    uint h = lut.get_height();
    if (w <= 1 && h <= 1) return paletteHSV(t);
    float u = clamp(t, 0.0, 1.0);
    if (w > 1) return lut.sample(s, float2(u, 0.5)).rgb;
    else       return lut.sample(s, float2(0.5, u)).rgb;
}
inline float3 pickColor(int palette, float t,
                        texture2d<float, access::sample> paletteTex,
                        sampler s) {
    switch (palette) {
        case 1: return paletteFire(t);
        case 2: return paletteOcean(t);
        case 3: return paletteLUT(paletteTex, t, s);
        default: return paletteHSV(t);
    }
}

// =============================================================
// Double-single arithmetic (ds2)
// =============================================================
struct ds2 { float hi; float lo; };
inline ds2 ds_make(float hi, float lo) { return {hi, lo}; }
inline ds2 ds_from_float(float x)      { return {x, 0.0f}; }

inline ds2 ds_add(ds2 a, ds2 b) {
    float s = a.hi + b.hi;
    float v = s - a.hi;
    float t = ((b.hi - v) + (a.hi - (s - v))) + a.lo + b.lo;
    return { s + t, t - ((s + t) - s) };
}
inline ds2 ds_sub(ds2 a, ds2 b) { return ds_add(a, {-b.hi, -b.lo}); }
inline ds2 ds_mul(ds2 a, ds2 b) {
    float p = a.hi * b.hi;
    float e = fma(a.hi, b.hi, -p) + a.hi * b.lo + a.lo * b.hi;
    float s = p + e;
    return { s, (p - s) + e };
}
inline ds2 ds_mul_f(ds2 a, float f) {
    float p = a.hi * f;
    float e = fma(a.hi, f, -p) + a.lo * f;
    float s = p + e;
    return { s, (p - s) + e };
}
inline float ds_to_float(ds2 a) { return a.hi + a.lo; }

// =============================================================
// Mapping + interior tests
// =============================================================
inline uint2 gridCenter(constant MandelbrotUniforms& u)
{
    // Center pixel indices (round down for even sizes — fine for DS anchoring)
    return uint2(u.size.x >> 1, u.size.y >> 1);
}

inline float2 mapComplexF(uint2 gid, constant MandelbrotUniforms &u) {
    // Center‑relative mapping: base at center, add small offset
    uint2 c = gridCenter(u);
    float cx = (float)c.x;
    float cy = (float)c.y;

    // Base coordinate at the center (still fine in float at moderate zooms)
    float2 base = float2(u.origin.x + u.step.x * cx,
                         u.origin.y + u.step.y * cy);

    // Offset from center
    float dx = (float)gid.x - cx;
    float dy = (float)gid.y - cy;

    return base + float2(u.step.x * dx, u.step.y * dy);
}
inline void mapComplexDS(uint2 gid, constant MandelbrotUniforms &u,
                         thread ds2 &cx, thread ds2 &cy) {
    uint2 c = gridCenter(u);
    float cxIdx = (float)c.x;
    float cyIdx = (float)c.y;

    // DS base at center: base = origin + step * centerIndex
    ds2 ox = { u.originHi.x, u.originLo.x };
    ds2 oy = { u.originHi.y, u.originLo.y };
    ds2 sx = { u.stepHi.x,   u.stepLo.x   };
    ds2 sy = { u.stepHi.y,   u.stepLo.y   };

    ds2 baseX = ds_add(ox, ds_mul_f(sx, cxIdx));
    ds2 baseY = ds_add(oy, ds_mul_f(sy, cyIdx));

    // Offset from center
    float dx = (float)gid.x - cxIdx;
    float dy = (float)gid.y - cyIdx;

    cx = ds_add(baseX, ds_mul_f(sx, dx));
    cy = ds_add(baseY, ds_mul_f(sy, dy));
}
inline bool inInteriorF(float2 c) {
    float xp1 = c.x + 1.0f;
    if ((xp1 * xp1 + c.y * c.y) < 0.0625f) return true; // period-2 bulb
    float xq = c.x - 0.25f;
    float q = xq * xq + c.y * c.y;
    return (q * (q + xq)) < (0.25f * c.y * c.y);        // main cardioid
}

// =============================================================
// Iteration — float & DS variants
// =============================================================
inline int iterateMandelF(float2 c, int maxIt, thread float &zx, thread float &zy) {
    zx = 0.0f; zy = 0.0f;
    int i = 0;
    for (; i < maxIt; ++i) {
        // zx,zy -> zx^2 - zy^2 + cx ; 2*zx*zy + cy
        float xx = fma(zx, zx, -zy*zy) + c.x;
        float yy = fma(zx*zy, 2.0f, 0.0f) + c.y;
        zx = xx; zy = yy;
        if (fma(zx, zx, zy*zy) > 4.0f) break;
    }
    return i;
}
inline int iterateMandelDS(ds2 cx, ds2 cy, int maxIt, thread float &zxOut, thread float &zyOut) {
    ds2 zx = ds_from_float(0.0f), zy = ds_from_float(0.0f);
    int i = 0;
    for (; i < maxIt; ++i) {
        ds2 zx2 = ds_mul(zx, zx);
        ds2 zy2 = ds_mul(zy, zy);
        ds2 xx  = ds_sub(zx2, zy2);
        ds2 yy  = ds_mul(ds_make(2.0f, 0.0f), ds_mul(zx, zy));
        zx = ds_add(xx, cx);
        zy = ds_add(yy, cy);
        float r2 = ds_to_float(zx)*ds_to_float(zx) + ds_to_float(zy)*ds_to_float(zy);
        if (r2 > 4.0f) break;
    }
    zxOut = ds_to_float(zx);
    zyOut = ds_to_float(zy);
    return i;
}

// =============================================================
// Kernel
// =============================================================
kernel void mandelbrotKernel(
    constant MandelbrotUniforms& u              [[buffer(0)]],
    const device float2 *refOrbit               [[buffer(1)]], // kept for ABI stability
    texture2d<float, access::write> outTex      [[texture(0)]],
    texture2d<float, access::sample> paletteTex [[texture(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= u.size.x || gid.y >= u.size.y) return;

    constexpr sampler samp(address::clamp_to_edge, filter::linear);

    // 2×2 SSAA (rotated grid)
    const float2 offsets[4] = {
        float2( 0.25,  0.25),
        float2(-0.25,  0.25),
        float2( 0.25, -0.25),
        float2(-0.25, -0.25)
    };
    int spp = max(1, u.subpixelSamples);

    float3 acc = float3(0.0);

    for (int s = 0; s < spp; ++s) {
        if (u.deepMode != 0) {
            ds2 cx, cy; mapComplexDS(gid, u, cx, cy);
            if (spp > 1) {
                ds2 sx = { u.stepHi.x, u.stepLo.x };
                ds2 sy = { u.stepHi.y, u.stepLo.y };
                float2 off = offsets[s];
                cx = ds_add(cx, ds_mul_f(sx, off.x));
                cy = ds_add(cy, ds_mul_f(sy, off.y));
            }
            float zx, zy;
            float2 cf = float2(ds_to_float(cx), ds_to_float(cy));
            if (!inInteriorF(cf)) {
                int it = iterateMandelDS(cx, cy, max(1, u.maxIt), zx, zy);
                if (it < u.maxIt) {
                    float r2 = max(zx*zx + zy*zy, 1.0f + 1e-12f);
                    float log_zn = 0.5f * log(r2);
                    float nu = log(log_zn / log(2.0f)) / log(2.0f);
                    float mu = (float)it + 1.0f - clamp(nu, 0.0f, 1.0f);
                    float t = clamp(mu / (float)max(1, u.maxIt), 0.0f, 1.0f);
                    t = clamp((t - 0.015f) / 0.97f, 0.0f, 1.0f);
                    // Contrast shaping (1.0 = neutral). Avoid divide-by-zero.
                    float c = max(u.contrast, 0.01f);
                    t = pow(t, 1.0f / c);
                    acc += pickColor(u.palette, t, paletteTex, samp);
                }
            }
        } else {
            float2 c = mapComplexF(gid, u);
            if (spp > 1) c += u.step * offsets[s];
            if (!inInteriorF(c)) {
                float zx, zy;
                int it = iterateMandelF(c, max(1, u.maxIt), zx, zy);
                if (it < u.maxIt) {
                    float r2 = max(zx*zx + zy*zy, 1.0f + 1e-12f);
                    float log_zn = 0.5f * log(r2);
                    float nu = log(log_zn / log(2.0f)) / log(2.0f);
                    float mu = (float)it + 1.0f - clamp(nu, 0.0f, 1.0f);
                    float t = clamp(mu / (float)max(1, u.maxIt), 0.0f, 1.0f);
                    t = clamp((t - 0.015f) / 0.97f, 0.0f, 1.0f);
                    // Contrast shaping (1.0 = neutral). Avoid divide-by-zero.
                    float c = max(u.contrast, 0.01f);
                    t = pow(t, 1.0f / c);
                    acc += pickColor(u.palette, t, paletteTex, samp);
                }
            }
        }
    }

    float3 rgb = (spp > 1) ? acc / (float)spp : acc;
    outTex.write(float4(rgb, 1.0), gid);
}
