#include <metal_stdlib>
using namespace metal;

#include "ShaderTypes.h"

// Vertex output structure (same as Common.metal)
struct VertexOut {
    float4 position [[position]];
    float3 worldPosition;
    float3 worldNormal;
    float2 texCoord;
    float3 viewDirection;
    float4 tangent;
};

// Helper function: Apply UV transform (scale and offset)
// transform: x=scaleX, y=scaleY, z=offsetX, w=offsetY
inline float2 transformUV(float2 uv, float4 transform) {
    return uv * transform.xy + transform.zw;
}


// MARK: - MToon Lighting Functions

float3 calculateMToonShading(
    float3 normal,
    float3 lightDirection,
    float3 viewDirection,
    constant MToonMaterialUniforms& material,
    float4 litColor,
    float4 shadeColor
) {
    // Toon shading with shade shift/toony control
    float dotNL = dot(normal, lightDirection);

    // Apply shade shift and toony
    float shadeThreshold = material.shadeShift;
    float shadeRange = 1.0 - material.shadeToony;

    float shading;
    if (shadeRange > 0.001) {
        shading = smoothstep(shadeThreshold - shadeRange, shadeThreshold + shadeRange, dotNL);
    } else {
        shading = step(shadeThreshold, dotNL);
    }

    // Mix lit and shade colors
    return mix(shadeColor.rgb, litColor.rgb, shading);
}

float3 calculateRimLighting(
    float3 normal,
    float3 viewDirection,
    float shading,
    constant MToonMaterialUniforms& material
) {
    // Fresnel-based rim lighting
    float NdotV = saturate(dot(normal, viewDirection));
    float rim = pow(1.0 - NdotV, material.rimFresnelPower);
    rim = smoothstep(material.rimLift, 1.0, rim);

    float3 rimColor = material.rimColor.rgb * rim;

    // Mix rim with lighting
    return rimColor * mix(1.0, shading, material.rimLightingMix);
}

// MARK: - MToon Fragment Shader

