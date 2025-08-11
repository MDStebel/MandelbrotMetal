//
//  Mandelbrot.metal
//  Mandelbrot Metal
//
//  Created by Michael Stebel on 8/8/25.
//

#include <metal_stdlib>
using namespace metal;

// ===== Uniforms (must match Swift) =====
struct MandelbrotUniforms {
    float2 origin;   // legacy origin (float)
    float2 step;     // legacy step (units per pixel)
    int    maxIt;    // iterations
    uint2  size;     // output size in pixels
    int    pixelStep;// (renderer uses 1)
    int    palette;  // 0=HSV, 1=Fire, 2=Ocean, 3=LUT
    int    deepMode; // 0=off, 1=double-single coordinate mapping
    float2 originHi; // deep zoom hi components (re, im)
    float2 originLo; // deep zoom lo components (re, im)
    float2 stepHi;   // deep zoom step hi (dx, dy)
    float2 stepLo;   // deep zoom step lo (dx, dy)
    int    perturbation; // 0=off, 1=on
    float2 c0;           // reference point for perturbation (complex)
};

// ===== Math helpers =====

// Smooth coloring term (log-smooth)
inline float smooth_term(int it, float r2, int maxIt) {
    if (it >= maxIt) return 0.0f;
    float v = max(r2, 1e-30f);
    float nu = (float)it + 1.0f - log2(0.5f * log(v));
    return clamp(nu / (float)maxIt, 0.0f, 1.0f);
}

// --- Double-single (hi/lo) minimal helpers ---
struct DS { float hi; float lo; };

inline float2 two_sum(float a, float b) {
    float s  = a + b;
    float bb = s - a;
    float e  = (a - (s - bb)) + (b - bb);
    return float2(s, e);
}

inline DS ds_make(float hi, float lo) { DS r; r.hi = hi; r.lo = lo; return r; }

inline DS ds_add(DS a, DS b) {
    float2 s  = two_sum(a.hi, b.hi);
    float2 t  = two_sum(a.lo, b.lo);
    float2 s2 = two_sum(s.x, t.x);
    float lo  = s.y + t.y + s2.y;
    float2 f  = two_sum(s2.x, lo);
    return ds_make(f.x, f.y);
}

inline DS ds_mul_float(DS a, float b) {
    float p  = a.hi * b;
    float e  = fma(a.hi, b, -p) + a.lo * b;
    float2 s = two_sum(p, e);
    return ds_make(s.x, s.y);
}

inline float ds_to_float(DS a) { return a.hi + a.lo; }

// --- Simple complex helpers (float) ---
inline float2 cadd(float2 a, float2 b) { return float2(a.x + b.x, a.y + b.y); }

// ===== Palettes =====
inline float3 hsv2rgb(float h, float s, float v) {
    float c = v * s;
    float x = c * (1.0 - fabs(fmod(h * 6.0, 2.0) - 1.0));
    float3 rgb;
    if (h < 1.0/6.0)      rgb = float3(c, x, 0);
    else if (h < 2.0/6.0) rgb = float3(x, c, 0);
    else if (h < 3.0/6.0) rgb = float3(0, c, x);
    else if (h < 4.0/6.0) rgb = float3(0, x, c);
    else if (h < 5.0/6.0) rgb = float3(x, 0, c);
    else                  rgb = float3(c, 0, x);
    float m = v - c;
    return rgb + m;
}

inline float4 palette_builtin(int palette, float t) {
    t = clamp(t, 0.0f, 1.0f);
    if (palette == 0) {
        // HSV ring
        float3 rgb = hsv2rgb(fract(t), 0.95, 1.0);
        return float4(rgb, 1.0);
    } else if (palette == 1) {
        // Fire (black -> red -> orange -> yellow -> white)
        float3 a = float3(0.0, 0.0, 0.0);
        float3 b = float3(1.0, 0.0, 0.0);
        float3 c = float3(1.0, 0.5, 0.0);
        float3 d = float3(1.0, 1.0, 0.0);
        float3 e = float3(1.0, 1.0, 1.0);
        float tt = t * 4.0;
        if (tt < 1.0)      return float4(mix(a, b, tt), 1.0);
        else if (tt < 2.0) return float4(mix(b, c, tt - 1.0), 1.0);
        else if (tt < 3.0) return float4(mix(c, d, tt - 2.0), 1.0);
        else               return float4(mix(d, e, tt - 3.0), 1.0);
    } else { // 2 = Ocean
        // Ocean (black -> blue -> teal -> cyan -> white)
        float3 a = float3(0.0, 0.0, 0.0);
        float3 b = float3(0.0, 0.0, 1.0);
        float3 c = float3(0.0, 0.5, 0.7);
        float3 d = float3(0.0, 1.0, 1.0);
        float3 e = float3(1.0, 1.0, 1.0);
        float tt = t * 4.0;
        if (tt < 1.0)      return float4(mix(a, b, tt), 1.0);
        else if (tt < 2.0) return float4(mix(b, c, tt - 1.0), 1.0);
        else if (tt < 3.0) return float4(mix(c, d, tt - 2.0), 1.0);
        else               return float4(mix(d, e, tt - 3.0), 1.0);
    }
}

