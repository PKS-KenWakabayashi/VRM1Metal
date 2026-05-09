#ifndef ShaderTypes_h
#define ShaderTypes_h

#include <simd/simd.h>

// Buffer indices
typedef enum {
    BufferIndexVertices = 0,
    BufferIndexUniforms = 1,
    BufferIndexBoneMatrices = 2,
    BufferIndexMorphWeights = 3,
    BufferIndexMorphDeltas = 4,
    BufferIndexMaterial = 5,
    BufferIndexLight = 6
} BufferIndex;

// Texture indices
typedef enum {
    TextureIndexBaseColor = 0,
    TextureIndexNormal = 1,
    TextureIndexEmissive = 2,
    TextureIndexMetallicRoughness = 3,
    TextureIndexOcclusion = 4,
    // MToon specific
    TextureIndexShadeMultiply = 5,
    TextureIndexMatcap = 6,
    TextureIndexRim = 7,
    TextureIndexOutlineWidth = 8,
    TextureIndexUVAnimationMask = 9
} TextureIndex;

// Vertex attribute indices
typedef enum {
    VertexAttributePosition = 0,
    VertexAttributeNormal = 1,
    VertexAttributeTexCoord = 2,
    VertexAttributeTangent = 3,
    VertexAttributeJoints = 4,
    VertexAttributeWeights = 5
} VertexAttribute;

// Maximum limits
#define MAX_BONES 256
#define MAX_MORPH_TARGETS 64
#define MAX_LIGHTS 4

// Vertex input structure (96 bytes total)
// Memory layout must match Swift side exactly
typedef struct {
    simd_float3 position;       // 16 bytes (12 + 4 padding)
    simd_float3 normal;         // 16 bytes (12 + 4 padding)
    simd_float2 texCoord;       // 8 bytes
    simd_float2 _texCoordPad;   // 8 bytes padding for 16-byte alignment of tangent
    simd_float4 tangent;        // 16 bytes
    simd_float4 joints;         // 16 bytes (float values, cast to int in shader)
    simd_float4 weights;        // 16 bytes
} Vertex;

// Per-frame uniforms
typedef struct {
    simd_float4x4 modelMatrix;
    simd_float4x4 viewMatrix;
    simd_float4x4 projectionMatrix;
    simd_float4x4 viewProjectionMatrix;
    simd_float4x4 normalMatrix;
    simd_float3 cameraPosition;
    float time;
    uint morphTargetCount;
    uint morphTargetStride;
    uint hasSkinning;
} Uniforms;

// Material uniforms (PBR)
typedef struct {
    simd_float4 baseColorFactor;        // offset 0, 16 bytes
    simd_float3 emissiveFactor;         // offset 16, 12 bytes + 4 padding
    float metallicFactor;               // offset 32, 4 bytes
    float roughnessFactor;              // offset 36, 4 bytes
    float alphaCutoff;                  // offset 40, 4 bytes
    int alphaMode;                      // offset 44, 4 bytes (0=OPAQUE, 1=MASK, 2=BLEND)
    int doubleSided;                    // offset 48, 4 bytes
    int hasBaseColorTexture;            // offset 52, 4 bytes
    int hasNormalTexture;               // offset 56, 4 bytes
    int hasEmissiveTexture;             // offset 60, 4 bytes
    int hasMetallicRoughnessTexture;    // offset 64, 4 bytes
    int debugMode;                      // offset 68, 4 bytes (0=normal, 1=UV, 2=unlit texture, 3=normals)
    float _pad1;                        // offset 72, 4 bytes
    float _pad2;                        // offset 76, 4 bytes
    simd_float4 textureTransform;       // offset 80, 16 bytes (ScaleX, ScaleY, OffsetX, OffsetY)
    // Total: 96 bytes
} MaterialUniforms;

// MToon material uniforms
typedef struct {
    // Base colors
    simd_float4 litColor;
    simd_float4 shadeColor;
    simd_float4 emissionColor;
    simd_float4 matcapColor;
    simd_float4 rimColor;
    simd_float4 outlineColor;

    // Shading parameters
    float shadeShift;
    float shadeToony;
    float rimLightingMix;
    float rimFresnelPower;
    float rimLift;

    // Outline parameters
    float outlineWidth;
    float outlineScaledMaxDistance;
    float outlineLightingMix;
    int outlineWidthMode; // 0=none, 1=worldCoordinates, 2=screenCoordinates

    // Texture flags
    int hasShadeMultiplyTexture;
    int hasMatcapTexture;
    int hasRimMultiplyTexture;
    int hasOutlineWidthTexture;
    int hasUVAnimationMaskTexture;

    // UV animation
    float uvAnimationScrollXSpeed;
    float uvAnimationScrollYSpeed;
    float uvAnimationRotationSpeed;

    // Alpha
    float alphaCutoff;
    int alphaMode;
    int isOutlinePass;

    // Debug mode: 0=normal, 1=UV, 2=unlit texture, 3=normals, 4=material index
    int debugMode;

    // Texture transform (ScaleX, ScaleY, OffsetX, OffsetY)
    simd_float4 textureTransform;
} MToonMaterialUniforms;

// Light data
typedef struct {
    simd_float3 direction;
    float intensity;
    simd_float3 color;
    int type; // 0=directional, 1=point, 2=spot
} LightData;

// Light uniforms
typedef struct {
    LightData lights[MAX_LIGHTS];
    int lightCount;
    simd_float3 ambientColor;
} LightUniforms;

#endif /* ShaderTypes_h */
