#include <metal_stdlib>
using namespace metal;

// MARK: - Data Structures

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

struct GlassUniforms {
    float2 viewSize;
    float2 glassOrigin;
    float2 glassSize;
    float  cornerRadius;
    float  refractionStrength;
    float  specularIntensity;
};

struct SdfUniforms {
    float2 position;
    float2 size;      // half-width, half-height (for pill shape)
    float  intensity;
    float  _padding;  // alignment
};

struct TabUniforms {
    float2 positions[8];  // Up to 8 tab center positions
    int    count;
    int    selectedIndex;
    float  fillRadius;
    float  fillOpacity;
};

// MARK: - Glass Effect Constants (percentages of blob size)

namespace GlassEffects {
    constant float smearPercent = 0.04;           // 4% of blob height
    constant float chromaticPercent = 0.02;       // 2% of blob height
    constant float refractionMultiplier = 12.0;   // Refraction strength multiplier
    constant float paddingPercent = 0.08;         // 8% edge padding
}

// MARK: - SDF Functions

/**
 Calculates signed distance to a rounded rectangle.
 @param pos Position relative to rectangle center
 @param halfSize Half-width and half-height of rectangle
 @param radius Corner radius
 @return Signed distance (negative inside, positive outside)
 @note Uses standard box SDF with corner rounding.
 @see https://iquilezles.org/articles/distfunctions2d/
 */
float sdRoundedRect(float2 pos, float2 halfSize, float radius) {
    radius = min(radius, min(halfSize.x, halfSize.y));
    float2 q = abs(pos) - halfSize + radius;
    return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - radius;
}

/**
 Polynomial smooth minimum for blending shapes.
 @param a First distance value
 @param b Second distance value
 @param k Blend radius (larger = smoother transition)
 @return Smoothly blended minimum
 @note Creates organic transitions instead of hard intersections.
 @see https://iquilezles.org/articles/smin/
 */
float smin(float a, float b, float k) {
    float h = saturate(0.5 + 0.5 * (b - a) / k);
    return mix(b, a, h) - k * h * (1.0 - h);
}

/**
 Calculates signed distance to a superellipse (squircle).
 @param pos Position relative to squircle center
 @param size Half-width and half-height of squircle
 @param n Superellipse exponent (4-5 for iOS-style squircle)
 @return Signed distance (negative inside, positive outside)
 @note Formula: |x/a|^n + |y/b|^n = 1
       n=2 is ellipse, n=4-5 is squircle, n->infinity is rectangle
 */
float sdSquircle(float2 pos, float2 size, float n) {
    float2 d = abs(pos) / size;
    float dist = pow(pow(d.x, n) + pow(d.y, n), 1.0 / n);
    // Convert to signed distance (approximate)
    float interior = dist - 1.0;
    // Scale by minimum axis for proper distance metric
    return interior * min(size.x, size.y);
}

/**
 Calculates signed distance to an SDF shape (pill/rounded rect).
 @param pixelPos Current pixel position
 @param sdf SDF uniforms containing position, size, intensity
 @return Signed distance to shape edge
 @note Uses rounded rect with cornerRadius = height/2 for pill shape
 */
float calculateSdf(float2 pixelPos, constant SdfUniforms &sdf) {
    if (sdf.size.y <= 0.0) return 10000.0;
    float2 pos = pixelPos - sdf.position;
    // Pill shape: corner radius = half-height
    float cornerRadius = sdf.size.y;
    return sdRoundedRect(pos, sdf.size, cornerRadius);
}

// MARK: - Refraction

/**
 Applies Snell's Law to calculate refracted angle.
 @param sinTheta1 Sine of incident angle
 @param n1 Refractive index of first medium (air ≈ 1.0)
 @param n2 Refractive index of second medium (glass ≈ 1.5)
 @return Sine of refracted angle
 @note Snell's Law: n1 × sin(θ1) = n2 × sin(θ2)
 */
float snellRefract(float sinTheta1, float n1, float n2) {
    float ratio = n1 / n2;
    float sinTheta2 = ratio * sinTheta1;
    return clamp(sinTheta2, -1.0, 1.0);
}

/**
 Calculates refracted UV coordinates using Snell's Law.
 @param uv Original texture coordinates
 @param towardEdgeDir Normalized direction toward nearest edge
 @param viewSize Viewport dimensions in pixels
 @param proximity Edge proximity (0 = center, 1 = edge)
 @param refractionStrength Base refraction strength from uniforms
 @param refractionMultiplier Multiplier for refraction effect
 @param paddingAmount How much to push content inward at edges
 @return Refracted UV coordinates
 @note Simulates how light bends when entering glass.
       Refractive indices: air ≈ 1.0, glass ≈ 1.5, water ≈ 1.33, diamond ≈ 2.4
 */
