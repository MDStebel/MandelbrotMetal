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

    // Double-single mapping splits
    float2 originHi;
    float2 originLo;
    float2 stepHi;
    float2 stepLo;

    // Perturbation (optional; kernel ignores if refCount==0)
    int    perturbation;  // 0/1
    int    refCount;      // orbit length
    float2 c0;            // reference c
    float2 _pad1;         // alignment padding
};

// =============================================================
// Small helpers
// =============================================================
inline float fractf(float x) { return x - floor(x); }
inline float  lerpf(float a, float b, float t) { return a + (b - a) * t; }
inline float3 lerp3(float3 a, float3 b, float t) { return a + (b - a) * t; }
inline float  saturate(float x) { return clamp(x, 0.0f, 1.0f); }

inline float shape_t(float t) {
    // Unified contrast shaping for color normalization
    return pow(clamp((t - 0.01f) / 0.99f, 0.0f, 1.0f), 0.85f);
}



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

// Complex ds2 multiply: (ax + i*ay) * (bx + i*by) = (ax*bx - ay*by) + i(ax*by + ay*bx)
inline void ds_cmul(ds2 ax, ds2 ay, ds2 bx, ds2 by, thread ds2 &rx, thread ds2 &ry) {
    ds2 ac = ds_mul(ax, bx);
    ds2 bd = ds_mul(ay, by);
    ds2 ad = ds_mul(ax, by);
    ds2 bc = ds_mul(ay, bx);
    rx = ds_sub(ac, bd);
    ry = ds_add(ad, bc);
}
inline int iteratePerturbDS(ds2 cx, ds2 cy,
                            ds2 c0x, ds2 c0y,
                            const device float4 *ref,
                            int refCount,
                            int maxIt,
                            thread float &zxOut,
                            thread float &zyOut)
{
    // dz_{n+1} = 2*z_ref[n]*dz_n + dz_n^2 + (c - c0)
    // z_{n+1}  = z_ref[n+1] + dz_{n+1}
    ds2 dzx = ds_from_float(0.0f), dzy = ds_from_float(0.0f);
    ds2 dcx = ds_sub(cx, c0x);
    ds2 dcy = ds_sub(cy, c0y);
    ds2 zx = ds_from_float(0.0f), zy = ds_from_float(0.0f);

    const int N = min(maxIt, max(1, refCount) - 1);
    for (int i = 0; i < N; ++i) {
        // load z_ref[n] and z_ref[n+1] as DS (hi.xy, lo.zw)
        float4 zn4   = ref[i];
        float4 znp14 = ref[i + 1];
        ds2 znx   = ds_make(zn4.x,   zn4.z);
        ds2 zny   = ds_make(zn4.y,   zn4.w);
        ds2 znp1x = ds_make(znp14.x, znp14.z);
        ds2 znp1y = ds_make(znp14.y, znp14.w);

        // two*zn * dz
        ds2 two = ds_make(2.0f, 0.0f);
        ds2 tznx = ds_mul(two, znx);
        ds2 tzny = ds_mul(two, zny);
        ds2 tzd_x, tzd_y;
        ds_cmul(tznx, tzny, dzx, dzy, tzd_x, tzd_y);

        // dz^2
        ds2 dz2x, dz2y;
        ds_cmul(dzx, dzy, dzx, dzy, dz2x, dz2y);

        dzx = ds_add(ds_add(tzd_x, dz2x), dcx);
        dzy = ds_add(ds_add(tzd_y, dz2y), dcy);

        ds2 zxds = ds_add(znp1x, dzx);
        ds2 zyds = ds_add(znp1y, dzy);
        float zxF = ds_to_float(zxds);
        float zyF = ds_to_float(zyds);
        if (zxF*zxF + zyF*zyF > 4.0f) { zxOut = zxF; zyOut = zyF; return i; }

        zx = zxds; zy = zyds;
    }
    zxOut = ds_to_float(zx);
    zyOut = ds_to_float(zy);
    return N;
}

