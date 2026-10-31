// Noyaux Core Image de Ciné.
// Mêmes formules, mêmes constantes que FilmCore/FilmLook.swift (la version Swift est testée).
// Compilés avec -fcikernel (compilateur et éditeur de liens) : voir Cine/project.yml.
// Core Image travaille en lumière linéaire (espace de travail : Display P3 linéaire étendu).

#include <metal_stdlib>
#include <CoreImage/CoreImage.h>
using namespace metal;

namespace film {
    inline float luma(float3 c) { return dot(c, float3(0.2126, 0.7152, 0.0722)); }

    inline float toLinear(float v) {
        return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4);
    }

    inline float toDisplay(float v) {
        v = max(v, 0.0);
        return v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1.0 / 2.4) - 0.055;
    }

    inline float3 toLinear3(float3 c) { return float3(toLinear(c.r), toLinear(c.g), toLinear(c.b)); }
    inline float3 toDisplay3(float3 c) { return float3(toDisplay(c.r), toDisplay(c.g), toDisplay(c.b)); }

    /// Courbe de pellicule d'un canal : sigmoïde en stops autour du gris moyen (0,18).
    inline float curve(float linear, float k, float x0, float lift, float white) {
        float x = log2(max(linear, 1e-6) / 0.18);
        float s = 1.0 / (1.0 + exp(-k * (x - x0)));
        return lift + (white - lift) * s;
    }

    /// Luminance « affichage » (pour la mise au point) d'un point de l'image.
    inline float edgeLuma(coreimage::sampler s, float2 p) {
        float4 c = s.sample(s.transform(p));
        return sqrt(max(luma(c.rgb), 0.0));
    }
}

extern "C" { namespace coreimage {

    /// Courbe de pellicule, saturation, verts olive, teintes des ombres et des hautes lumières.
    float4 filmLook(sample_t s, float3 balance, float3 contrast, float3 pivot, float lift, float white,
                    float saturation, float greenShift, float3 shadowTint, float3 highlightTint) {
        float3 c = max(s.rgb, float3(0.0)) * balance;
        float3 y = float3(film::curve(c.r, contrast.r, pivot.r, lift, white),
                          film::curve(c.g, contrast.g, pivot.g, lift, white),
                          film::curve(c.b, contrast.b, pivot.b, lift, white));
        float l = film::luma(y);
        y = float3(l) + (y - float3(l)) * saturation;
        float green = clamp((y.g - max(y.r, y.b)) * 4.0, 0.0, 1.0) * greenShift;
        float3 olive = float3(l + (y.r - l) * 0.8 + 0.015, l + (y.g - l) * 0.75, l + (y.b - l) * 0.7 - 0.01);
        y = y + (olive - y) * green;
        float inv = 1.0 - l;
        y = y + shadowTint * (inv * inv * inv) + highlightTint * (l * l * l);
        y = clamp(y, float3(0.0), float3(1.0));
        return float4(film::toLinear3(y), 1.0);
    }

    /// Lumière au-dessus du seuil (avec sa couleur) : source des effets optiques.
    float4 glowMask(sample_t s, float threshold, float maxExcess) {
        float3 c = max(s.rgb, float3(0.0));
        float l = film::luma(c);
        float excess = clamp(l - threshold, 0.0, maxExcess);
        return float4(c * (excess / max(l, 1e-4)), 1.0);
    }

    /// Halation (halo serré, rouge orangé), diffusion (voile large) et flares anamorphiques (bleutés, compressés).
    float4 addGlow(sample_t s, sample_t halo, sample_t mist, sample_t streak,
                   float3 haloTint, float haloAmount, float mistAmount,
                   float3 streakTint, float streakAmount, float streakGain) {
        float flare = 1.0 - exp(-max(film::luma(streak.rgb) * streakGain, 0.0));
        float3 c = s.rgb + haloTint * (film::luma(halo.rgb) * haloAmount) + mist.rgb * mistAmount
                 + streakTint * (flare * streakAmount);
        return float4(c, 1.0);
    }

    /// Grain (surtout dans les tons moyens) et vignettage, en valeurs d'affichage.
    float4 filmFinish(sample_t s, sample_t noise, float amount, float normalization,
                      float vignette, float2 center, float2 halfSize, destination dest) {
        float3 e = film::toDisplay3(s.rgb);
        float l = clamp(film::luma(e), 0.0, 1.0);
        float n = (noise.r - 0.5) * normalization;
        e = e + n * amount * (0.35 + 2.6 * l * (1.0 - l));
        float2 p = (dest.coord() - center) / halfSize;
        float d = length(p) * 0.70710678;
        float t = clamp((d - 0.45) / 0.55, 0.0, 1.0);
        e = e * (1.0 - vignette * t * t);
        e = clamp(e, float3(0.0), float3(1.0));
        return float4(film::toLinear3(e), 1.0);
    }

    /// Logarithme de la luminance : sa moyenne donne l'exposition « perçue » d'une image.
    float4 logLuminance(sample_t s) {
        float v = log(max(film::luma(max(s.rgb, float3(0.0))), 1e-4));
        return float4(v, v, v, 1.0);
    }

    /// Zébras : rayures là où l'image source (avant le rendu) est presque blanche, c'est-à-dire là où
    /// le capteur sature. La courbe de pellicule arrondit les blancs : on ne peut pas juger sur l'image rendue.
    float4 zebra(sample_t s, sample_t source, float threshold, float period, destination dest) {
        float3 e = film::toDisplay3(s.rgb);
        float2 p = dest.coord();
        float stripe = fract((p.x + p.y) / period);
        if (film::luma(max(source.rgb, float3(0.0))) > threshold && stripe < 0.5) {
            e = mix(e, float3(0.08), 0.75);
        }
        return float4(film::toLinear3(e), 1.0);
    }

    /// Focus peaking : les contours nets de `source` (avant rendu, donc sans grain) colorés sur `image`.
    float4 focusPeaking(coreimage::sampler source, coreimage::sampler image, float threshold, float3 color,
                        coreimage::destination dest) {
        float2 p = dest.coord();
        float tl = film::edgeLuma(source, p + float2(-1.0, 1.0));
        float t = film::edgeLuma(source, p + float2(0.0, 1.0));
        float tr = film::edgeLuma(source, p + float2(1.0, 1.0));
        float l = film::edgeLuma(source, p + float2(-1.0, 0.0));
        float r = film::edgeLuma(source, p + float2(1.0, 0.0));
        float bl = film::edgeLuma(source, p + float2(-1.0, -1.0));
        float b = film::edgeLuma(source, p + float2(0.0, -1.0));
        float br = film::edgeLuma(source, p + float2(1.0, -1.0));
        float gx = (tr + 2.0 * r + br) - (tl + 2.0 * l + bl);
        float gy = (tl + 2.0 * t + tr) - (bl + 2.0 * b + br);
        float magnitude = sqrt(gx * gx + gy * gy);
        float4 c = image.sample(image.transform(p));
        float k = smoothstep(threshold, threshold * 1.4, magnitude) * 0.9;
        return float4(mix(c.rgb, color, k), 1.0);
    }
}}