float2 calculateRefractedUV(
    float2 uv,
    float2 towardEdgeDir,
    float2 viewSize,
    float proximity,
    float refractionStrength,
    float refractionMultiplier,
    float paddingAmount
) {
    const float kAirRefractiveIndex = 1.0;
    const float kGlassRefractiveIndex = 1.5;

    float easedProximity = pow(proximity, 0.6);
    float incidentAngle = proximity * 1.4;
    float sinTheta1 = sin(incidentAngle);
    float sinTheta2 = snellRefract(sinTheta1, kAirRefractiveIndex, kGlassRefractiveIndex);
    float theta2 = asin(sinTheta2);
    float bendAmount = incidentAngle - theta2;

    float strength = bendAmount * refractionStrength * refractionMultiplier * easedProximity;
    float2 refractedUV = uv - (towardEdgeDir / viewSize) * strength;
    refractedUV -= (towardEdgeDir / viewSize) * paddingAmount * easedProximity;

    return refractedUV;
}

// MARK: - Chromatic Aberration & Smear

/**
 Samples texture with chromatic aberration and directional blur.
 @param tex Source texture
 @param s Texture sampler
 @param baseUV Base UV coordinates after refraction
 @param towardEdgeDir Direction toward edge for chromatic offset
 @param tangentDir Direction along edge for smear blur
 @param viewSize Viewport dimensions
 @param chromaticAmount Chromatic aberration strength in pixels
 @param smearAmount Directional blur strength in pixels
 @return Sampled color with effects applied
 @note Chromatic aberration (dispersion) occurs because different
       wavelengths refract at different angles.
       Cauchy's equation: n(λ) = A + B/λ²
       Red light bends less, blue light bends more.
 */
float3 sampleWithChromaticAberration(
    texture2d<float> tex,
    sampler s,
    float2 baseUV,
    float2 towardEdgeDir,
    float2 tangentDir,
    float2 viewSize,
    float chromaticAmount,
    float smearAmount
) {
    float2 chromaticOffset = towardEdgeDir * chromaticAmount / viewSize;
    float2 redUV = baseUV + chromaticOffset;
    float2 greenUV = baseUV;
    float2 blueUV = baseUV - chromaticOffset;

    // Gaussian weights: e^(-x²/2σ²) with σ=2.0, sum = 1.0
    const int kSamples = 9;
    float weights[9] = { 0.028, 0.066, 0.121, 0.176, 0.199, 0.176, 0.121, 0.066, 0.028 };
    float3 color = float3(0.0);

    for (int i = 0; i < kSamples; i++) {
        float offset = (float(i) - 4.0) * smearAmount * 0.5;  // tighter spacing
        float2 smearOffset = tangentDir * offset / viewSize;

        float2 rUV = clamp(redUV + smearOffset, 0.001, 0.999);
        float2 gUV = clamp(greenUV + smearOffset, 0.001, 0.999);
        float2 bUV = clamp(blueUV + smearOffset, 0.001, 0.999);

        float r = tex.sample(s, rUV).r;
        float g = tex.sample(s, gUV).g;
        float b = tex.sample(s, bUV).b;

        color += float3(r, g, b) * weights[i];
    }

    return color;
}

// MARK: - SDF Effects

/**
 Calculates specular highlights for an SDF shape using Phong-like model.
 @param pixelPos Current pixel position
 @param sdfShape SDF uniforms
 @param specular Output: accumulated specular intensity
 @return RGB color contribution from this shape
 @note Uses layered specular with different exponents for varied shine.
       Phong model: I = ks × (R·V)^n. Higher n = tighter highlights.
       Enhanced for pill shape with bolder visibility.
 */
float3 calculateSdfSpecular(float2 pixelPos, constant SdfUniforms &sdfShape, thread float &specular) {
    if (sdfShape.size.y <= 0.0) return float3(0.0);

    // Use rounded rect SDF for pill shape
    float2 pos = pixelPos - sdfShape.position;
    float cornerRadius = sdfShape.size.y;
    float sdf = sdRoundedRect(pos, sdfShape.size, cornerRadius);
    float normalizedDist = sdf / min(sdfShape.size.x, sdfShape.size.y);
    float glow = saturate(1.0 - normalizedDist - 1.0);

    // Enhanced specular layers for bolder appearance
    specular += pow(glow, 1.5) * sdfShape.intensity * 0.7;
    specular += pow(glow, 3.0) * sdfShape.intensity * 1.0;

    float3 color = float3(1.0) * pow(glow, 2.0) * 0.8;

    // Sharper rim highlight for pill edges
    float rim = smoothstep(0.6, 0.9, glow) * smoothstep(1.0, 0.8, glow);
    color += float3(1.0) * rim * 0.6;

    return color;
}

