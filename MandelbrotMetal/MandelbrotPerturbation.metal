//
//  MandelbrotPerturbation.metal
//  Mandelbrot Metal
//
//  Created by Michael Stebel on 8/13/25.
//
//  Drop‑in guarded-perturbation kernel (A/B alongside my current kernel)

#include <metal_stdlib>
using namespace metal;

// =============================================================
// Uniforms — MUST MATCH Swift's MandelbrotUniforms field order
// (kept identical to your current Mandelbrot.metal)
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

    // Double-single mapping splits (for deep zoom)
    float2 originHi;
    float2 originLo;
    float2 stepHi;
    float2 stepLo;

    // Perturbation
    int    perturbation;  // 0/1 (kernel will ignore if 0 or refCount==0)
    int    refCount;      // length of refOrbit buffer
    float2 c0;            // reference c (center where refOrbit was built)
    float2 _pad1;         // alignment padding
};

// =============================================================
// Small helpers & palettes (same as your current file)
// =============================================================
inline float fractf(float x) { return x - floor(x); }
inline float  lerpf(float a, float b, float t) { return a + (b - a) * t; }
inline float3 lerp3(float3 a, float3 b, float t) { return a + (b - a) * t; }

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
    uint w = lut.get_width(), h = lut.get_height();
    if (w <= 1 && h <= 1) return paletteHSV(t);
    float u = clamp(t, 0.0, 1.0);
    return (w > 1) ? lut.sample(s, float2(u, 0.5)).rgb
                   : lut.sample(s, float2(0.5, u)).rgb;
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
// Double-single arithmetic & mapping (matches your current file)
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

inline uint2 gridCenter(constant MandelbrotUniforms& u) {
    return uint2(u.size.x >> 1, u.size.y >> 1);
}
inline float2 mapComplexF(uint2 gid, constant MandelbrotUniforms &u) {
    uint2 c = gridCenter(u);
    float2 base = float2(u.origin.x + u.step.x * (float)c.x,
                         u.origin.y + u.step.y * (float)c.y);
    float2 d = float2((float)gid.x - (float)c.x,
                      (float)gid.y - (float)c.y);
    return base + u.step * d;
}
inline void mapComplexDS(uint2 gid, constant MandelbrotUniforms &u,
                         thread ds2 &cx, thread ds2 &cy) {
    uint2 c = gridCenter(u);
    ds2 ox = { u.originHi.x, u.originLo.x };
    ds2 oy = { u.originHi.y, u.originLo.y };
    ds2 sx = { u.stepHi.x,   u.stepLo.x   };
    ds2 sy = { u.stepHi.y,   u.stepLo.y   };
    ds2 baseX = ds_add(ox, ds_mul_f(sx, (float)c.x));
    ds2 baseY = ds_add(oy, ds_mul_f(sy, (float)c.y));
    float2 d = float2((float)gid.x - (float)c.x,
                      (float)gid.y - (float)c.y);
    cx = ds_add(baseX, ds_mul_f(sx, d.x));
    cy = ds_add(baseY, ds_mul_f(sy, d.y));
}

inline bool inInteriorF(float2 c) {
    float xp1 = c.x + 1.0f;
    if ((xp1 * xp1 + c.y * c.y) < 0.0625f) return true;
    float xq = c.x - 0.25f;
    float q = xq * xq + c.y * c.y;
    return (q * (q + xq)) < (0.25f * c.y * c.y);
}

