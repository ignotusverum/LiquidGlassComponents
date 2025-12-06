#include <metal_stdlib>
using namespace metal;

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

// SDF for rounded rectangle
float sdRoundedRect(float2 pos, float2 halfSize, float radius) {
    radius = min(radius, min(halfSize.x, halfSize.y));
    float2 q = abs(pos) - halfSize + radius;
    return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - radius;
}

// Smooth min for blob merging
float smin(float a, float b, float k) {
    float h = saturate(0.5 + 0.5 * (b - a) / k);
    return mix(b, a, h) - k * h * (1.0 - h);
}

// Snell's Law refraction
float snellRefract(float sinTheta1, float n1, float n2) {
    float ratio = n1 / n2;
    float sinTheta2 = ratio * sinTheta1;
    return clamp(sinTheta2, -1.0, 1.0);
}

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

fragment float4 liquidGlassTabBarFragment(
    VertexOut in [[stage_in]],
    texture2d<float> backdropTexture [[texture(0)]],
    sampler linearSampler [[sampler(0)]],
    constant GlassUniforms &glass [[buffer(0)]],
    constant BlobUniforms &blob1 [[buffer(1)]],
    constant BlobUniforms &blob2 [[buffer(2)]]
) {
    // ==========================================================================
    // TUNABLE PARAMETERS
    // ==========================================================================
    const float SMEAR_STRENGTH = 8.0;          // Edge blur/smear intensity (pixels)
    const float CHROMATIC_STRENGTH = 4.0;      // Rainbow separation amount (pixels)
    const float REFRACTION_MULTIPLIER = 18.0;  // Overall refraction strength
    const float PADDING_AMOUNT = 0.08;         // Content pushed inward at edges

    float2 pixelPos = in.texCoord * glass.viewSize;
    float2 uv = in.texCoord;

    // Glass shape
    float2 glassCenter = glass.glassOrigin + glass.glassSize * 0.5;
    float2 relativePos = pixelPos - glassCenter;
    float2 halfSize = glass.glassSize * 0.5;
    float glassSdf = sdRoundedRect(relativePos, halfSize, glass.cornerRadius);

    // Blob SDFs
    float blob1Sdf = (blob1.radius > 0.0)
        ? length(pixelPos - blob1.position) - blob1.radius
        : 10000.0;
    float blob2Sdf = (blob2.radius > 0.0)
        ? length(pixelPos - blob2.position) - blob2.radius
        : 10000.0;

    float blendK = max(min(blob1.radius, blob2.radius) * 0.8, 20.0);
    float blobSdf = smin(blob1Sdf, blob2Sdf, blendK);

    // Discard outside glass
    if (glassSdf > 1.0) {
        discard_fragment();
    }

    // Anti-aliased alpha
    float alpha = saturate(-glassSdf * 32.0);
    if (alpha <= 0.0) {
        discard_fragment();
    }

    // Distance from edge (positive inside glass)
    float distFromEdge = -glassSdf;
    float maxDist = min(halfSize.x, halfSize.y);

    // Zone widths
    float refractionZoneWidth = maxDist * 0.55;

    // Proximity values (1 at edge, 0 toward center)
    float refractionProximity = 1.0 - saturate(distFromEdge / refractionZoneWidth);

    // Direction toward edge (normalized, pixel space)
    float2 towardEdgeDir = normalize(relativePos + 0.001);

    // Perpendicular direction (for smear along edge, pixel space)
    float2 tangentDir = float2(-towardEdgeDir.y, towardEdgeDir.x);

    // === SNELL'S LAW REFRACTION ===
    float n1 = 1.0;  // Air
    float n2 = 1.5;  // Glass

    float easedProximity = pow(refractionProximity, 0.6);

    float incidentAngle = refractionProximity * 1.4;
    float sinTheta1 = sin(incidentAngle);
    float sinTheta2 = snellRefract(sinTheta1, n1, n2);
    float theta2 = asin(sinTheta2);
    float bendAmount = incidentAngle - theta2;

    float refractionStrength = bendAmount * glass.refractionStrength * REFRACTION_MULTIPLIER * easedProximity;
    float2 baseRefractedUV = uv - (towardEdgeDir / glass.viewSize) * refractionStrength;

    // === EDGE PADDING ===
    baseRefractedUV -= (towardEdgeDir / glass.viewSize) * PADDING_AMOUNT * easedProximity;

    // ==========================================================================
    // CHROMATIC ABERRATION (Rainbow effect)
    // Different wavelengths refract at different angles through glass
    // Red bends least, Blue bends most (dispersion)
    // ==========================================================================
    float chromatic = easedProximity * CHROMATIC_STRENGTH;

    // Offset each channel differently - scale by viewSize for proper pixel offset
    float2 chromaticOffset = towardEdgeDir * chromatic / glass.viewSize;
    float2 redUV   = baseRefractedUV + chromaticOffset;
    float2 greenUV = baseRefractedUV;
    float2 blueUV  = baseRefractedUV - chromaticOffset;

    // ==========================================================================
    // EDGE SMEAR / DIRECTIONAL BLUR
    // Content gets stretched along the edge at steep angles
    // ==========================================================================
    float smearAmount = easedProximity * SMEAR_STRENGTH;

    // Sample multiple times along tangent direction and average
    float3 finalColor = float3(0.0);

    // 5-tap blur along edge tangent + chromatic aberration
    const int SAMPLES = 5;
    float weights[5] = { 0.1, 0.2, 0.4, 0.2, 0.1 };  // Gaussian-ish weights

    for (int i = 0; i < SAMPLES; i++) {
        float offset = (float(i) - 2.0) * smearAmount;  // -2, -1, 0, 1, 2
        float2 smearOffset = tangentDir * offset / glass.viewSize;

        // Sample each color channel at its chromatic offset + smear offset
        float2 rUV = clamp(redUV   + smearOffset, 0.001, 0.999);
        float2 gUV = clamp(greenUV + smearOffset, 0.001, 0.999);
        float2 bUV = clamp(blueUV  + smearOffset, 0.001, 0.999);

        float r = backdropTexture.sample(linearSampler, rUV).r;
        float g = backdropTexture.sample(linearSampler, gUV).g;
        float b = backdropTexture.sample(linearSampler, bUV).b;

        finalColor += float3(r, g, b) * weights[i];
    }

    float4 color = float4(finalColor, 1.0);

    // ==========================================================================
    // FRESNEL WHITE HIGHLIGHT at edges
    // ==========================================================================
    float fresnelHighlight = pow(easedProximity, 2.5) * 0.15;
    color.rgb += float3(1.0) * fresnelHighlight;

    // === BLOB FILL ===
    float blobFill = smoothstep(30.0, -10.0, blobSdf);
    color.rgb = mix(color.rgb, color.rgb + float3(0.15, 0.15, 0.2), blobFill * 0.4);

    // === SPECULAR HIGHLIGHTS ===
    float specular = 0.0;

    if (blob1.radius > 0.0) {
        float d1 = length(pixelPos - blob1.position) / blob1.radius;
        float blob1Glow = saturate(1.0 - d1);

        specular += pow(blob1Glow, 2.0) * blob1.intensity * 0.5;
        specular += pow(blob1Glow, 4.0) * blob1.intensity * 0.8;
        color.rgb += float3(1.0) * pow(blob1Glow, 3.0) * 0.6;

        float rim1 = smoothstep(0.7, 1.0, blob1Glow) * smoothstep(1.0, 0.85, blob1Glow);
        color.rgb += float3(1.0) * rim1 * 0.4;
    }
    if (blob2.radius > 0.0) {
        float d2 = length(pixelPos - blob2.position) / blob2.radius;
        float blob2Glow = saturate(1.0 - d2);

        specular += pow(blob2Glow, 2.0) * blob2.intensity * 0.5;
        specular += pow(blob2Glow, 4.0) * blob2.intensity * 0.8;
        color.rgb += float3(1.0) * pow(blob2Glow, 3.0) * 0.6;

        float rim2 = smoothstep(0.7, 1.0, blob2Glow) * smoothstep(1.0, 0.85, blob2Glow);
        color.rgb += float3(1.0) * rim2 * 0.4;
    }

    color.rgb += specular * glass.specularIntensity * 0.6;

    // === EDGE HIGHLIGHT ===
    float edgeMask = smoothstep(6.0, 0.0, abs(glassSdf));
    color.rgb += float3(1.0) * edgeMask * 0.15;

    // === BORDER ===
    float border = smoothstep(2.0, 0.0, abs(glassSdf)) - smoothstep(1.0, 0.0, abs(glassSdf));
    color.rgb += float3(1.0) * border * 0.5;

    return float4(color.rgb, alpha);
}
