import Foundation
import simd

// MARK: - Root Document

/// Complete glTF 2.0 document representation
public struct GLTFDocument: Codable {
    public var asset: GLTFAsset
    public var scene: Int?
    public var scenes: [GLTFScene]?
    public var nodes: [GLTFNode]?
    public var meshes: [GLTFMesh]?
    public var accessors: [GLTFAccessor]?
    public var bufferViews: [GLTFBufferView]?
    public var buffers: [GLTFBuffer]?
    public var materials: [GLTFMaterial]?
    public var textures: [GLTFTexture]?
    public var images: [GLTFImage]?
    public var samplers: [GLTFSampler]?
    public var skins: [GLTFSkin]?
    public var animations: [GLTFAnimation]?
    public var cameras: [GLTFCamera]?
    public var extensions: [String: AnyCodable]?
    public var extensionsUsed: [String]?
    public var extensionsRequired: [String]?
    public var extras: AnyCodable?
}

// MARK: - Asset

public struct GLTFAsset: Codable {
    public var version: String
    public var generator: String?
    public var copyright: String?
    public var minVersion: String?
    public var extras: AnyCodable?
}

// MARK: - Scene

public struct GLTFScene: Codable {
    public var name: String?
    public var nodes: [Int]?
    public var extras: AnyCodable?
}

// MARK: - Node

public struct GLTFNode: Codable {
    public var name: String?
    public var children: [Int]?
    public var mesh: Int?
    public var skin: Int?
    public var camera: Int?

    // Transform (use matrix OR TRS)
    public var matrix: [Float]?
    public var translation: [Float]?
    public var rotation: [Float]?
    public var scale: [Float]?

    public var weights: [Float]?
    public var extensions: [String: AnyCodable]?
    public var extras: AnyCodable?

    /// Compute local transform matrix from TRS or matrix property
    public func localTransform() -> simd_float4x4 {
        if let matrix = matrix, matrix.count == 16 {
            return simd_float4x4(
                SIMD4<Float>(matrix[0], matrix[1], matrix[2], matrix[3]),
                SIMD4<Float>(matrix[4], matrix[5], matrix[6], matrix[7]),
                SIMD4<Float>(matrix[8], matrix[9], matrix[10], matrix[11]),
                SIMD4<Float>(matrix[12], matrix[13], matrix[14], matrix[15])
            )
        }

        let t = translation ?? [0, 0, 0]
        let r = rotation ?? [0, 0, 0, 1]
        let s = scale ?? [1, 1, 1]

        let translationMatrix = simd_float4x4(
            SIMD4<Float>(1, 0, 0, 0),
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(t[0], t[1], t[2], 1)
        )

        let quat = simd_quatf(ix: r[0], iy: r[1], iz: r[2], r: r[3])
        let rotationMatrix = simd_float4x4(quat)

        let scaleMatrix = simd_float4x4(
            SIMD4<Float>(s[0], 0, 0, 0),
            SIMD4<Float>(0, s[1], 0, 0),
            SIMD4<Float>(0, 0, s[2], 0),
            SIMD4<Float>(0, 0, 0, 1)
        )

        return translationMatrix * rotationMatrix * scaleMatrix
    }
}

// MARK: - Mesh

public struct GLTFMesh: Codable {
    public var name: String?
    public var primitives: [GLTFPrimitive]
    public var weights: [Float]?
    public var extras: AnyCodable?
}

public struct GLTFPrimitive: Codable {
    public var attributes: [String: Int]
    public var indices: Int?
    public var material: Int?
    public var mode: Int?
    public var targets: [[String: Int]]?
    public var extras: AnyCodable?

    /// Primitive rendering mode
    public var renderMode: GLTFPrimitiveMode {
        GLTFPrimitiveMode(rawValue: mode ?? 4) ?? .triangles
    }
}

public enum GLTFPrimitiveMode: Int, Codable {
    case points = 0
    case lines = 1
    case lineLoop = 2
    case lineStrip = 3
    case triangles = 4
    case triangleStrip = 5
    case triangleFan = 6
}

// MARK: - Accessor