/**
 Applies SDF fill tint to color for bold visibility.
 @param color Input color
 @param sdfDist Distance to SDF shape
 @return Tinted color
 @note Uses smoothstep for Hermite interpolation: 3t² - 2t³
       Enhanced for bolder appearance with sharper transition.
 */
float3 applySdfFill(float3 color, float sdfDist) {
    // Sharper transition for more defined edge
    float fill = smoothstep(10.0, -5.0, sdfDist);
    // Stronger tint for bold visibility
    float3 tint = float3(0.2, 0.2, 0.3);
    return mix(color, color + tint, fill * 0.5);
}

/**
 Applies solid fill for unselected tabs.
 @param color Input color
 @param pixelPos Current pixel position
 @param tabs Tab uniforms with positions and fill settings
 @return Color with unselected tab fills applied
 */
float3 applyUnselectedFills(float3 color, float2 pixelPos, constant TabUniforms &tabs) {
    for (int i = 0; i < tabs.count && i < 8; i++) {
        // Skip selected tab (it has the blob)
        if (i == tabs.selectedIndex) continue;

        float2 pos = pixelPos - tabs.positions[i];
        float sdf = sdSquircle(pos, float2(tabs.fillRadius), 4.0);

        // Soft fill for unselected tabs
        float fill = smoothstep(5.0, -10.0, sdf);
        // Gray tint for unselected tabs
        color = mix(color, color + float3(0.1), fill * tabs.fillOpacity);
    }
    return color;
}

// MARK: - Edge Effects

/**
 Calculates Fresnel highlights and edge effects.
 @param glassSdf Signed distance to glass edge
 @param easedProximity Eased edge proximity value
 @return RGB color contribution from edge effects
 @note Fresnel effect causes increased reflectivity at grazing angles.
       Schlick's approximation: F(θ) = F0 + (1-F0)(1-cosθ)^5
       F0 ≈ 0.04 for glass, ≈ 0.02 for water.
 */
float3 calculateEdgeEffects(float glassSdf, float easedProximity) {
    float3 effects = float3(0.0);

    // Fresnel highlight
    float fresnel = pow(easedProximity, 2.5) * 0.15;
    effects += float3(1.0) * fresnel;

    // Edge highlight
    float edgeMask = smoothstep(6.0, 0.0, abs(glassSdf));
    effects += float3(1.0) * edgeMask * 0.15;

    // Border
    float border = smoothstep(2.0, 0.0, abs(glassSdf)) - smoothstep(1.0, 0.0, abs(glassSdf));
    effects += float3(1.0) * border * 0.5;

    return effects;
}

// MARK: - Vertex Shader

vertex VertexOut liquidGlassVertex(uint vertexID [[vertex_id]]) {
    float2 positions[4] = {
        float2(-1.0, -1.0), float2(1.0, -1.0),
        float2(-1.0,  1.0), float2(1.0,  1.0)
    };
    float2 texCoords[4] = {
        float2(0.0, 1.0), float2(1.0, 1.0),
        float2(0.0, 0.0), float2(1.0, 0.0)
    };

    VertexOut out;
    out.position = float4(positions[vertexID], 0.0, 1.0);
    out.texCoord = texCoords[vertexID];
    return out;
}

// MARK: - Fragment Shader

