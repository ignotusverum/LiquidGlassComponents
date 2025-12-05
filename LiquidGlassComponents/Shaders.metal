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

/**
 Tab bar glass with dual blob merging

 SIMPLE: No blur loop. Backdrop is pre-blurred by CABackdropLayer.
 Just: distort UV → sample once → add specular → add edges
 */
fragment float4 liquidGlassTabBarFragment(
    VertexOut in [[stage_in]],
    texture2d<float> backdropTexture [[texture(0)]],  // Pre-blurred by CABackdropLayer
    sampler linearSampler [[sampler(0)]],
    constant GlassUniforms &glass [[buffer(0)]],
    constant BlobUniforms &blob1 [[buffer(1)]],
    constant BlobUniforms &blob2 [[buffer(2)]]
) {
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

    // Merge blobs with smin (for blob fill effect)
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

    // === EDGE-ONLY REFRACTION (pixel pulling ONLY at glass borders ~15% from edge) ===
    float2 distortedUV = uv;

    // Define edge zone - only this zone gets distortion
    float edgeZoneWidth = min(glass.glassSize.x, glass.glassSize.y) * 0.15;  // 15% from edge

    // edgeProximity: 1.0 at the very edge, 0.0 when past the edge zone (in center)
    // glassSdf is negative inside, so -glassSdf is positive inside
    // At edge: glassSdf ≈ 0, so edgeProximity ≈ 1
    // At edgeZoneWidth inside: glassSdf ≈ -edgeZoneWidth, so edgeProximity ≈ 0
    float distFromEdge = -glassSdf;  // Distance from edge (positive inside)
    float edgeProximity = 1.0 - saturate(distFromEdge / edgeZoneWidth);  // 1 at edge, 0 in center

    // Dark bevel zone at very edge (creates "padding under angle" effect)
    float darkBevelWidth = min(glass.glassSize.x, glass.glassSize.y) * 0.05;  // 5% dark bevel
    float bevelZone = 1.0 - saturate(distFromEdge / darkBevelWidth);  // 1 at edge, 0 past bevel

    // Direction toward edge in UV space (normalized and scaled properly)
    float2 towardEdgePixel = normalize(relativePos + 0.001);
    float2 towardEdgeUV = towardEdgePixel / glass.viewSize;  // Convert to UV space

    // === REFRACTION DISTORTION (bend content like real glass at edges) ===
    // Pull content from center toward edges (simulates light bending through angled glass)
    float refractionStrength = pow(edgeProximity, 1.5) * glass.refractionStrength * 30.0;  // Pixels
    float2 refractedUV = uv - towardEdgeUV * refractionStrength;  // Pull inward (content shifts outward visually)

    // Sample the distorted backdrop
    float4 color = backdropTexture.sample(linearSampler, refractedUV);

    // === REFLECTION COPY in edge zone (sample from OUTSIDE and blend in) ===
    if (edgeProximity > 0.0) {
        // Sample content from OUTSIDE the glass (further out = stronger reflection)
        float reflectionOffsetPx = edgeProximity * glass.refractionStrength * 50.0;  // Pixels to offset
        float2 reflectionUV = uv + towardEdgeUV * reflectionOffsetPx;
        float4 reflectedColor = backdropTexture.sample(linearSampler, reflectionUV);

        // Blend reflected content into edge zone
        float copyBlend = pow(edgeProximity, 1.3) * 0.5;
        color.rgb = mix(color.rgb, reflectedColor.rgb, copyBlend);
    }

    // Apply dark bevel at very edge (the angled padding effect - creates depth)
    color.rgb *= (1.0 - pow(bevelZone, 1.3) * 0.55);

    // === BLOB FILL (subtle tint inside blob area) ===
    float blobFill = smoothstep(30.0, -10.0, blobSdf);  // Soft edge fill
    color.rgb = mix(color.rgb, color.rgb + float3(0.15, 0.15, 0.2), blobFill * 0.4);  // Subtle blue-white tint

    // === SPECULAR HIGHLIGHTS (blob glow) - MUCH STRONGER ===
    float specular = 0.0;

    if (blob1.radius > 0.0) {
        float d1 = length(pixelPos - blob1.position) / blob1.radius;
        float blob1Glow = saturate(1.0 - d1);

        // Multi-layer glow for more prominence
        specular += pow(blob1Glow, 2.0) * blob1.intensity * 0.5;   // Broad glow
        specular += pow(blob1Glow, 4.0) * blob1.intensity * 0.8;   // Medium glow

        // Bright white highlight at blob center
        color.rgb += float3(1.0) * pow(blob1Glow, 3.0) * 0.6;

        // Rim highlight at blob edge
        float rim1 = smoothstep(0.7, 1.0, blob1Glow) * smoothstep(1.0, 0.85, blob1Glow);
        color.rgb += float3(1.0) * rim1 * 0.4;
    }
    if (blob2.radius > 0.0) {
        float d2 = length(pixelPos - blob2.position) / blob2.radius;
        float blob2Glow = saturate(1.0 - d2);

        // Multi-layer glow for more prominence
        specular += pow(blob2Glow, 2.0) * blob2.intensity * 0.5;
        specular += pow(blob2Glow, 4.0) * blob2.intensity * 0.8;

        // Bright white highlight at blob center
        color.rgb += float3(1.0) * pow(blob2Glow, 3.0) * 0.6;

        // Rim highlight at blob edge
        float rim2 = smoothstep(0.7, 1.0, blob2Glow) * smoothstep(1.0, 0.85, blob2Glow);
        color.rgb += float3(1.0) * rim2 * 0.4;
    }

    // Add specular shine (increased)
    color.rgb += specular * glass.specularIntensity * 0.6;

    // === EDGE HIGHLIGHT (subtle white border glow) ===
    float edgeMask = smoothstep(6.0, 0.0, abs(glassSdf));
    color.rgb += float3(1.0) * edgeMask * 0.15;

    // === BORDER (thin bright line at edge) ===
    float border = smoothstep(2.0, 0.0, abs(glassSdf)) - smoothstep(1.0, 0.0, abs(glassSdf));
    color.rgb += float3(1.0) * border * 0.5;

    // Apply alpha for anti-aliasing at glass edges
    return float4(color.rgb, alpha);
}
