#include <metal_stdlib>
using namespace metal;

// ================= Uniforms (MUST MATCH Swift) =================
struct MandelbrotUniforms {
    // Base float mapping
    float2 origin;
    float2 step;
    int    maxIt;
    uint2  size;
    int    pixelStep;

    // Quality / color
    int    subpixelSamples; // 1 or 4
    int    palette;         // 0=HSV,1=Fire,2=Ocean,3=LUT
    int    deepMode;        // 0/1
    int    _pad0;           // keep 16B alignment

    // Double-single mapping splits
    float2 originHi;
    float2 originLo;
    float2 stepHi;
    float2 stepLo;

    // Perturbation (optional)
    int    perturbation;    // 0/1
    int    refCount;        // entries in ref orbit
    float2 c0;              // reference c
    float2 _pad1;           // keep 16B alignment
};

// ================= Small helpers =================
inline float fractf(float x)            { return x - floor(x); }
inline float lerpf(float a, float b, float t) { return a + (b - a) * t; }
inline float3 lerp3(float3 a, float3 b, float t){ return a + (b - a) * t; }
inline float saturate1(float x)         { return clamp(x, 0.0f, 1.0f); } // avoid name clash

// ---- Double-single (hi+lo) minimal ops ----
struct ds2 { float hi; float lo; };

inline ds2 ds_add(ds2 a, ds2 b) {
    float s = a.hi + b.hi;
    float v = s - a.hi;
    float e = (a.hi - (s - v)) + (b.hi - v) + a.lo + b.lo;
    float hi = s + e;
    float lo = e - (hi - s);
    return { hi, lo };
}

inline ds2 ds_add_f(ds2 a, float b) {
    float s = a.hi + b;
    float v = s - a.hi;
    float e = (a.hi - (s - v)) + (b - v) + a.lo;
    float hi = s + e;
    float lo = e - (hi - s);
    return { hi, lo };
}

inline ds2 ds_mul(ds2 a, ds2 b) {
    float p = a.hi * b.hi;
    float e = fma(a.hi, b.hi, -p) + a.hi * b.lo + a.lo * b.hi + a.lo * b.lo;
    float hi = p + e;
    float lo = e - (hi - p);
    return { hi, lo };
}

inline ds2 ds_mul_f(ds2 a, float b) {
    float p = a.hi * b;
    float e = fma(a.hi, b, -p) + a.lo * b;
    float hi = p + e;
    float lo = e - (hi - p);
    return { hi, lo };
}

inline float ds_to_float(ds2 a) { return a.hi + a.lo; }

// ================= Palettes =================
inline float3 hsv(float h, float s, float v) {
    float r = abs(h * 6.0 - 3.0) - 1.0;
    float g = 2.0 - abs(h * 6.0 - 2.0);
    float b = 2.0 - abs(h * 6.0 - 4.0);
    float3 rgb = clamp(float3(r,g,b), 0.0, 1.0);
    return ((rgb - 1.0) * s + 1.0) * v;
}

inline float3 paletteHSV(float t) {
    return hsv(fractf(t), 1.0, 1.0);
}

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