// =============================================================
// Mapping + interior tests
// =============================================================
inline float2 mapComplexF(uint2 gid, constant MandelbrotUniforms &u) {
    return float2(u.origin.x + u.step.x * (float)gid.x,
                  u.origin.y + u.step.y * (float)gid.y);
}
inline void mapComplexDS(uint2 gid, constant MandelbrotUniforms &u,
                         thread ds2 &cx, thread ds2 &cy) {
    float ix = (float)gid.x, iy = (float)gid.y;
    float cxh = u.originHi.x + u.stepHi.x * ix;
    float cyh = u.originHi.y + u.stepHi.y * iy;
    float cxl = u.originLo.x + u.stepLo.x * ix;
    float cyl = u.originLo.y + u.stepLo.y * iy;
    cx = { cxh, cxl };
    cy = { cyh, cyl };
}
inline bool inInteriorF(float2 c) {
    float xp1 = c.x + 1.0f;
    if ((xp1 * xp1 + c.y * c.y) < 0.0625f) return true; // period-2 bulb
    float xq = c.x - 0.25f;
    float q = xq * xq + c.y * c.y;
    return (q * (q + xq)) < (0.25f * c.y * c.y);        // main cardioid
}

// Cheap delta bailout: if the pixel's c is far from the reference c0,
// we can assume fast escape and avoid expensive perturbation math.
inline bool cheapDeltaEscape(float2 c, float2 c0) {
    float2 d = c - c0;
    return dot(d, d) > 16.0f; // radius 4^2 in c-space (tunable)
}