// If a LUT (palette==3) is bound to texture(1), sample it in [0..1] along X
inline float4 palette_sample_lut(texture2d<float, access::sample> lutTex, sampler s, float t) {
    t = clamp(t, 0.0f, 1.0f);
    float w = float(lutTex.get_width());
    if (w <= 0.5f) { // defensive: no LUT bound
        return float4(0.0,0.0,0.0,0.0);
    }
    float x = (t * (w - 1.0f) + 0.5f) / w; // center of texels
    return lutTex.sample(s, float2(x, 0.5f));
}

// ===== Kernel =====
kernel void mandelbrotKernel(
    constant MandelbrotUniforms& u                 [[ buffer(0) ]],
    const device float2*        refOrbit           [[ buffer(1) ]], // optional when perturbation off
    texture2d<float, access::write>  outTex        [[ texture(0) ]],
    texture2d<float, access::sample> paletteTex    [[ texture(1) ]],
    uint2 gid [[thread_position_in_grid]]
) {
    // We expect renderer to dispatch a 1:1 grid; still guard against OOB
    if (gid.x >= u.size.x || gid.y >= u.size.y) return;

    // Map pixel -> complex c (double-single mapping if deepMode)
    float2 c;
    if (u.deepMode != 0) {
        DS oR = ds_make(u.originHi.x, u.originLo.x);
        DS oI = ds_make(u.originHi.y, u.originLo.y);
        DS sR = ds_make(u.stepHi.x,   u.stepLo.x);
        DS sI = ds_make(u.stepHi.y,   u.stepLo.y);
        DS cx = ds_add(oR, ds_mul_float(sR, float(gid.x)));
        DS cy = ds_add(oI, ds_mul_float(sI, float(gid.y)));
        c = float2(ds_to_float(cx), ds_to_float(cy));
    } else {
        c = u.origin + float2(gid) * u.step;
    }

    int maxIt = max(1, u.maxIt);
    int it = 0;
    float2 z = float2(0.0f);
    float r2 = 0.0f;

    if (u.perturbation != 0 && refOrbit != nullptr) {
        // First-order perturbation around reference orbit at c0
        // Renderer builds: orbit[i] = z_{i+1}, with z_0 = 0
        float2 dz = float2(0.0, 0.0);        // dz_0 = 0
        float2 dc = c - u.c0;                // small delta in c
        for (it = 0; it < maxIt; ++it) {
            float2 zref_n = (it == 0) ? float2(0.0, 0.0) : refOrbit[it - 1];
            // dz_{n+1} = 2*z_ref_n*dz_n + dc
            float2 twozr = zref_n * 2.0f;
            float2 dzn = float2(twozr.x * dz.x - twozr.y * dz.y,
                                twozr.x * dz.y + twozr.y * dz.x) + dc;
            dz = dzn;
            z = zref_n + dz;                 // z_n approximation
            r2 = dot(z, z);
            if (r2 > 4.0f) break;
        }
    } else {
        // Plain Mandelbrot
        float x = 0.0f, y = 0.0f;
        for (it = 0; it < maxIt; ++it) {
            float xx = x*x - y*y + c.x;
            float yy = 2.0f * x * y + c.y;
            x = xx; y = yy;
            r2 = x*x + y*y;
            if (r2 > 4.0f) break;
        }
        z = float2(x, y);
    }

    float t = smooth_term(it, r2, maxIt);   // 0..1 (0 if maxed out)
    float4 color;

    if (u.palette == 3) {
        constexpr sampler s(address::clamp_to_edge, filter::linear);
        float4 lutc = palette_sample_lut(paletteTex, s, t);
        color = (lutc.a > 0.0f ? lutc : palette_builtin(0, t));
    } else {
        color = palette_builtin(u.palette, t);
    }

    outTex.write(color, gid);
}