// =============================================================
// Direct iteration (float or DS) — used for fallback
// =============================================================
inline int iterateMandelF(float2 c, int maxIt, thread float &zx, thread float &zy) {
    zx = 0.0f; zy = 0.0f;
    int i = 0;
    for (; i < maxIt; ++i) {
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
// Guarded perturbation (float math, protected fallbacks)
// =============================================================
// refOrbit[k] contains z_ref(k) produced at c0 with z0=0.
// We evolve delta:  δ_{k+1} = 2*z_ref(k)*δ + δ² + (c - c0).
// If δ grows too large/unstable we bail to direct iteration.
inline int iteratePerturb(float2 c, float2 c0,
                          const device float2* refOrbit, int refCount,
                          int maxIt,
                          thread float &zxOut, thread float &zyOut)
{
    float2 deltaC = c - c0;     // (c - c0)
    float2 delta  = float2(0.0); // δ_0 = 0
    int k = 0;

    // Guard thresholds (tuned conservatively)
    const float THRESH_ABS   = 4e2f;     // absolute size of δ bailout
    const float THRESH_REL   = 64.0f;    // if |δ| > THRESH_REL * |z_ref| -> bail
    const int   REBASE_EVERY = 256;      // periodic clamp to keep δ bounded

    float2 z_last = float2(0.0); // will track z_ref(k) + δ_k for continuation

    for (; k < min(refCount, maxIt); ++k) {
        float2 zref = refOrbit[k];
        // δ_{k+1} = 2*z_ref*δ + δ² + (c - c0)
        float2 twoZrefDelta = float2(2.0f*zref.x*delta.x - 2.0f*zref.y*delta.y,
                                     2.0f*(zref.x*delta.y + zref.y*delta.x));
        float2 deltaSq = float2(delta.x*delta.x - delta.y*delta.y,
                                2.0f*delta.x*delta.y);
        delta = twoZrefDelta + deltaSq + deltaC;

        float2 z = zref + delta;
        z_last = z;

        // Escape test
        if (dot(z, z) > 4.0f) { zxOut = z.x; zyOut = z.y; return k; }

        // Stability guardrails
        float magRef = fmax(length(zref), 1e-12f);
        if (length(delta) > THRESH_REL * magRef || length(delta) > THRESH_ABS) {
            // Bail to direct iteration from current z
            float zx = z.x, zy = z.y;
            int i = k + 1;
            for (; i < maxIt; ++i) {
                float xx = fma(zx, zx, -zy*zy) + c.x;
                float yy = fma(zx*zy, 2.0f, 0.0f) + c.y;
                zx = xx; zy = yy;
                if (fma(zx, zx, zy*zy) > 4.0f) { zxOut = zx; zyOut = zy; return i; }
            }
            zxOut = zx; zyOut = zy;
            return i;
        }

        // Periodic gentle clamp; prevents catastrophic growth
        if ((k % REBASE_EVERY) == 0 && k > 0) {
            delta = clamp(delta, float2(-THRESH_ABS), float2(THRESH_ABS));
        }
    }

    // If reference orbit finished without escape, continue normally from z_last
    float zx = z_last.x, zy = z_last.y;
    int i = k;
    for (; i < maxIt; ++i) {
        float xx = fma(zx, zx, -zy*zy) + c.x;
        float yy = fma(zx*zy, 2.0f, 0.0f) + c.y;
        zx = xx; zy = yy;
        if (fma(zx, zx, zy*zy) > 4.0f) { zxOut = zx; zyOut = zy; return i; }
    }
    zxOut = zx; zyOut = zy;
    return i;
}

// =============================================================
// Kernel (uses perturbation when available, otherwise identical
// to your current DS/float path). Bindings match your existing
// pipeline: buffer(0)=uniforms, buffer(1)=refOrbit, tex(0)=out,
// tex(1)=palette LUT.
// =============================================================
kernel void mandelbrotKernelPerturb(
    constant MandelbrotUniforms& u                 [[buffer(0)]],
    const device float2 *refOrbit                  [[buffer(1)]],
    texture2d<float, access::write> outTex         [[texture(0)]],
    texture2d<float, access::sample> paletteTex    [[texture(1)]],
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
        // Map pixel → complex (float or DS), apply subpixel offset when needed
        float2 cFloat;
        if (u.deepMode != 0) {
            ds2 cx, cy; mapComplexDS(gid, u, cx, cy);
            if (spp > 1) {
                ds2 sx = { u.stepHi.x, u.stepLo.x };
                ds2 sy = { u.stepHi.y, u.stepLo.y };
                float2 off = offsets[s];
                cx = ds_add(cx, ds_mul_f(sx, off.x));
                cy = ds_add(cy, ds_mul_f(sy, off.y));
            }
            cFloat = float2(ds_to_float(cx), ds_to_float(cy));
        } else {
            cFloat = mapComplexF(gid, u);
            if (spp > 1) cFloat += u.step * offsets[s];
        }

        if (inInteriorF(cFloat)) {
            // interior → black (already default in acc)
            continue;
        }

        // Choose path: perturbation (if enabled & valid) or direct
        float zx, zy;
        int it;
        bool canPerturb = (u.perturbation != 0) && (u.refCount > 0) && (refOrbit != nullptr);

        if (canPerturb) {
            it = iteratePerturb(cFloat, u.c0, refOrbit, u.refCount, max(1, u.maxIt), zx, zy);
        } else {
            // fallback — keep consistent with your current deepMode
            if (u.deepMode != 0) {
                // DS direct
                ds2 cx = { cFloat.x, 0.0f };
                ds2 cy = { cFloat.y, 0.0f };
                it = iterateMandelDS(cx, cy, max(1, u.maxIt), zx, zy);
            } else {
                it = iterateMandelF(cFloat, max(1, u.maxIt), zx, zy);
            }
        }

        if (it < u.maxIt) {
            float r2 = max(zx*zx + zy*zy, 1.0f + 1e-12f);
            float log_zn = 0.5f * log(r2);
            float nu = log(log_zn / log(2.0f)) / log(2.0f);
            float mu = (float)it + 1.0f - clamp(nu, 0.0f, 1.0f);
            float t = clamp(mu / (float)max(1, u.maxIt), 0.0f, 1.0f);
            // gentle contrast shaping (same as current)
            t = clamp((t - 0.015f) / 0.97f, 0.0f, 1.0f);
            acc += pickColor(u.palette, t, paletteTex, samp);
        }
    }

    float3 rgb = (spp > 1) ? acc / (float)spp : acc;
    outTex.write(float4(rgb, 1.0), gid);
}
