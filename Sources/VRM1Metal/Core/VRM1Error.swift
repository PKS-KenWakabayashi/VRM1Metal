import Foundation

/// VRM1Metal library errors
public enum VRM1Error: LocalizedError {
    // GLTF Parsing Errors
    case invalidGLBMagic
    case unsupportedGLTFVersion(UInt32)
    case missingJSONChunk
    case invalidJSONChunk
    case invalidBinaryChunk
    case jsonDecodingFailed(Error)

    // Buffer Errors
    case bufferIndexOutOfBounds(Int)
    case bufferViewIndexOutOfBounds(Int)
    case accessorIndexOutOfBounds(Int)
    case invalidBufferData

    // Mesh Errors
    case meshIndexOutOfBounds(Int)
    case primitiveHasNoPositions
    case invalidVertexData

    // Node Errors
    case nodeIndexOutOfBounds(Int)
    case cyclicNodeHierarchy

    // Material/Texture Errors
    case materialIndexOutOfBounds(Int)
    case textureIndexOutOfBounds(Int)
    case imageIndexOutOfBounds(Int)
    case unsupportedImageFormat(String)
    case imageDecodingFailed

    // Skin Errors
    case skinIndexOutOfBounds(Int)
    case invalidJointCount

    // VRM Extension Errors
    case missingVRMExtension
    case invalidVRMVersion(String)
    case missingHumanoid
    case invalidHumanoidBone(String)

    // Metal Errors
    case metalDeviceNotAvailable
    case shaderCompilationFailed(String)
    case pipelineCreationFailed(String)
    case textureCreationFailed
    case bufferCreationFailed

    // File Errors
    case fileNotFound(String)
    case fileReadFailed(Error)

    public var errorDescription: String? {
        switch self {
        case .invalidGLBMagic:
            return "Invalid GLB file: magic number mismatch (expected 'glTF')"
        case .unsupportedGLTFVersion(let version):
            return "Unsupported glTF version: \(version) (expected 2)"
        case .missingJSONChunk:
            return "GLB file is missing required JSON chunk"
        case .invalidJSONChunk:
            return "GLB JSON chunk is invalid or corrupted"
        case .invalidBinaryChunk:
            return "GLB binary chunk is invalid or corrupted"
        case .jsonDecodingFailed(let error):
            return "Failed to decode glTF JSON: \(error.localizedDescription)"

        case .bufferIndexOutOfBounds(let index):
            return "Buffer index \(index) is out of bounds"
        case .bufferViewIndexOutOfBounds(let index):
            return "BufferView index \(index) is out of bounds"
        case .accessorIndexOutOfBounds(let index):
            return "Accessor index \(index) is out of bounds"
        case .invalidBufferData:
            return "Buffer data is invalid or corrupted"

        case .meshIndexOutOfBounds(let index):
            return "Mesh index \(index) is out of bounds"
        case .primitiveHasNoPositions:
            return "Mesh primitive is missing POSITION attribute"
        case .invalidVertexData:
            return "Vertex data is invalid or corrupted"

        case .nodeIndexOutOfBounds(let index):
            return "Node index \(index) is out of bounds"
        case .cyclicNodeHierarchy:
            return "Node hierarchy contains a cycle"

        case .materialIndexOutOfBounds(let index):
            return "Material index \(index) is out of bounds"
        case .textureIndexOutOfBounds(let index):
            return "Texture index \(index) is out of bounds"
        case .imageIndexOutOfBounds(let index):
            return "Image index \(index) is out of bounds"
        case .unsupportedImageFormat(let format):
            return "Unsupported image format: \(format)"
        case .imageDecodingFailed:
            return "Failed to decode image data"

        case .skinIndexOutOfBounds(let index):
            return "Skin index \(index) is out of bounds"
        case .invalidJointCount:
            return "Skin has invalid joint count"

        case .missingVRMExtension:
            return "VRM extension (VRMC_vrm) not found in glTF document"
        case .invalidVRMVersion(let version):
            return "Invalid or unsupported VRM version: \(version)"
        case .missingHumanoid:
            return "VRM humanoid definition is missing"
        case .invalidHumanoidBone(let bone):
            return "Invalid humanoid bone: \(bone)"

        case .metalDeviceNotAvailable:
            return "Metal device is not available on this system"
        case .shaderCompilationFailed(let message):
            return "Shader compilation failed: \(message)"
        case .pipelineCreationFailed(let message):
            return "Render pipeline creation failed: \(message)"
        case .textureCreationFailed:
            return "Failed to create Metal texture"
        case .bufferCreationFailed:
            return "Failed to create Metal buffer"

        case .fileNotFound(let path):
            return "File not found: \(path)"
        case .fileReadFailed(let error):
            return "Failed to read file: \(error.localizedDescription)"
        }
    }
}