fragment float4 mtoon_fragment(
    VertexOut in [[stage_in]],
    constant MToonMaterialUniforms& material [[buffer(BufferIndexMaterial)]],
    constant LightUniforms& lights [[buffer(BufferIndexLight)]],
    texture2d<float> baseColorTexture [[texture(TextureIndexBaseColor)]],
    texture2d<float> shadeMultiplyTexture [[texture(TextureIndexShadeMultiply)]],
    texture2d<float> normalTexture [[texture(TextureIndexNormal)]],
    texture2d<float> emissiveTexture [[texture(TextureIndexEmissive)]],
    texture2d<float> matcapTexture [[texture(TextureIndexMatcap)]],
    texture2d<float> rimTexture [[texture(TextureIndexRim)]],
    sampler textureSampler [[sampler(0)]]
) {
    // Apply UV transform (scale and offset)
    float2 uv = transformUV(in.texCoord, material.textureTransform);
    // TODO: Apply UV animation based on time

    // Debug mode 1: Show UV coordinates
    if (material.debugMode == 1) {
        return float4(uv.x, uv.y, 0.0, 1.0);
    }

    // Debug mode 2: Show texture directly without MToon shading
    if (material.debugMode == 2) {
        float4 texColor = baseColorTexture.sample(textureSampler, uv);
        return texColor;
    }

    // Debug mode 3: Show normals
    if (material.debugMode == 3) {
        float3 N = normalize(in.worldNormal);
        return float4(N * 0.5 + 0.5, 1.0);
    }

    // Debug mode 4: Show potential texture issues (white areas become magenta)
    if (material.debugMode == 4) {
        float4 texColor = baseColorTexture.sample(textureSampler, uv);
        // If texture is pure/near white (RGB all > 0.95), show magenta to highlight
        if (texColor.r > 0.95 && texColor.g > 0.95 && texColor.b > 0.95) {
            return float4(1.0, 0.0, 1.0, 1.0);  // Magenta
        }
        return texColor;
    }

    // Debug mode 5: Show shadeColor * texture (what shadow areas should look like)
    if (material.debugMode == 5) {
        float4 texColor = baseColorTexture.sample(textureSampler, uv);
        float4 shadeResult = material.shadeColor * texColor;
        return float4(shadeResult.rgb, 1.0);
    }

    // Debug mode 6: Show raw shadeColor uniform (without texture)
    if (material.debugMode == 6) {
        return float4(material.shadeColor.rgb, 1.0);
    }

    // Debug mode 7: Show hasShadeMultiplyTexture flag (green=0, red=1)
    if (material.debugMode == 7) {
        if (material.hasShadeMultiplyTexture == 0) {
            return float4(0.0, 1.0, 0.0, 1.0);  // Green = no shade texture, use base
        } else {
            return float4(1.0, 0.0, 0.0, 1.0);  // Red = has shade texture
        }
    }

    // Sample base texture once
    float4 baseTexColor = baseColorTexture.sample(textureSampler, uv);

    // Alpha test
    if (material.alphaMode == 1 && baseTexColor.a < material.alphaCutoff) {
        discard_fragment();
    }

    // Toon shading with texture multiplication
    float3 litResult = material.litColor.rgb * baseTexColor.rgb;

    // Shade color: blend between litColor and shadeColor to avoid being too dark
    float3 shadeColorBlended = mix(material.litColor.rgb, material.shadeColor.rgb, 0.5);
    float3 shadeResult = shadeColorBlended * baseTexColor.rgb;

    // Calculate shading based on light direction
    float3 N = normalize(in.worldNormal);
    float3 L = float3(0.0, 1.0, 0.0);  // Default: light from above
    if (lights.lightCount > 0) {
        L = normalize(-lights.lights[0].direction);  // Light direction points TO scene, so negate
    }
    float NdotL = dot(N, L);
    float rawShading = NdotL * 0.5 + 0.5;  // Half-lambert: remap -1..1 to 0..1

    // Toon shading: sharp transition using smoothstep with narrow range
    // shadeShift moves the threshold, shadeToony controls sharpness (higher = sharper)
    float threshold = 0.5 + material.shadeShift;
    float sharpness = mix(0.4, 0.01, material.shadeToony);  // toony=0 → soft, toony=1 → sharp
    float shading = smoothstep(threshold - sharpness, threshold + sharpness, rawShading);

    // Blend: shading=1 → litResult, shading=0 → shadeResult
    float3 finalColor = mix(shadeResult, litResult, shading);

    // ★★★ 常時リムライト（黒背景用 - 青白い縁取り）★★★
    float3 V = normalize(in.viewDirection);
    float NdotV = saturate(dot(N, V));
    float rimPower = 3.0;  // リムの鋭さ（高いほど細い）
    float rimStrength = 0.6;  // リムの強さ
    float rim = pow(1.0 - NdotV, rimPower) * rimStrength;

    // リムライトの色（青白い発光）
    float3 rimColor = float3(0.4, 0.7, 1.0);  // 青白
    finalColor += rimColor * rim;

    return float4(finalColor, baseTexColor.a);
}

// MARK: - MToon Outline Vertex Shader

