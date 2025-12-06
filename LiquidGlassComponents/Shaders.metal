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

// Schlick's Fresnel approximation
float fresnelSchlick(float cosTheta, float F0) {
    return F0 + (1.0 - F0) * pow(1.0 - cosTheta, 5.0);
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
    float reflectionZoneWidth = maxDist * 0.50;  // 50% - Fresnel reflection zone (was 25%)
    float darkBevelWidth = maxDist * 0.045;       // 8% - dark padding

    // Proximity values (1 at edge, 0 toward center)
    float refractionProximity = 1.0 - saturate(distFromEdge / refractionZoneWidth);
    float edgeProximity = 1.0 - saturate(distFromEdge / reflectionZoneWidth);
    float bevelZone = 1.0 - saturate(distFromEdge / darkBevelWidth);

    // Direction toward edge
    float2 towardEdgePixel = normalize(relativePos + 0.001);
    float2 towardEdgeUV = towardEdgePixel / glass.viewSize;

    // === SNELL'S LAW REFRACTION (with smooth easing) ===
    float n1 = 1.0;  // Air
    float n2 = 1.5;  // Glass

    // Eased proximity - strongest at edge, smooth falloff toward center
    float easedProximity = pow(refractionProximity, 0.6);

    float incidentAngle = refractionProximity * 1.4;
    float sinTheta1 = sin(incidentAngle);
    float sinTheta2 = snellRefract(sinTheta1, n1, n2);
    float theta2 = asin(sinTheta2);
    float bendAmount = incidentAngle - theta2;

    // Apply easing to refraction strength for smooth transition
    float refractionStrength = bendAmount * glass.refractionStrength * 25.0 * easedProximity;
    float2 refractedUV = uv - towardEdgeUV * refractionStrength;

    // === EDGE PADDING (content pushed inward, eased) ===
    float paddingAmount = easedProximity * 0.10;
    refractedUV -= towardEdgeUV * paddingAmount;

    refractedUV = clamp(refractedUV, 0.001, 0.999);

    float4 color = backdropTexture.sample(linearSampler, refractedUV);

    // === FRESNEL REFLECTION - EDGE MIRROR ===
    if (edgeProximity > 0.01) {
        float cosTheta = 1.0 - edgeProximity;
        float F0 = 0.28;  // Slightly higher base reflectance
        float fresnel = fresnelSchlick(cosTheta, F0);

        // Sample from a position reflected across the edge
        float2 reflectionUV = uv;

        // Offset amount - how far "past the edge" to sample (simulates mirror)
        float offsetAmount = edgeProximity * 0.45;  // Slightly stronger

        if (abs(towardEdgePixel.x) > abs(towardEdgePixel.y)) {
            // Near LEFT or RIGHT edge
            if (towardEdgePixel.x > 0.0) {
                // RIGHT edge: flip and offset from right
                reflectionUV.x = 1.0 + (1.0 - uv.x) * offsetAmount;
            } else {
                // LEFT edge: flip and offset from left
                reflectionUV.x = -uv.x * offsetAmount;
            }
        } else {
            // Near TOP or BOTTOM edge
            if (towardEdgePixel.y > 0.0) {
                // BOTTOM edge: flip and offset from bottom
                reflectionUV.y = 1.0 + (1.0 - uv.y) * offsetAmount;
            } else {
                // TOP edge: flip and offset from top
                reflectionUV.y = -uv.y * offsetAmount;
            }
        }

        // Clamp and use mirror-style sampling (abs to fold back into texture)
        reflectionUV.x = abs(reflectionUV.x);
        reflectionUV.y = abs(reflectionUV.y);
        if (reflectionUV.x > 1.0) reflectionUV.x = 2.0 - reflectionUV.x;
        if (reflectionUV.y > 1.0) reflectionUV.y = 2.0 - reflectionUV.y;
        reflectionUV = clamp(reflectionUV, 0.001, 0.999);

        float4 mirroredColor = backdropTexture.sample(linearSampler, reflectionUV);

        // Subtle reflection at grazing angles (edges)
        float reflectionStrength = fresnel * pow(edgeProximity, 0.65) * 0.75;
        color.rgb = mix(color.rgb, mirroredColor.rgb, reflectionStrength);

        // Subtle specular highlight
        color.rgb += fresnel * edgeProximity * 0.10;
    }

    // === DARK BEVEL (entry refraction darkening) ===
    color.rgb *= (1.0 - pow(bevelZone, 1.3) * 0.55);

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