// =============================================================
// Iteration — float & DS variants
// =============================================================
inline int iterateMandelF(float2 c, int maxIt, thread float &zx, thread float &zy) {
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

inline int iteratePerturbF(float2 c,
                           float2 c0,
                           const device float2 *ref,
                           int refCount,
                           int maxIt,
                           thread float &zxOut,
                           thread float &zyOut)
{
    // Delta iteration around a reference orbit z_ref[n]
    // dz_{n+1} = 2*z_ref[n]*dz_n + dz_n^2 + (c - c0)
    // z_{n+1} = z_ref[n+1] + dz_{n+1}
    float2 dz = float2(0.0, 0.0);
    const float2 dc = c - c0;
    float2 z = float2(0.0, 0.0);

    const int N = min(maxIt, max(1, refCount) - 1);
    for (int i = 0; i < N; ++i) {
        const float2 zn   = ref[i];
        const float2 znp1 = ref[i + 1];
        const float2 twozn = float2(2.0f * zn.x, 2.0f * zn.y);
        // twozn*dz
        const float2 tzd = float2(twozn.x * dz.x - twozn.y * dz.y,
                                   twozn.x * dz.y + twozn.y * dz.x);
        // dz^2
        const float2 dz2 = float2(dz.x * dz.x - dz.y * dz.y,
                                  2.0f * dz.x * dz.y);
        dz = tzd + dz2 + dc;
        z = znp1 + dz;
        if (dot(z, z) > 4.0f) { zxOut = z.x; zyOut = z.y; return i; }
    }
    zxOut = z.x; zyOut = z.y;
    return N;
}

// =============================================================
// Kernel
// =============================================================
kernel void mandelbrotKernel(
    constant MandelbrotUniforms& u              [[buffer(0)]],
    const device float4 *refOrbitDS             [[buffer(1)]], // DS reference orbit
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

                // Cheap delta bailout: if far from reference c0, do a short float path and continue
                if (u.perturbation != 0 && u.refCount > 1 && cheapDeltaEscape(cf, u.c0)) {
                    zx = 0.0f; zy = 0.0f;
                    int i = 0;
                    int maxItLocal = max(1, u.maxIt);
                    for (; i < min(maxItLocal, 64); ++i) {
                        float xx = zx*zx - zy*zy + cf.x;
                        float yy = 2.0f*zx*zy + cf.y;
                        zx = xx; zy = yy;
                        if (zx*zx + zy*zy > 4.0f) break;
                    }
                    if (i < maxItLocal) {
                        float r2 = max(zx*zx + zy*zy, 1.0f + 1e-12f);
                        float log_zn = 0.5f * log(r2);
                        float nu = log(log_zn / log(2.0f)) / log(2.0f);
                        float mu = (float)i + 1.0f - clamp(nu, 0.0f, 1.0f);
                        float t = clamp(mu / (float)u.maxIt, 0.0f, 1.0f);
                        t = shape_t(t);
                        acc += pickColor(u.palette, t, paletteTex, samp);
                    }
                    continue;
                }

                int it;
                if (u.perturbation != 0 && u.refCount > 1 && refOrbitDS != nullptr) {
                    ds2 c0x = ds_from_float(u.c0.x);
                    ds2 c0y = ds_from_float(u.c0.y);
                    it = iteratePerturbDS(cx, cy, c0x, c0y, refOrbitDS, u.refCount, max(1, u.maxIt), zx, zy);
                } else {
                    it = iterateMandelDS(cx, cy, max(1, u.maxIt), zx, zy);
                }
                if (it < u.maxIt) {
                    float r2 = max(zx*zx + zy*zy, 1.0f + 1e-12f);
                    float log_zn = 0.5f * log(r2);
                    float nu = log(log_zn / log(2.0f)) / log(2.0f);
                    float mu = (float)it + 1.0f - clamp(nu, 0.0f, 1.0f);
                    float t = clamp(mu / (float)u.maxIt, 0.0f, 1.0f);
                    t = shape_t(t);
                    acc += pickColor(u.palette, t, paletteTex, samp);
                }
            }
        } else {
            float2 c = mapComplexF(gid, u);
            if (spp > 1) c += u.step * offsets[s];
            if (!inInteriorF(c)) {

                // Cheap delta bailout: if far from reference c0, do a short float path and continue
                if (u.perturbation != 0 && u.refCount > 1 && cheapDeltaEscape(c, u.c0)) {
                    float zx = 0.0f, zy = 0.0f;
                    int i = 0;
                    int maxItLocal = max(1, u.maxIt);
                    for (; i < min(maxItLocal, 64); ++i) {
                        float xx = zx*zx - zy*zy + c.x;
                        float yy = 2.0f*zx*zy + c.y;
                        zx = xx; zy = yy;
                        if (zx*zx + zy*zy > 4.0f) break;
                    }
                    if (i < maxItLocal) {
                        float r2 = max(zx*zx + zy*zy, 1.0f + 1e-12f);
                        float log_zn = 0.5f * log(r2);
                        float nu = log(log_zn / log(2.0f)) / log(2.0f);
                        float mu = (float)i + 1.0f - clamp(nu, 0.0f, 1.0f);
                        float t = clamp(mu / (float)u.maxIt, 0.0f, 1.0f);
                        t = shape_t(t);
                        acc += pickColor(u.palette, t, paletteTex, samp);
                    }
                    continue;
                }

                float zx, zy;
                int it;
                if (u.perturbation != 0 && u.refCount > 1 && refOrbitDS != nullptr) {
                    it = iteratePerturbF(c, u.c0, (const device float2*)refOrbitDS, u.refCount, max(1, u.maxIt), zx, zy);
                } else {
                    it = iterateMandelF(c, max(1, u.maxIt), zx, zy);
                }
                if (it < u.maxIt) {
                    float r2 = max(zx*zx + zy*zy, 1.0f + 1e-12f);
                    float log_zn = 0.5f * log(r2);
                    float nu = log(log_zn / log(2.0f)) / log(2.0f);
                    float mu = (float)it + 1.0f - clamp(nu, 0.0f, 1.0f);
                    float t = clamp(mu / (float)u.maxIt, 0.0f, 1.0f);
                    t = shape_t(t);
                    acc += pickColor(u.palette, t, paletteTex, samp);
                }
            }
        }
    }

    float3 rgb = (spp > 1) ? acc / (float)spp : acc;
    outTex.write(float4(rgb, 1.0), gid);
}