fragment float4 liquidGlassTabBarFragment(
    VertexOut in [[stage_in]],
    texture2d<float> backdropTexture [[texture(0)]],
    sampler linearSampler [[sampler(0)]],
    constant GlassUniforms &glass [[buffer(0)]],
    constant SdfUniforms &sdf1 [[buffer(1)]],
    constant SdfUniforms &sdf2 [[buffer(2)]],
    constant TabUniforms &tabs [[buffer(3)]]
) {
    // Calculate effect strengths from percentages (relative to blob height)
    const float kSmearStrength = GlassEffects::smearPercent * glass.glassSize.y;
    const float kChromaticStrength = GlassEffects::chromaticPercent * glass.glassSize.y;
    const float kRefractionMultiplier = GlassEffects::refractionMultiplier;
    const float kPaddingAmount = GlassEffects::paddingPercent;

    float2 pixelPos = in.texCoord * glass.viewSize;
    float2 uv = in.texCoord;

    // Glass shape
    float2 glassCenter = glass.glassOrigin + glass.glassSize * 0.5;
    float2 relativePos = pixelPos - glassCenter;
    float2 halfSize = glass.glassSize * 0.5;
    float glassSdf = sdRoundedRect(relativePos, halfSize, glass.cornerRadius);

    // Check if SDF effects are enabled (non-zero size)
    bool sdfEnabled = sdf1.size.y > 0.0 || sdf2.size.y > 0.0;

    float sdfDist = 10000.0;  // Far away by default (disabled)
    if (sdfEnabled) {
        float sdf1Dist = calculateSdf(pixelPos, sdf1);
        float sdf2Dist = calculateSdf(pixelPos, sdf2);
        float blendK = max(min(sdf1.size.y, sdf2.size.y) * 0.8, 20.0);
        sdfDist = smin(sdf1Dist, sdf2Dist, blendK);
    }

    // Check regions
    bool insideGlass = glassSdf < 1.0;
    bool insideSdf = sdfEnabled && sdfDist < 0.0;

    // Discard if outside glass (and outside SDF if enabled)
    if (!insideGlass && !insideSdf) {
        discard_fragment();
    }

    // Handle SDF overflow region (outside glass, inside SDF)
    if (!insideGlass && insideSdf) {
        float3 color = backdropTexture.sample(linearSampler, uv).rgb;
        color = applySdfFill(color, sdfDist);
        float specular = 0.0;
        color += calculateSdfSpecular(pixelPos, sdf1, specular);
        color += calculateSdfSpecular(pixelPos, sdf2, specular);
        color += specular * glass.specularIntensity * 0.6;
        float sdfAlpha = saturate(-sdfDist * 8.0);
        return float4(color, sdfAlpha);
    }

    // Normal glass rendering (inside glass bounds)
    float alpha = saturate(-glassSdf * 32.0);
    if (alpha <= 0.0) discard_fragment();

    // Edge proximity (1 at edge, 0 toward center)
    float distFromEdge = -glassSdf;
    float maxDist = min(halfSize.x, halfSize.y);
    float refractionZoneWidth = maxDist * 0.55;
    float proximity = 1.0 - saturate(distFromEdge / refractionZoneWidth);
    float easedProximity = pow(proximity, 0.6);

    // Direction vectors
    float2 towardEdgeDir = normalize(relativePos + 0.001);
    float2 tangentDir = float2(-towardEdgeDir.y, towardEdgeDir.x);

    // Refracted UV
    float2 refractedUV = calculateRefractedUV(
        uv, towardEdgeDir, glass.viewSize,
        proximity, glass.refractionStrength,
        kRefractionMultiplier, kPaddingAmount
    );

    // Sample with chromatic aberration and smear
    float chromatic = easedProximity * kChromaticStrength;
    float smear = easedProximity * kSmearStrength;
    float3 color = sampleWithChromaticAberration(
        backdropTexture, linearSampler,
        refractedUV, towardEdgeDir, tangentDir,
        glass.viewSize, chromatic, smear
    );

    // Edge effects
    color += calculateEdgeEffects(glassSdf, easedProximity);

    // Only apply SDF and tab effects if enabled
    if (sdfEnabled) {
        color = applyUnselectedFills(color, pixelPos, tabs);
        color = applySdfFill(color, sdfDist);
        float specular = 0.0;
        color += calculateSdfSpecular(pixelPos, sdf1, specular);
        color += calculateSdfSpecular(pixelPos, sdf2, specular);
        color += specular * glass.specularIntensity * 0.6;
    }

    return float4(color, alpha);
}

// MARK: - SDF Container Fragment Shader

/**
 Standalone SDF container shader - renders SDF shapes without glass refraction.
 Use this for container components that need SDF highlight effects.
 */
fragment float4 liquidGlassSdfFragment(
    VertexOut in [[stage_in]],
    texture2d<float> backdropTexture [[texture(0)]],
    sampler linearSampler [[sampler(0)]],
    constant GlassUniforms &glass [[buffer(0)]],
    constant SdfUniforms &sdf1 [[buffer(1)]],
    constant SdfUniforms &sdf2 [[buffer(2)]]
) {
    float2 pixelPos = in.texCoord * glass.viewSize;
    float2 uv = in.texCoord;

    // Calculate SDF distances
    float sdf1Dist = calculateSdf(pixelPos, sdf1);
    float sdf2Dist = calculateSdf(pixelPos, sdf2);
    float blendK = max(min(sdf1.size.y, sdf2.size.y) * 0.8, 20.0);
    float sdfDist = smin(sdf1Dist, sdf2Dist, blendK);

    // Discard if outside SDF
    if (sdfDist >= 0.0) {
        discard_fragment();
    }

    // Sample backdrop
    float3 color = backdropTexture.sample(linearSampler, uv).rgb;

    // Apply SDF fill and specular
    color = applySdfFill(color, sdfDist);
    float specular = 0.0;
    color += calculateSdfSpecular(pixelPos, sdf1, specular);
    color += calculateSdfSpecular(pixelPos, sdf2, specular);
    color += specular * glass.specularIntensity * 0.6;

    // SDF alpha based on distance (soft edge)
    float sdfAlpha = saturate(-sdfDist * 8.0);
    return float4(color, sdfAlpha);
}
