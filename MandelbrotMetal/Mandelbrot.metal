#include <metal_stdlib>
using namespace metal;

// ======= Uniforms (must match Swift exactly) =======
struct MandelbrotUniforms {
    float2 origin;          // base float mapping
    float2 step;
    int    maxIt;
    uint2  size;
    int    pixelStep;       // reserved (unused here)
    int    subpixelSamples; // 1 or 4
    int    palette;         // 0=HSV,1=Fire,2=Ocean,3=LUT
    int    deepMode;        // 0=float map, 1=double‑single map
    int    _pad0;           // keep 16B alignment
    float2 originHi;        // DS split for mapping
    float2 originLo;
    float2 stepHi;
    float2 stepLo;
};

// ======= helpers =======
inline float  fractf(float x) { return x - floor(x); }
inline float  lerpf(float a, float b, float t) { return a + (b - a) * t; }
inline float3 lerp3(float3 a, float3 b, float t) { return a + (b - a) * t; }
inline float  saturate01(float x) { return clamp(x, 0.0f, 1.0f); }

// ======= palettes =======
inline float3 hsv(float h, float s, float v) {
    float r = fabs(h * 6.0 - 3.0) - 1.0;
    float g = 2.0 - fabs(h * 6.0 - 2.0);
    float b = 2.0 - fabs(h * 6.0 - 4.0);
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

// 1‑D LUT as 1×W or H×1 texture
inline float3 paletteLUT(texture2d<float, access::sample> lut, float t, sampler s) {
    uint w = lut.get_width();
    uint h = lut.get_height();
    if (w <= 1 && h <= 1) return paletteHSV(t);
    float u = clamp(t, 0.0, 1.0);
    return (w > 1) ? lut.sample(s, float2(u, 0.5)).rgb
                   : lut.sample(s, float2(0.5, u)).rgb;
}

inline float3 pickColor(int palette, float t,
                        texture2d<float, access::sample> paletteTex,
                        sampler s)
{
    switch (palette) {
        case 1: return paletteFire(t);
        case 2: return paletteOcean(t);
        case 3: return paletteLUT(paletteTex, t, s);
        default: return paletteHSV(t);
    }
}

// ======= Double‑single (two‑float) arithmetic =======
struct ds2 { float hi; float lo; };
inline ds2 ds_make(float x) { return { x, 0.0f }; }

inline ds2 ds_add(ds2 a, ds2 b) {
    float s = a.hi + b.hi;
    float v = s - a.hi;
    float e = (a.hi - (s - v)) + (b.hi - v) + a.lo + b.lo;
    float res_hi = s + e;
    float res_lo = e - (res_hi - s);
    return { res_hi, res_lo };
}
inline ds2 ds_add_f(ds2 a, float b) { return ds_add(a, ds_make(b)); }

inline ds2 ds_mul(ds2 a, ds2 b) {
    float p = a.hi * b.hi;
    float e = fma(a.hi, b.hi, -p) + (a.hi * b.lo + a.lo * b.hi);
    float res_hi = p + e;
    float res_lo = e - (res_hi - p);
    return { res_hi, res_lo };
}
inline ds2 ds_mul_f(ds2 a, float b) { return ds_mul(a, ds_make(b)); }

inline void ds_square_add(ds2 zx, ds2 zy, ds2 cx, ds2 cy, thread ds2 &outx, thread ds2 &outy) {
    ds2 x2 = ds_mul(zx, zx);
    ds2 y2 = ds_mul(zy, zy);
    ds2 real = ds_add(x2, { -y2.hi, -y2.lo });
    real = ds_add(real, cx);
    ds2 xy = ds_mul(zx, zy);
    ds2 imag = ds_mul_f(xy, 2.0f);
    imag = ds_add(imag, cy);
    outx = real; outy = imag;
}
inline float ds_to_float(ds2 a) { return a.hi + a.lo; }

// ======= Mapping =======
inline float2 mapComplexF(uint2 gid, constant MandelbrotUniforms &u) {
    return float2(u.origin.x + u.step.x * (float)gid.x,
                  u.origin.y + u.step.y * (float)gid.y);
}

// DS mapping that **returns ds2** (no precision drop)
inline void mapComplexDS(uint2 gid, constant MandelbrotUniforms &u,
                         thread ds2 &cx, thread ds2 &cy)
{
    float ix = (float)gid.x;
    float iy = (float)gid.y;

    // hi part
    ds2 baseX = ds_make(u.originHi.x + u.stepHi.x * ix);
    ds2 baseY = ds_make(u.originHi.y + u.stepHi.y * iy);
    // add lo part exactly
    baseX = ds_add(baseX, ds_make(u.originLo.x + u.stepLo.x * ix));
    baseY = ds_add(baseY, ds_make(u.originLo.y + u.stepLo.y * iy));

    cx = baseX; cy = baseY;
}

// ======= Iteration in DS (c is ds2) =======
inline int iterateMandelDS(ds2 cx, ds2 cy, int maxIt, thread float &outX, thread float &outY) {
    ds2 zx = { 0.0f, 0.0f }, zy = { 0.0f, 0.0f };
    int i = 0;
    for (; i < maxIt; ++i) {
        ds2 nx, ny;
        ds_square_add(zx, zy, cx, cy, nx, ny);
        zx = nx; zy = ny;
        float x = zx.hi, y = zy.hi;              // fast escape using hi
        if (x*x + y*y > 4.0f) break;
    }
    outX = ds_to_float(zx);
    outY = ds_to_float(zy);
    return i;
}

// ======= Iteration in float (fallback / shallow) =======
inline int iterateMandelF(float2 c, int maxIt, thread float &outX, thread float &outY) {
    float zx = 0.0f, zy = 0.0f;
    int i = 0;
    for (; i < maxIt; ++i) {
        float xx = zx*zx - zy*zy + c.x;
        float yy = 2.0f*zx*zy + c.y;
        zx = xx; zy = yy;
        if (zx*zx + zy*zy > 4.0f) break;
    }
    outX = zx; outY = zy;
    return i;
}

// ======= Interior tests (float) =======
inline bool inInteriorF(float2 c) {
    float xp1 = c.x + 1.0f;
    if ((xp1 * xp1 + c.y * c.y) < 0.0625f) return true;
    float xq = c.x - 0.25f;
    float q  = xq * xq + c.y * c.y;
    return (q * (q + xq) < 0.25f * c.y * c.y);
}

// ======= Kernel =======
kernel void mandelbrotKernel(
    constant MandelbrotUniforms& u [[buffer(0)]],
    texture2d<float, access::write> outTex [[texture(0)]],
    texture2d<float, access::sample> paletteTex [[texture(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= u.size.x || gid.y >= u.size.y) return;

    constexpr sampler s(address::clamp_to_edge, filter::linear);

    // Sub‑pixel locations for 2×2 SS (rotated grid)
    const float2 offsets[4] = {
        float2( 0.25,  0.25),
        float2(-0.25,  0.25),
        float2( 0.25, -0.25),
        float2(-0.25, -0.25)
    };
    int spp = max(1, u.subpixelSamples); // 1 or 4

    float3 acc = float3(0.0);

    for (int sidx = 0; sidx < spp; ++sidx) {
        // ==== map to c ====
        if (u.deepMode != 0) {
            // DS path: keep c in ds2 from the start
            ds2 cx, cy;
            mapComplexDS(gid, u, cx, cy);

            // apply sub‑pixel offset in DS space
            if (spp > 1) {
                ds2 sx = { u.stepHi.x, u.stepLo.x };
                ds2 sy = { u.stepHi.y, u.stepLo.y };
                float2 off = offsets[sidx];
                cx = ds_add(cx, ds_mul_f(sx, off.x));
                cy = ds_add(cy, ds_mul_f(sy, off.y));
            }

            // interior test in float (cheap)
            float2 cf = float2(ds_to_float(cx), ds_to_float(cy));
            if (!inInteriorF(cf)) {
                float zx, zy;
                int it = iterateMandelDS(cx, cy, max(1, u.maxIt), zx, zy);

                float3 rgb;
                if (it >= u.maxIt) {
                    rgb = float3(0.0);
                } else {
                    float r2 = max(zx*zx + zy*zy, 1.0f + 1e-12f);
                    float log_zn = 0.5f * log(r2);
                    float nu = log(log_zn / log(2.0f)) / log(2.0f);
                    float mu = (float)it + 1.0f - clamp(nu, 0.0f, 1.0f);
                    float t = clamp(mu / (float)max(1, u.maxIt), 0.0f, 1.0f);
                    t = clamp((t - 0.015f) / 0.97f, 0.0f, 1.0f);
                    rgb = pickColor(u.palette, t, paletteTex, s);
                }
                acc += rgb;
            }
            // else interior → contributes black (no add)

        } else {
            // float path
            float2 c = mapComplexF(gid, u);
            if (spp > 1) c += u.step * offsets[sidx];

            if (!inInteriorF(c)) {
                float zx, zy;
                int it = iterateMandelF(c, max(1, u.maxIt), zx, zy);

                float3 rgb;
                if (it >= u.maxIt) {
                    rgb = float3(0.0);
                } else {
                    float r2 = max(zx*zx + zy*zy, 1.0f + 1e-12f);
                    float log_zn = 0.5f * log(r2);
                    float nu = log(log_zn / log(2.0f)) / log(2.0f);
                    float mu = (float)it + 1.0f - clamp(nu, 0.0f, 1.0f);
                    float t = clamp(mu / (float)max(1, u.maxIt), 0.0f, 1.0f);
                    t = clamp((t - 0.015f) / 0.97f, 0.0f, 1.0f);
                    acc += pickColor(u.palette, t, paletteTex, s);
                }
            }
        }
    }

    float inv = 1.0f / (float)spp;
    outTex.write(float4(acc * inv, 1.0), gid);
}