vertex VertexOut mtoon_outline_vertex(
    const device Vertex* vertices [[buffer(BufferIndexVertices)]],
    constant Uniforms& uniforms [[buffer(BufferIndexUniforms)]],
    constant float4x4* boneMatrices [[buffer(BufferIndexBoneMatrices)]],
    constant MToonMaterialUniforms& material [[buffer(BufferIndexMaterial)]],
    // 【追加】モーフ用バッファ（アウトラインにもモーフを適用するため）
    constant float* morphWeights [[buffer(BufferIndexMorphWeights)]],
    const device float3* morphPositionDeltas [[buffer(BufferIndexMorphDeltas)]],
    uint vertexID [[vertex_id]]
) {
    Vertex in = vertices[vertexID];

    float3 position = in.position;
    float3 normal = in.normal;

    // 【追加】モーフィングの適用（skinned_vertexと同じロジック）
    if (uniforms.morphTargetCount > 0) {
        for (uint i = 0; i < uniforms.morphTargetCount && i < MAX_MORPH_TARGETS; i++) {
            float weight = morphWeights[i];
            if (weight > 0.0001) {
                // 【修正】カウントではなくストライドを使ってインデックス計算
                uint deltaIndex = vertexID * uniforms.morphTargetStride + i;
                position += morphPositionDeltas[deltaIndex] * weight;
            }
        }
    }

    // Apply skeletal skinning
    float4x4 skinMatrix;
    if (uniforms.hasSkinning) {
        // Cast float joints to int for array indexing
        int4 joints = int4(in.joints);
        float4 weights = in.weights;

        // ★安全チェック: ジョイントインデックスを有効範囲に制限 (0〜255)
        joints = clamp(joints, int4(0), int4(MAX_BONES - 1));

        // ★修正: ウェイトの合計を計算し、正規化する（ゼロ除算防止付き）
        float weightSum = dot(weights, float4(1.0));
        if (weightSum > 0.001) {
            weights /= weightSum;
        } else {
            // ウェイトが全て0の場合、最初のボーンに100%割り当てる（救済処置）
            weights = float4(1.0, 0.0, 0.0, 0.0);
        }

        skinMatrix = boneMatrices[joints.x] * weights.x +
                     boneMatrices[joints.y] * weights.y +
                     boneMatrices[joints.z] * weights.z +
                     boneMatrices[joints.w] * weights.w;
    } else {
        skinMatrix = float4x4(1.0);
    }

    float4 skinnedPosition = skinMatrix * float4(position, 1.0);
    float3 skinnedNormal = normalize((skinMatrix * float4(normal, 0.0)).xyz);

    // Expand position along normal for outline
    float outlineWidth = material.outlineWidth;

    if (material.outlineWidthMode == 1) {
        // World coordinates mode
        skinnedPosition.xyz += skinnedNormal * outlineWidth;
    } else if (material.outlineWidthMode == 2) {
        // Screen coordinates mode - adjust based on distance
        float4 worldPos = uniforms.modelMatrix * skinnedPosition;
        float dist = length(uniforms.cameraPosition - worldPos.xyz);
        float scaledWidth = outlineWidth * min(dist, material.outlineScaledMaxDistance) * 0.01;
        skinnedPosition.xyz += skinnedNormal * scaledWidth;
    }

    // Transform to world space
    float4 worldPosition = uniforms.modelMatrix * skinnedPosition;
    float3 worldNormal = normalize((uniforms.normalMatrix * float4(skinnedNormal, 0.0)).xyz);

    VertexOut out;
    out.position = uniforms.viewProjectionMatrix * worldPosition;
    out.worldPosition = worldPosition.xyz;
    out.worldNormal = worldNormal;
    out.texCoord = in.texCoord;
    out.viewDirection = uniforms.cameraPosition - worldPosition.xyz;
    out.tangent = float4(0.0);

    return out;
}

// MARK: - MToon Outline Fragment Shader

fragment float4 mtoon_outline_fragment(
    VertexOut in [[stage_in]],
    constant MToonMaterialUniforms& material [[buffer(BufferIndexMaterial)]],
    constant LightUniforms& lights [[buffer(BufferIndexLight)]],
    texture2d<float> baseColorTexture [[texture(TextureIndexBaseColor)]],
    sampler textureSampler [[sampler(0)]]
) {
    // Apply UV transform (scale and offset)
    float2 uv = transformUV(in.texCoord, material.textureTransform);

    // Base alpha for cutoff
    float4 baseColor = baseColorTexture.sample(textureSampler, uv);
    if (material.alphaMode == 1 && baseColor.a < material.alphaCutoff) {
        discard_fragment();
    }

    // Outline color with optional lighting mix
    float3 outlineColor = material.outlineColor.rgb;

    if (material.outlineLightingMix > 0.0 && lights.lightCount > 0) {
        LightData mainLight = lights.lights[0];
        float3 L = normalize(-mainLight.direction);
        float NdotL = max(dot(normalize(in.worldNormal), L), 0.0);

        float3 litOutline = outlineColor * mainLight.color * mainLight.intensity * NdotL;
        outlineColor = mix(outlineColor, litOutline, material.outlineLightingMix);
    }

    return float4(outlineColor, material.outlineColor.a);
}