public struct GLTFAccessor: Codable {
    public var bufferView: Int?
    public var byteOffset: Int?
    public var componentType: Int
    public var normalized: Bool?
    public var count: Int
    public var type: String
    public var max: [Float]?
    public var min: [Float]?
    public var sparse: GLTFAccessorSparse?
    public var name: String?
    public var extras: AnyCodable?

    public var componentTypeEnum: GLTFComponentType {
        GLTFComponentType(rawValue: componentType) ?? .float
    }

    public var typeEnum: GLTFAccessorType {
        GLTFAccessorType(rawValue: type) ?? .scalar
    }

    /// Number of components per element
    public var componentCount: Int {
        typeEnum.componentCount
    }

    /// Byte size of one component
    public var componentByteSize: Int {
        componentTypeEnum.byteSize
    }

    /// Total byte size of one element
    public var elementByteSize: Int {
        componentCount * componentByteSize
    }
}

public struct GLTFAccessorSparse: Codable {
    public var count: Int
    public var indices: GLTFAccessorSparseIndices
    public var values: GLTFAccessorSparseValues
}

public struct GLTFAccessorSparseIndices: Codable {
    public var bufferView: Int
    public var byteOffset: Int?
    public var componentType: Int
}

public struct GLTFAccessorSparseValues: Codable {
    public var bufferView: Int
    public var byteOffset: Int?
}

public enum GLTFComponentType: Int, Codable {
    case byte = 5120
    case unsignedByte = 5121
    case short = 5122
    case unsignedShort = 5123
    case unsignedInt = 5125
    case float = 5126

    public var byteSize: Int {
        switch self {
        case .byte, .unsignedByte: return 1
        case .short, .unsignedShort: return 2
        case .unsignedInt, .float: return 4
        }
    }
}

public enum GLTFAccessorType: String, Codable {
    case scalar = "SCALAR"
    case vec2 = "VEC2"
    case vec3 = "VEC3"
    case vec4 = "VEC4"
    case mat2 = "MAT2"
    case mat3 = "MAT3"
    case mat4 = "MAT4"

    public var componentCount: Int {
        switch self {
        case .scalar: return 1
        case .vec2: return 2
        case .vec3: return 3
        case .vec4: return 4
        case .mat2: return 4
        case .mat3: return 9
        case .mat4: return 16
        }
    }
}

// MARK: - BufferView

public struct GLTFBufferView: Codable {
    public var buffer: Int
    public var byteOffset: Int?
    public var byteLength: Int
    public var byteStride: Int?
    public var target: Int?
    public var name: String?
    public var extras: AnyCodable?

    public var targetEnum: GLTFBufferViewTarget? {
        target.flatMap { GLTFBufferViewTarget(rawValue: $0) }
    }
}

public enum GLTFBufferViewTarget: Int, Codable {
    case arrayBuffer = 34962
    case elementArrayBuffer = 34963
}

// MARK: - Buffer

public struct GLTFBuffer: Codable {
    public var uri: String?
    public var byteLength: Int
    public var name: String?
    public var extras: AnyCodable?
}

// MARK: - Material

public struct GLTFMaterial: Codable {
    public var name: String?
    public var pbrMetallicRoughness: GLTFPBRMetallicRoughness?
    public var normalTexture: GLTFNormalTextureInfo?
    public var occlusionTexture: GLTFOcclusionTextureInfo?
    public var emissiveTexture: GLTFTextureInfo?
    public var emissiveFactor: [Float]?
    public var alphaMode: String?
    public var alphaCutoff: Float?
    public var doubleSided: Bool?
    public var extensions: [String: AnyCodable]?
    public var extras: AnyCodable?

    public var alphaModeEnum: GLTFAlphaMode {
        alphaMode.flatMap { GLTFAlphaMode(rawValue: $0) } ?? .opaque
    }
}

public struct GLTFPBRMetallicRoughness: Codable {
    public var baseColorFactor: [Float]?
    public var baseColorTexture: GLTFTextureInfo?
    public var metallicFactor: Float?
    public var roughnessFactor: Float?
    public var metallicRoughnessTexture: GLTFTextureInfo?
    public var extras: AnyCodable?
}

