#include <metal_stdlib>
using namespace metal;

#include "ShaderTypes.h"

// Vertex output structure
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

// MARK: - Basic Vertex Shader (No Skinning)

vertex VertexOut basic_vertex(
    const device Vertex* vertices [[buffer(BufferIndexVertices)]],
    constant Uniforms& uniforms [[buffer(BufferIndexUniforms)]],
    uint vertexID [[vertex_id]]
) {
    Vertex in = vertices[vertexID];

    VertexOut out;

    float4 worldPosition = uniforms.modelMatrix * float4(in.position, 1.0);
    out.position = uniforms.viewProjectionMatrix * worldPosition;
    out.worldPosition = worldPosition.xyz;
    out.worldNormal = normalize((uniforms.normalMatrix * float4(in.normal, 0.0)).xyz);
    out.texCoord = in.texCoord;
    out.viewDirection = uniforms.cameraPosition - worldPosition.xyz;
    out.tangent = float4((uniforms.normalMatrix * float4(in.tangent.xyz, 0.0)).xyz, in.tangent.w);

    return out;
}

// MARK: - Skinned Vertex Shader

vertex VertexOut skinned_vertex(
    const device Vertex* vertices [[buffer(BufferIndexVertices)]],
    constant Uniforms& uniforms [[buffer(BufferIndexUniforms)]],
    constant float4x4* boneMatrices [[buffer(BufferIndexBoneMatrices)]],
    constant float* morphWeights [[buffer(BufferIndexMorphWeights)]],
    // 【修正】constant → device: 64KB制限を回避するためdevice空間を使用
    const device float3* morphPositionDeltas [[buffer(BufferIndexMorphDeltas)]],
    uint vertexID [[vertex_id]]
) {
    Vertex in = vertices[vertexID];

    float3 position = in.position;
    float3 normal = in.normal;

    // Apply morph targets
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

    // Transform to world space
    float4 worldPosition = uniforms.modelMatrix * skinnedPosition;
    float3 worldNormal = normalize((uniforms.normalMatrix * float4(skinnedNormal, 0.0)).xyz);

    VertexOut out;
    out.position = uniforms.viewProjectionMatrix * worldPosition;
    out.worldPosition = worldPosition.xyz;
    out.worldNormal = worldNormal;
    out.texCoord = in.texCoord;
    out.viewDirection = uniforms.cameraPosition - worldPosition.xyz;
    out.tangent = float4((uniforms.normalMatrix * float4(in.tangent.xyz, 0.0)).xyz, in.tangent.w);

    return out;
}

// MARK: - Basic PBR Fragment Shader

fragment float4 pbr_fragment(
    VertexOut in [[stage_in]],
    constant MaterialUniforms& material [[buffer(BufferIndexMaterial)]],
    constant LightUniforms& lights [[buffer(BufferIndexLight)]],
    texture2d<float> baseColorTexture [[texture(TextureIndexBaseColor)]],
    texture2d<float> normalTexture [[texture(TextureIndexNormal)]],
    texture2d<float> emissiveTexture [[texture(TextureIndexEmissive)]],
    texture2d<float> metallicRoughnessTexture [[texture(TextureIndexMetallicRoughness)]],
    sampler textureSampler [[sampler(0)]]
) {
    // Apply UV transform (scale and offset)
    float2 uv = transformUV(in.texCoord, material.textureTransform);

    // Debug mode 1: Show UV coordinates (after transform)
    if (material.debugMode == 1) {
        return float4(uv.x, uv.y, 0.0, 1.0);
    }

    // Debug mode 2: Show texture directly (unlit)
    if (material.debugMode == 2) {
        if (material.hasBaseColorTexture) {
            return baseColorTexture.sample(textureSampler, uv);
        }
        return float4(1.0, 0.0, 1.0, 1.0); // Magenta if no texture
    }

    // Debug mode 3: Show normals
    if (material.debugMode == 3) {
        float3 N = normalize(in.worldNormal);
        return float4(N * 0.5 + 0.5, 1.0);
    }

    // Base color
    float4 baseColor = material.baseColorFactor;
    if (material.hasBaseColorTexture) {
        baseColor *= baseColorTexture.sample(textureSampler, uv);
    }

    // Alpha test
    if (material.alphaMode == 1 && baseColor.a < material.alphaCutoff) {
        discard_fragment();
    }

    // Normal
    float3 N = normalize(in.worldNormal);
    if (material.hasNormalTexture) {
        float3 normalSample = normalTexture.sample(textureSampler, uv).xyz * 2.0 - 1.0;
        float3 T = normalize(in.tangent.xyz);
        float3 B = cross(N, T) * in.tangent.w;
        float3x3 TBN = float3x3(T, B, N);
        N = normalize(TBN * normalSample);
    }

    // View direction
    float3 V = normalize(in.viewDirection);

    // Metallic/Roughness - clamp to reasonable values for VRM characters
    float metallic = clamp(material.metallicFactor, 0.0, 1.0);
    float roughness = clamp(material.roughnessFactor, 0.04, 1.0);
    if (material.hasMetallicRoughnessTexture) {
        float4 mr = metallicRoughnessTexture.sample(textureSampler, uv);
        metallic *= mr.b;
        roughness *= mr.g;
    }

    // Simple lighting (Lambertian diffuse + Blinn-Phong specular)
    float3 finalColor = float3(0.0);

    // Ambient - apply to both metallic and non-metallic, modulated by roughness
    float3 ambient = lights.ambientColor * baseColor.rgb;
    finalColor += ambient;

    // Directional lights
    for (int i = 0; i < lights.lightCount && i < MAX_LIGHTS; i++) {
        LightData light = lights.lights[i];
        float3 L = normalize(-light.direction);
        float3 H = normalize(V + L);

        float NdotL = max(dot(N, L), 0.0);
        float NdotH = max(dot(N, H), 0.0);

        // Diffuse (Lambertian)
        float3 diffuse = baseColor.rgb * (1.0 - metallic) * NdotL;

        // Specular (simple Blinn-Phong)
        float shininess = max(1.0, (1.0 - roughness) * 128.0);
        float3 specularColor = mix(float3(0.04), baseColor.rgb, metallic);
        float3 specular = specularColor * pow(NdotH, shininess) * NdotL;

        finalColor += (diffuse + specular) * light.color * light.intensity;
    }

    // Emissive
    float3 emissive = material.emissiveFactor;
    if (material.hasEmissiveTexture) {
        emissive *= emissiveTexture.sample(textureSampler, uv).rgb;
    }
    finalColor += emissive;

    return float4(finalColor, baseColor.a);
}

// MARK: - Unlit Fragment Shader

fragment float4 unlit_fragment(
    VertexOut in [[stage_in]],
    constant MaterialUniforms& material [[buffer(BufferIndexMaterial)]],
    texture2d<float> baseColorTexture [[texture(TextureIndexBaseColor)]],
    sampler textureSampler [[sampler(0)]]
) {
    // Apply UV transform (scale and offset)
    float2 uv = transformUV(in.texCoord, material.textureTransform);

    float4 baseColor = material.baseColorFactor;
    if (material.hasBaseColorTexture) {
        baseColor *= baseColorTexture.sample(textureSampler, uv);
    }

    if (material.alphaMode == 1 && baseColor.a < material.alphaCutoff) {
        discard_fragment();
    }

    return baseColor;
}
