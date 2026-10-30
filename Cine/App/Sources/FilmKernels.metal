// Noyaux Core Image du rendu « Pellicule cinéma ».
// Même formule, mêmes constantes que FilmCore/FilmLook.swift (la version Swift est testée).
// Compilés avec -fcikernel (compilateur) et -cikernel (éditeur de liens) : voir Cine/project.yml.
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
}

extern "C" { namespace coreimage {

    /// Courbe de pellicule, saturation retenue, verts olive, ombres froides, hautes lumières chaudes.
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

    /// Lumière au-dessus du seuil (avec sa couleur) : source des halos.
    float4 glowMask(sample_t s, float threshold, float maxExcess) {
        float3 c = max(s.rgb, float3(0.0));
        float l = film::luma(c);
        float excess = clamp(l - threshold, 0.0, maxExcess);
        return float4(c * (excess / max(l, 1e-4)), 1.0);
    }

    /// Halation (halo serré, rouge orangé) et diffusion (voile large).
    float4 addGlow(sample_t s, sample_t halo, sample_t bloom, float3 haloTint, float haloAmount, float bloomAmount) {
        float3 c = s.rgb + haloTint * (film::luma(halo.rgb) * haloAmount) + bloom.rgb * bloomAmount;
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
}}