// 1D LUT as 1×W or H×1
inline float3 paletteLUT(texture2d<float, access::sample> lut, float t, sampler s) {
    uint w = lut.get_width();
    uint h = lut.get_height();
    if (w <= 1 && h <= 1) {
        return paletteHSV(t);
    }
    float u = clamp(t, 0.0f, 1.0f);
    if (w > 1) {
        return lut.sample(s, float2(u, 0.5)).rgb;
    } else {
        return lut.sample(s, float2(0.5, u)).rgb;
    }
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

// ================= Mapping & interior tests =================
inline float2 mapComplexF(uint2 gid, constant MandelbrotUniforms &u) {
    return float2(u.origin.x + u.step.x * (float)gid.x,
                  u.origin.y + u.step.y * (float)gid.y);
}

inline void mapComplexDS(uint2 gid, constant MandelbrotUniforms &u,
                         thread ds2 &cx, thread ds2 &cy) {
    float ix = (float)gid.x;
    float iy = (float)gid.y;
    cx = ds_add( {u.originHi.x, u.originLo.x}, ds_mul_f({u.stepHi.x, u.stepLo.x}, ix) );
    cy = ds_add( {u.originHi.y, u.originLo.y}, ds_mul_f({u.stepHi.y, u.stepLo.y}, iy) );
}

inline bool inInteriorF(float2 c) {
    float x = c.x, y = c.y;
    // period-2 bulb: (x+1)^2 + y^2 < 1/16
    float xp1 = x + 1.0f;
    if ((xp1 * xp1 + y*y) < 0.0625f) return true;
    // cardioid: q(q + x - 0.25) < 0.25*y^2
    float xq = x - 0.25f;
    float q = xq * xq + y*y;
    return (q * (q + xq) < 0.25f * y*y);
}

// ================= Iteration =================
inline int iterateMandelF(float2 c, int maxIt,
                          thread float &zx, thread float &zy) {
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

inline int iterateMandelDS(thread ds2 cx, thread ds2 cy, int maxIt,
                           thread float &zx, thread float &zy) {
    ds2 zx2 = {0.0f, 0.0f};
    ds2 zy2 = {0.0f, 0.0f};
    int i = 0;
    for (; i < maxIt; ++i) {
        // (zx + i*zy)^2 = (zx^2 - zy^2) + 2*i*zx*zy
        ds2 zxzx = ds_mul(zx2, zx2);
        ds2 zyzy = ds_mul(zy2, zy2);
        ds2 real = ds_add( ds_add(zxzx, { -zyzy.hi, -zyzy.lo }), cx );
        ds2 imag = ds_add( ds_mul_f( ds_mul(zx2, zy2), 2.0f ), cy );
        zx2 = real; zy2 = imag;

        zx = ds_to_float(zx2);
        zy = ds_to_float(zy2);
        if (zx*zx + zy*zy > 4.0f) break;
    }
    return i;
}

// Optional perturbation (float path). If you’re not using it, keep refCount=0.
inline int iteratePerturb(float2 c, float2 c0,
                          const device float2 *refOrbit, int refCount,
                          int maxIt,
                          thread float &zx, thread float &zy) {
    zx = 0.0f; zy = 0.0f;
    int i = 0;
    for (; i < maxIt; ++i) {
        float2 r = (i < refCount) ? refOrbit[i] : float2(0.0);
        // delta recursion (very simplified; suitable mainly for small deltas)
        float dx = zx, dy = zy;
        float nx = (dx*dx - dy*dy) + 2.0f * (dx * (r.x - c0.x) - dy * (r.y - c0.y)) + c.x - c0.x;
        float ny = (2.0f*dx*dy) + 2.0f * (dx * (r.y - c0.y) + dy * (r.x - c0.x)) + c.y - c0.y;
        zx = nx; zy = ny;
        float rx = r.x + zx, ry = r.y + zy;
        if (rx*rx + ry*ry > 4.0f) break;
    }
    return i;
}

// ================= Kernel =================
kernel void mandelbrotKernel(
    constant MandelbrotUniforms &u                  [[buffer(0)]],
    const device float2           *refOrbit         [[buffer(1)]], // may be dummy
    texture2d<float, access::write> outTex          [[texture(0)]],
    texture2d<float, access::sample> paletteTex     [[texture(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= u.size.x || gid.y >= u.size.y) return;

    constexpr sampler samp(address::clamp_to_edge, filter::linear);

    // 2x2 rotated-grid SSAA (if enabled)
    const float2 offsets[4] = {
        float2( 0.25,  0.25),
        float2(-0.25,  0.25),
        float2( 0.25, -0.25),
        float2(-0.25, -0.25)
    };
    int spp = (u.subpixelSamples >= 4) ? 4 : 1;

    float3 accum = float3(0.0);

    for (int s = 0; s < spp; ++s) {
        if (u.deepMode != 0) {
            // DS map
            ds2 cx, cy;
            mapComplexDS(gid, u, cx, cy);
            if (spp > 1) {
                ds2 sx = { u.stepHi.x, u.stepLo.x };
                ds2 sy = { u.stepHi.y, u.stepLo.y };
                cx = ds_add(cx, ds_mul_f(sx, offsets[s].x));
                cy = ds_add(cy, ds_mul_f(sy, offsets[s].y));
            }
            float2 cf = float2(ds_to_float(cx), ds_to_float(cy));
            if (inInteriorF(cf)) {
                // interior → black; contributes 0
            } else {
                float zx, zy;
                int it;
                if (u.perturbation != 0 && u.refCount > 0 && refOrbit != nullptr) {
                    it = iteratePerturb(cf, u.c0, refOrbit, u.refCount, max(1, u.maxIt), zx, zy);
                } else {
                    it = iterateMandelDS(cx, cy, max(1, u.maxIt), zx, zy);
                }

                float3 rgb;
                if (it >= u.maxIt) {
                    rgb = float3(0.0);
                } else {
                    float r2 = max(zx*zx + zy*zy, 1.0f + 1e-12f);
                    float log_zn = 0.5f * log(r2);
                    float nu = log(log_zn / log(2.0f)) / log(2.0f);
                    float mu = (float)it + 1.0f - clamp(nu, 0.0f, 1.0f);
                    float t  = clamp(mu / (float)max(1, u.maxIt), 0.0f, 1.0f);
                    // gentle contrast shaping
                    t = clamp((t - 0.015f) / 0.97f, 0.0f, 1.0f);
                    accum += pickColor(u.palette, t, paletteTex, samp);
                }
            }
        } else {
            // Float map
            float2 c = mapComplexF(gid, u);
            if (spp > 1) c += u.step * offsets[s];

            if (inInteriorF(c)) {
                // interior → black
            } else {
                float zx, zy;
                int it;
                if (u.perturbation != 0 && u.refCount > 0 && refOrbit != nullptr) {
                    it = iteratePerturb(c, u.c0, refOrbit, u.refCount, max(1, u.maxIt), zx, zy);
                } else {
                    it = iterateMandelF(c, max(1, u.maxIt), zx, zy);
                }

                float3 rgb;
                if (it >= u.maxIt) {
                    rgb = float3(0.0);
                } else {
                    float r2 = max(zx*zx + zy*zy, 1.0f + 1e-12f);
                    float log_zn = 0.5f * log(r2);
                    float nu = log(log_zn / log(2.0f)) / log(2.0f);
                    float mu = (float)it + 1.0f - clamp(nu, 0.0f, 1.0f);
                    float t  = clamp(mu / (float)max(1, u.maxIt), 0.0f, 1.0f);
                    t = clamp((t - 0.015f) / 0.97f, 0.0f, 1.0f);
                    accum += pickColor(u.palette, t, paletteTex, samp);
                }
            }
        }
    }

    float3 rgbOut = (spp == 1) ? accum : (accum / (float)spp);
    outTex.write(float4(rgbOut, 1.0), gid);
}
