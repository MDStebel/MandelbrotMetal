#include <metal_stdlib>
using namespace metal;

struct MandelbrotUniforms {
    float2  origin;     // base origin (float)
    float2  step;       // base step (float)
    int     maxIt;
    uint2   size;
    int     pixelStep;
    int     palette;    // 0=HSV 1=Fire 2=Ocean 3=LUT
    int     deepMode;   // use Hi/Lo splits if != 0
    float2  originHi;
    float2  originLo;
    float2  stepHi;
    float2  stepLo;
    int     perturbation; // ignored (not used in this kernel)
    float2  c0;           // ignored here
};

inline float fractf(float x) { return x - floor(x); }
inline float3 lerp3(float3 a, float3 b, float t) { return a + (b - a) * t; }

// ---------- palette helpers ----------

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
    // black -> red -> orange -> yellow -> white
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
    // black -> blue -> teal -> cyan -> white
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
    // sample 1D LUT (stored as 1×W or H×1); support either orientation
    uint w = lut.get_width();
    uint h = lut.get_height();
    if (w <= 1 && h <= 1) {
        // defensive fallback
        return paletteHSV(t);
    }
    float u = clamp(t, 0.0, 1.0);
    if (w > 1) {
        // 1×W strip: sample across X at y=0.5
        return lut.sample(s, float2(u, 0.5)).rgb;
    } else {
        // H×1 strip: sample across Y at x=0.5
        return lut.sample(s, float2(0.5, u)).rgb;
    }
}

inline float3 pickColor(int palette, float t,
                        texture2d<float, access::sample> paletteTex,
                        sampler s) {
    if (palette == 3) {
        return paletteLUT(paletteTex, t, s);
    } else if (palette == 1) {
        return paletteFire(t);
    } else if (palette == 2) {
        return paletteOcean(t);
    } else {
        return paletteHSV(t);
    }
}

inline float lerpf(float a, float b, float t) { return a + (b - a) * t; }

inline float saturate(float x) { return clamp(x, 0.0f, 1.0f); }

// ---------- kernel ----------

kernel void mandelbrotKernel(
    constant MandelbrotUniforms& u        [[buffer(0)]],
    texture2d<float, access::write> outTex [[texture(0)]],
    texture2d<float, access::sample> lut   [[texture(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= u.size.x || gid.y >= u.size.y) return;

    // Map pixel -> complex plane (supports Hi/Lo splits if deepMode != 0)
    float2 p = float2((float)gid.x, (float)gid.y);
    float2 c;
    if (u.deepMode != 0) {
        float2 cHi = u.originHi + u.stepHi * p;
        float2 cLo = u.originLo + u.stepLo * p;
        c = cHi + cLo;   // simple compensated add (cheap, helpful at deep zoom)
    } else {
        c = u.origin + u.step * p;
    }

    // Iterate
    float2 z = float2(0.0, 0.0);
    int i = 0;
    const int maxIt = max(1, u.maxIt);

    // fast escape loop
    for (; i < maxIt; ++i) {
        // z = z^2 + c
        float x = z.x, y = z.y;
        float xx = x*x - y*y + c.x;
        float yy = 2.0f*x*y + c.y;
        z = float2(xx, yy);

        if (dot(z, z) > 4.0f) break;
    }

    float3 rgb;
    if (i >= maxIt) {
        // interior: solid black (or tweakable)
        rgb = float3(0.0, 0.0, 0.0);
    } else {
        // ---- Smooth (continuous) coloring: blended for stability + punch ----
        float r2 = dot(z, z);
        r2 = max(r2, 1.0f + 1e-12f); // guard
        float nu = (float)i + 1.0f - log2(max(1e-12f, log(sqrt(r2))));

        // Two normalizations
        float tRaw  = clamp(nu / (float)maxIt, 0.0f, 1.0f);

        // Adaptive k: lower at small maxIt, higher at large maxIt (6..14 range)
        float k     = lerpf(6.0f, 14.0f, clamp(((float)maxIt - 500.0f) / 4500.0f, 0.0f, 1.0f));
        float tComp = clamp(nu / (nu + k), 0.0f, 1.0f);

        // Blend: lean more toward raw for punch, keep stability from tComp
        float t = lerpf(tComp, tRaw, 0.80f);

        // Mild contrast stretch (avoid clipping, lift mids)
        t = clamp((t - 0.02f) / 0.96f, 0.0f, 1.0f);

        // Slightly stronger gamma for vibrance in mid‑tones
        t = pow(t, 0.90f);

        // Subtle palette cycling so color varies more with detail
        const float cycles = 1.50f;
        float tColor = fractf(t * cycles);

        // Sample palette (built‑ins or LUT)
        constexpr sampler s(address::clamp_to_edge, filter::linear);
        rgb = pickColor(u.palette, tColor, lut, s);
    }

    outTex.write(float4(rgb, 1.0), gid);
}
