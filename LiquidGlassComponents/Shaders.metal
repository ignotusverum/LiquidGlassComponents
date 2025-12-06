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

struct BlobUniforms {
    float2 position;
    float  radius;
    float  intensity;
};

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
 Calculates signed distance to a blob (circle).
 @param pixelPos Current pixel position
 @param blob Blob uniforms containing position, radius, intensity
 @return Signed distance to blob edge
 */
float calculateBlobSdf(float2 pixelPos, constant BlobUniforms &blob) {
    if (blob.radius <= 0.0) return 10000.0;
    return length(pixelPos - blob.position) - blob.radius;
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

    // Gaussian weights: approximate e^(-x²/2σ²), sum = 1.0
    const int kSamples = 5;
    float weights[5] = { 0.1, 0.2, 0.4, 0.2, 0.1 };
    float3 color = float3(0.0);

    for (int i = 0; i < kSamples; i++) {
        float offset = (float(i) - 2.0) * smearAmount;
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

// MARK: - Blob Effects

/**
 Calculates specular highlights for a blob using Phong-like model.
 @param pixelPos Current pixel position
 @param blob Blob uniforms
 @param specular Output: accumulated specular intensity
 @return RGB color contribution from this blob
 @note Uses layered specular with different exponents for varied shine.
       Phong model: I = ks × (R·V)^n. Higher n = tighter highlights.
 */
float3 calculateBlobSpecular(float2 pixelPos, constant BlobUniforms &blob, thread float &specular) {
    if (blob.radius <= 0.0) return float3(0.0);

    float d = length(pixelPos - blob.position) / blob.radius;
    float glow = saturate(1.0 - d);

    specular += pow(glow, 2.0) * blob.intensity * 0.5;
    specular += pow(glow, 4.0) * blob.intensity * 0.8;

    float3 color = float3(1.0) * pow(glow, 3.0) * 0.6;

    float rim = smoothstep(0.7, 1.0, glow) * smoothstep(1.0, 0.85, glow);
    color += float3(1.0) * rim * 0.4;

    return color;
}

/**
 Applies blob fill tint to color.
 @param color Input color
 @param blobSdf Distance to blob
 @return Tinted color
 @note Uses smoothstep for Hermite interpolation: 3t² - 2t³
 */
float3 applyBlobFill(float3 color, float blobSdf) {
    float fill = smoothstep(30.0, -10.0, blobSdf);
    return mix(color, color + float3(0.15, 0.15, 0.2), fill * 0.4);
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
    constant BlobUniforms &blob1 [[buffer(1)]],
    constant BlobUniforms &blob2 [[buffer(2)]]
) {
    const float kSmearStrength = 8.0;
    const float kChromaticStrength = 4.0;
    const float kRefractionMultiplier = 18.0;
    const float kPaddingAmount = 0.08;

    float2 pixelPos = in.texCoord * glass.viewSize;
    float2 uv = in.texCoord;

    // Glass shape
    float2 glassCenter = glass.glassOrigin + glass.glassSize * 0.5;
    float2 relativePos = pixelPos - glassCenter;
    float2 halfSize = glass.glassSize * 0.5;
    float glassSdf = sdRoundedRect(relativePos, halfSize, glass.cornerRadius);

    // Early discard
    if (glassSdf > 1.0) discard_fragment();
    float alpha = saturate(-glassSdf * 32.0);
    if (alpha <= 0.0) discard_fragment();

    // Blob SDFs
    float blob1Sdf = calculateBlobSdf(pixelPos, blob1);
    float blob2Sdf = calculateBlobSdf(pixelPos, blob2);
    float blendK = max(min(blob1.radius, blob2.radius) * 0.8, 20.0);
    float blobSdf = smin(blob1Sdf, blob2Sdf, blendK);

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

    // Blob effects
    color = applyBlobFill(color, blobSdf);
    float specular = 0.0;
    color += calculateBlobSpecular(pixelPos, blob1, specular);
    color += calculateBlobSpecular(pixelPos, blob2, specular);
    color += specular * glass.specularIntensity * 0.6;

    return float4(color, alpha);
}