public struct GLTFTextureInfo: Codable {
    public var index: Int
    public var texCoord: Int?
    public var extensions: [String: AnyCodable]?
    public var extras: AnyCodable?
}

public struct GLTFNormalTextureInfo: Codable {
    public var index: Int
    public var texCoord: Int?
    public var scale: Float?
    public var extras: AnyCodable?
}

public struct GLTFOcclusionTextureInfo: Codable {
    public var index: Int
    public var texCoord: Int?
    public var strength: Float?
    public var extras: AnyCodable?
}

public enum GLTFAlphaMode: String, Codable {
    case opaque = "OPAQUE"
    case mask = "MASK"
    case blend = "BLEND"
}

// MARK: - Texture

public struct GLTFTexture: Codable {
    public var sampler: Int?
    public var source: Int?
    public var name: String?
    public var extras: AnyCodable?
}

// MARK: - Image

public struct GLTFImage: Codable {
    public var uri: String?
    public var mimeType: String?
    public var bufferView: Int?
    public var name: String?
    public var extras: AnyCodable?
}

// MARK: - Sampler

public struct GLTFSampler: Codable {
    public var magFilter: Int?
    public var minFilter: Int?
    public var wrapS: Int?
    public var wrapT: Int?
    public var name: String?
    public var extras: AnyCodable?
}

// MARK: - Skin

public struct GLTFSkin: Codable {
    public var name: String?
    public var inverseBindMatrices: Int?
    public var skeleton: Int?
    public var joints: [Int]
    public var extras: AnyCodable?
}

// MARK: - Animation

public struct GLTFAnimation: Codable {
    public var name: String?
    public var channels: [GLTFAnimationChannel]
    public var samplers: [GLTFAnimationSampler]
    public var extras: AnyCodable?
}

public struct GLTFAnimationChannel: Codable {
    public var sampler: Int
    public var target: GLTFAnimationChannelTarget
}

public struct GLTFAnimationChannelTarget: Codable {
    public var node: Int?
    public var path: String
}

public struct GLTFAnimationSampler: Codable {
    public var input: Int
    public var output: Int
    public var interpolation: String?

    public var interpolationEnum: GLTFInterpolation {
        interpolation.flatMap { GLTFInterpolation(rawValue: $0) } ?? .linear
    }
}

public enum GLTFInterpolation: String, Codable {
    case linear = "LINEAR"
    case step = "STEP"
    case cubicSpline = "CUBICSPLINE"
}

// MARK: - Camera

public struct GLTFCamera: Codable {
    public var name: String?
    public var type: String
    public var orthographic: GLTFCameraOrthographic?
    public var perspective: GLTFCameraPerspective?
    public var extras: AnyCodable?
}

public struct GLTFCameraOrthographic: Codable {
    public var xmag: Float
    public var ymag: Float
    public var zfar: Float
    public var znear: Float
}

public struct GLTFCameraPerspective: Codable {
    public var aspectRatio: Float?
    public var yfov: Float
    public var zfar: Float?
    public var znear: Float
}

// MARK: - AnyCodable Helper

/// Type-erased Codable for handling arbitrary JSON
public struct AnyCodable: Codable {
    public let value: Any

    public init(_ value: Any) {
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            value = NSNull()
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map { $0.value }
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues { $0.value }
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Cannot decode AnyCodable"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch value {
        case is NSNull:
            try container.encodeNil()
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let array as [Any]:
            try container.encode(array.map { AnyCodable($0) })
        case let dict as [String: Any]:
            try container.encode(dict.mapValues { AnyCodable($0) })
        default:
            throw EncodingError.invalidValue(
                value,
                EncodingError.Context(
                    codingPath: encoder.codingPath,
                    debugDescription: "Cannot encode AnyCodable"
                )
            )
        }
    }

    // Convenience accessors
    public var dictionary: [String: Any]? {
        value as? [String: Any]
    }

    public var array: [Any]? {
        value as? [Any]
    }

    public var string: String? {
        value as? String
    }

    public var int: Int? {
        value as? Int
    }

    public var double: Double? {
        value as? Double
    }

    public var bool: Bool? {
        value as? Bool
    }
}
