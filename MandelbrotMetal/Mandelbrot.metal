//  Mandelbrot Metal
//
//  Created by Michael Stebel on 8/8/25.
//

#include <metal_stdlib>
using namespace metal;

// =======================
// Uniforms — must match Swift exactly (field order & sizes)
// =======================
struct MandelbrotUniforms {
    // Base float mapping
    float2 origin;
    float2 step;
    int    maxIt;
    uint2  size;
    int    pixelStep;         // reserved

    // Quality / color
    int    subpixelSamples;   // 1 or 4
    int    palette;           // 0=HSV, 1=Fire, 2=Ocean, 3=LUT
    int    deepMode;          // 0/1
    int    _pad0;             // 16B align

    // Double-single splits
    float2 originHi;
    float2 originLo;
    float2 stepHi;
    float2 stepLo;

    // Perturbation
    int    perturbation;      // 0/1
    int    refCount;          // orbit length
    float2 c0;                // reference c
    float2 _pad1;             // 16B align
};

// =======================
// Small helpers
// =======================
inline float fractf(float x) { return x - floor(x); }
inline float  lerpf(float a, float b, float t) { return a + (b - a) * t; }
inline float3 lerp3(float3 a, float3 b, float t) { return a + (b - a) * t; }
inline float  saturate(float x) { return clamp(x, 0.0f, 1.0f); }

// =======================
// Double‑single type & ops (hi+lo)
// =======================
struct ds2 { float hi; float lo; };

inline ds2 ds_make(float hi, float lo) { ds2 r; r.hi = hi; r.lo = lo; return r; }

inline ds2 ds_add(ds2 a, ds2 b) {
    // Dekker-like two-sum on floats
    float s  = a.hi + b.hi;
    float bb = s - a.hi;
    float e  = (a.hi - (s - bb)) + (b.hi - bb) + a.lo + b.lo;
    float hi = s + e;
    float lo = e - (hi - s);
    return ds_make(hi, lo);
}

inline ds2 ds_from_f(float x) { return ds_make(x, 0.0f); }

inline ds2 ds_mul(ds2 a, ds2 b) {
    // High product + error terms
    float p  = a.hi * b.hi;
    float e  = fma(a.hi, b.hi, -p) + a.hi*b.lo + a.lo*b.hi; // ignore lo*lo term (tiny)
    float hi = p + e;
    float lo = e - (hi - p);
    return ds_make(hi, lo);
}

inline ds2 ds_mul_f(ds2 a, float s) {
    float p  = a.hi * s;
    float e  = fma(a.hi, s, -p) + a.lo * s;
    float hi = p + e;
    float lo = e - (hi - p);
    return ds_make(hi, lo);
}

inline ds2 ds_sub(ds2 a, ds2 b) {
    float s  = a.hi - b.hi;
    float bb = s - a.hi;
    float e  = (a.hi - (s - bb)) - (b.hi + bb) + a.lo - b.lo;
    float hi = s + e;
    float lo = e - (hi - s);
    return ds_make(hi, lo);
}

inline ds2 ds_sqr(ds2 a) { return ds_mul(a, a); }
inline float ds_to_float(ds2 a) { return a.hi + a.lo; }

// Periodic renormalization to keep hi/lo well‑conditioned
inline ds2 ds_compact(ds2 a) {
    float hi = a.hi + a.lo;
    float lo = a.lo - (hi - a.hi);
    return ds_make(hi, lo);
}

// =======================
// Palettes
// =======================
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

// 1D LUT stored as 1×W or H×1 texture. Samples linearly.
inline float3 paletteLUT(texture2d<float, access::sample> lut, float t, sampler s) {
    uint w = lut.get_width();
    uint h = lut.get_height();
    if (w <= 1 && h <= 1) return paletteHSV(t);
    float u = clamp(t, 0.0, 1.0);
    if (w > 1)  return lut.sample(s, float2(u, 0.5)).rgb;   // horizontal strip
    else        return lut.sample(s, float2(0.5, u)).rgb;   // vertical strip
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

// =======================
// Mapping
// =======================
inline float2 mapComplexF(uint2 gid, constant MandelbrotUniforms& u) {
    return float2(u.origin.x + u.step.x * (float)gid.x,
                  u.origin.y + u.step.y * (float)gid.y);
}

inline void mapComplexDS(uint2 gid, constant MandelbrotUniforms& u, thread ds2& cx, thread ds2& cy) {
    float ix = (float)gid.x;
    float iy = (float)gid.y;

    ds2 ox = ds_make(u.originHi.x, u.originLo.x);
    ds2 oy = ds_make(u.originHi.y, u.originLo.y);
    ds2 sx = ds_make(u.stepHi.x,   u.stepLo.x);
    ds2 sy = ds_make(u.stepHi.y,   u.stepLo.y);

    // c = origin + step * index  (DS)
    cx = ds_add(ox, ds_mul_f(sx, ix));
    cy = ds_add(oy, ds_mul_f(sy, iy));
}

// =======================
// Interior tests
// =======================
inline bool inInteriorF(float2 c) {
    // Period‑2 bulb
    float xp1 = c.x + 1.0f;
    if (xp1 * xp1 + c.y * c.y < 0.0625f) return true;
    // Main cardioid
    float xq = c.x - 0.25f;
    float q  = xq*xq + c.y*c.y;
    return (q * (q + xq) < 0.25f * c.y*c.y);
}

inline bool inInteriorDS(ds2 cx, ds2 cy) {
    // Evaluate in float from DS (stable enough for a quick reject)
    float2 cf = float2(ds_to_float(cx), ds_to_float(cy));
    return inInteriorF(cf);
}

// =======================
// Iteration
// =======================
inline int iterateMandelF(float2 c, int maxIt, thread float& zx, thread float& zy) {
    zx = 0.0f; zy = 0.0f;
    int i = 0;
    for (; i < maxIt; ++i) {
        float xx = zx*zx - zy*zy + c.x;
        float yy = 2.0f*zx*zy + c.y;
        zx = xx; zy = yy;
        if (zx*zx + zy*zy > 4.0f) break;
    }
    return i;
}

inline int iterateMandelDS(ds2 cx, ds2 cy, int maxIt, thread float& zx, thread float& zy) {
    ds2 zxds = ds_from_f(0.0f);
    ds2 zyds = ds_from_f(0.0f);
    int i = 0;
    for (; i < maxIt; ++i) {
        // z^2 + c (DS)
        ds2 zx2 = ds_sqr(zxds);
        ds2 zy2 = ds_sqr(zyds);
        ds2 xx  = ds_sub(zx2, zy2);
        ds2 two = ds_from_f(2.0f);
        ds2 xy  = ds_mul(ds_mul(two, zxds), zyds);

        zxds = ds_add(xx, cx);
        zyds = ds_add(xy, cy);

        // Periodic compaction to keep conditioning
        if ((i & 7) == 7) { zxds = ds_compact(zxds); zyds = ds_compact(zyds); }

        // Bailout in float (fast)
        float zx_f = ds_to_float(zxds);
        float zy_f = ds_to_float(zyds);
        if (zx_f*zx_f + zy_f*zy_f > 4.0f) { zx = zx_f; zy = zy_f; break; }
    }
    if (i == maxIt) { zx = ds_to_float(zxds); zy = ds_to_float(zyds); }
    return i;
}

// =======================
// Perturbation (float, uses ref orbit buffer)
// z_n ≈ ref_n + δ_n;   δ_{n+1} = 2*ref_n*δ_n + δ_n^2 + (c - c0)
// =======================
inline int iteratePerturb(float2 c, float2 c0,
                          const device float2* ref, int refCount, int maxIt,
                          thread float& zx, thread float& zy)
{
    float2 delta = float2(c.x - c0.x, c.y - c0.y);
    float2 z = delta; // start with δ_0
    int nMax = min(maxIt, refCount);
    int i = 0;
    for (; i < nMax; ++i) {
        float2 r = ref[i];                   // reference z_n
        // δ^2 + 2*r*δ + (c - c0)
        float2 z2 = float2(z.x*z.x - z.y*z.y, 2.0f*z.x*z.y);
        float2 two_rz = float2(2.0f*(r.x*z.x - r.y*z.y),
                               2.0f*(r.x*z.y + r.y*z.x));
        z = z2 + two_rz + delta;

        float2 zn = r + z;                   // approximate z_n
        if (dot(zn, zn) > 4.0f) { zx = zn.x; zy = zn.y; break; }

        // mild compaction
        if ((i & 7) == 7) { z.x = z.x + 1e-20f - 1e-20f; z.y = z.y + 1e-20f - 1e-20f; }
    }
    if (i == nMax) { float2 rn = (refCount > 0 ? ref[min(refCount-1, nMax-1)] : float2(0)); float2 zn = rn + z; zx = zn.x; zy = zn.y; }
    return i;
}

// =======================
// Kernel
// =======================
kernel void mandelbrotKernel(
    constant MandelbrotUniforms& u                 [[buffer(0)]],
    const device float2*         refOrbit          [[buffer(1)]],  // optional (may be dummy)
    texture2d<float, access::write>  outTex        [[texture(0)]],
    texture2d<float, access::sample> paletteTex    [[texture(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= u.size.x || gid.y >= u.size.y) return;

    constexpr sampler s(address::clamp_to_edge, filter::linear);

    // Sub‑pixel offsets for 2×2 rotated grid
    const float2 offsets[4] = {
        float2( 0.25,  0.25),
        float2(-0.25,  0.25),
        float2( 0.25, -0.25),
        float2(-0.25, -0.25)
    };
    int spp = max(1, u.subpixelSamples);
    float3 acc = float3(0.0);

    for (int sidx = 0; sidx < spp; ++sidx) {
        // ===== Map pixel to c (with sub‑pixel) =====
        if (u.deepMode != 0) {
            ds2 cx, cy;
            mapComplexDS(gid, u, cx, cy);
            if (spp > 1) {
                ds2 sx = ds_make(u.stepHi.x, u.stepLo.x);
                ds2 sy = ds_make(u.stepHi.y, u.stepLo.y);
                float2 off = offsets[sidx];
                cx = ds_add(cx, ds_mul_f(sx, off.x));
                cy = ds_add(cy, ds_mul_f(sy, off.y));
            }

            if (inInteriorDS(cx, cy)) {
                // interior: black
                // (acc += 0)
            } else {
                float zx, zy;
                int it;
                if (u.perturbation != 0 && u.refCount > 0 && refOrbit) {
                    // Use float perturbation with DS‑derived c reduced to float
                    float2 cf = float2(ds_to_float(cx), ds_to_float(cy));
                    it = iteratePerturb(cf, u.c0, refOrbit, u.refCount, max(1, u.maxIt), zx, zy);
                } else {
                    it = iterateMandelDS(cx, cy, max(1, u.maxIt), zx, zy);
                }

                float3 rgb;
                if (it >= u.maxIt) {
                    rgb = float3(0.0);
                } else {
                    float r2 = max(zx*zx + zy*zy, 1.0f + 1e-20f);
                    float log_zn = 0.5f * log(r2);
                    float nu = log(log_zn / log(2.0f)) / log(2.0f);
                    float mu = (float)it + 1.0f - clamp(nu, 0.0f, 1.0f);
                    float t  = clamp(mu / (float)max(1, u.maxIt), 0.0f, 1.0f);
                    t = clamp((t - 0.015f) / 0.97f, 0.0f, 1.0f);
                    acc += pickColor(u.palette, t, paletteTex, s);
                }
            }
        } else {
            // Float path
            float2 c = mapComplexF(gid, u);
            if (spp > 1) {
                float2 off = offsets[sidx];
                c += float2(u.step.x * off.x, u.step.y * off.y);
            }

            if (inInteriorF(c)) {
                // interior: black
            } else {
                float zx, zy;
                int it;
                if (u.perturbation != 0 && u.refCount > 0 && refOrbit) {
                    it = iteratePerturb(c, u.c0, refOrbit, u.refCount, max(1, u.maxIt), zx, zy);
                } else {
                    it = iterateMandelF(c, max(1, u.maxIt), zx, zy);
                }

                float3 rgb;
                if (it >= u.maxIt) {
                    rgb = float3(0.0);
                } else {
                    float r2 = max(zx*zx + zy*zy, 1.0f + 1e-20f);
                    float log_zn = 0.5f * log(r2);
                    float nu = log(log_zn / log(2.0f)) / log(2.0f);
                    float mu = (float)it + 1.0f - clamp(nu, 0.0f, 1.0f);
                    float t  = clamp(mu / (float)max(1, u.maxIt), 0.0f, 1.0f);
                    t = clamp((t - 0.015f) / 0.97f, 0.0f, 1.0f);
                    acc += pickColor(u.palette, t, paletteTex, s);
                }
            }
        }
    }

    float3 rgb = (spp > 1) ? (acc / (float)spp) : acc;
    outTex.write(float4(rgb, 1.0), gid);
}
