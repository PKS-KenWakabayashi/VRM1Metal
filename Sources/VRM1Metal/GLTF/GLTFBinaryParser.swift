import Foundation

/// Parses GLB (Binary glTF) format files including VRM
public final class GLTFBinaryParser {

    // GLB Magic: 0x46546C67 ("glTF" in ASCII)
    private static let GLB_MAGIC: UInt32 = 0x46546C67

    // GLB Version (must be 2)
    private static let GLB_VERSION: UInt32 = 2

    // Chunk types
    private static let CHUNK_TYPE_JSON: UInt32 = 0x4E4F534A  // "JSON"
    private static let CHUNK_TYPE_BIN: UInt32 = 0x004E4942   // "BIN\0"

    // Header size: magic(4) + version(4) + length(4) = 12 bytes
    private static let HEADER_SIZE = 12

    // Chunk header size: length(4) + type(4) = 8 bytes
    private static let CHUNK_HEADER_SIZE = 8

    /// Result of parsing a GLB file
    public struct ParseResult {
        /// Parsed glTF document
        public let document: GLTFDocument

        /// Binary buffer data (if present)
        public let binaryBuffer: Data?

        /// Original file data for resolving buffer references
        public let sourceData: Data
    }

    /// Parse GLB data from a file URL
    public static func parse(url: URL) throws -> ParseResult {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw VRM1Error.fileReadFailed(error)
        }
        return try parse(data: data)
    }

    /// Parse GLB data from memory
    public static func parse(data: Data) throws -> ParseResult {
        guard data.count >= HEADER_SIZE else {
            throw VRM1Error.invalidGLBMagic
        }

        // Read header
        let header = try parseHeader(data: data)

        // Validate header
        guard header.magic == GLB_MAGIC else {
            throw VRM1Error.invalidGLBMagic
        }

        guard header.version == GLB_VERSION else {
            throw VRM1Error.unsupportedGLTFVersion(header.version)
        }

        // Parse chunks
        var offset = HEADER_SIZE
        var jsonData: Data?
        var binaryData: Data?

        while offset < data.count {
            let chunk = try parseChunk(data: data, offset: offset)

            switch chunk.type {
            case CHUNK_TYPE_JSON:
                jsonData = chunk.data
            case CHUNK_TYPE_BIN:
                binaryData = chunk.data
            default:
                // Unknown chunk type, skip it
                break
            }

            offset += CHUNK_HEADER_SIZE + Int(chunk.length)

            // Align to 4-byte boundary
            offset = (offset + 3) & ~3
        }

        // JSON chunk is required
        guard let json = jsonData else {
            throw VRM1Error.missingJSONChunk
        }

        // Decode JSON to GLTFDocument
        let document: GLTFDocument
        do {
            let decoder = JSONDecoder()
            document = try decoder.decode(GLTFDocument.self, from: json)
        } catch {
            throw VRM1Error.jsonDecodingFailed(error)
        }

        return ParseResult(
            document: document,
            binaryBuffer: binaryData,
            sourceData: data
        )
    }

    // MARK: - Private Helpers

    private struct GLBHeader {
        let magic: UInt32
        let version: UInt32
        let length: UInt32
    }

    private struct GLBChunk {
        let length: UInt32
        let type: UInt32
        let data: Data
    }

    private static func parseHeader(data: Data) throws -> GLBHeader {
        return data.withUnsafeBytes { buffer in
            let magic = buffer.load(fromByteOffset: 0, as: UInt32.self)
            let version = buffer.load(fromByteOffset: 4, as: UInt32.self)
            let length = buffer.load(fromByteOffset: 8, as: UInt32.self)
            return GLBHeader(magic: magic, version: version, length: length)
        }
    }

    private static func parseChunk(data: Data, offset: Int) throws -> GLBChunk {
        guard offset + CHUNK_HEADER_SIZE <= data.count else {
            throw VRM1Error.invalidBinaryChunk
        }

        let chunkLength: UInt32 = data.withUnsafeBytes { buffer in
            buffer.load(fromByteOffset: offset, as: UInt32.self)
        }

        let chunkType: UInt32 = data.withUnsafeBytes { buffer in
            buffer.load(fromByteOffset: offset + 4, as: UInt32.self)
        }

        let dataStart = offset + CHUNK_HEADER_SIZE
        let dataEnd = dataStart + Int(chunkLength)

        guard dataEnd <= data.count else {
            throw VRM1Error.invalidBinaryChunk
        }

        let chunkData = data.subdata(in: dataStart..<dataEnd)

        return GLBChunk(length: chunkLength, type: chunkType, data: chunkData)
    }
}

// MARK: - Buffer Data Access

public extension GLTFBinaryParser.ParseResult {

    /// Get buffer data for the specified buffer index
    func getBufferData(bufferIndex: Int) throws -> Data {
        guard let buffers = document.buffers,
              bufferIndex < buffers.count else {
            throw VRM1Error.bufferIndexOutOfBounds(bufferIndex)
        }

        let buffer = buffers[bufferIndex]

        // Buffer 0 typically uses the binary chunk in GLB
        if bufferIndex == 0, let binaryBuffer = binaryBuffer {
            return binaryBuffer
        }

        // External URI (base64 or file reference)
        if let uri = buffer.uri {
            if uri.hasPrefix("data:") {
                return try decodeDataURI(uri)
            } else {
                throw VRM1Error.fileNotFound(uri)
            }
        }

        throw VRM1Error.invalidBufferData
    }

    /// Get buffer view data
    func getBufferViewData(bufferViewIndex: Int) throws -> Data {
        guard let bufferViews = document.bufferViews,
              bufferViewIndex < bufferViews.count else {
            throw VRM1Error.bufferViewIndexOutOfBounds(bufferViewIndex)
        }

        let bufferView = bufferViews[bufferViewIndex]
        let bufferData = try getBufferData(bufferIndex: bufferView.buffer)

        let offset = bufferView.byteOffset ?? 0
        let length = bufferView.byteLength

        guard offset + length <= bufferData.count else {
            throw VRM1Error.invalidBufferData
        }

        return bufferData.subdata(in: offset..<(offset + length))
    }

    /// Get accessor data as Float array
    func getAccessorDataAsFloats(accessorIndex: Int) throws -> [Float] {
        guard let accessors = document.accessors,
              accessorIndex < accessors.count else {
            throw VRM1Error.accessorIndexOutOfBounds(accessorIndex)
        }

        let accessor = accessors[accessorIndex]
        let totalElements = accessor.count * accessor.componentCount

        // Initialize result array
        var result: [Float]

        // Step 1: Read base data from bufferView (if present)
        if let bufferViewIndex = accessor.bufferView {
            let bufferViewData = try getBufferViewData(bufferViewIndex: bufferViewIndex)
            let byteOffset = accessor.byteOffset ?? 0

            guard let bufferViews = document.bufferViews else {
                throw VRM1Error.bufferViewIndexOutOfBounds(bufferViewIndex)
            }
            let bufferView = bufferViews[bufferViewIndex]
            let byteStride = bufferView.byteStride ?? accessor.elementByteSize

            result = [Float]()
            result.reserveCapacity(totalElements)

            for i in 0..<accessor.count {
                let elementOffset = byteOffset + i * byteStride

                for j in 0..<accessor.componentCount {
                    let componentOffset = elementOffset + j * accessor.componentByteSize
                    let value = readComponent(
                        data: bufferViewData,
                        offset: componentOffset,
                        componentType: accessor.componentTypeEnum,
                        normalized: accessor.normalized ?? false
                    )
                    result.append(value)
                }
            }
        } else {
            // No bufferView - initialize with zeros
            result = [Float](repeating: 0, count: totalElements)
        }

        // Step 2: Apply sparse overrides (if present)
        if let sparse = accessor.sparse {

            // Read sparse indices
            let indicesBufferViewData = try getBufferViewData(bufferViewIndex: sparse.indices.bufferView)
            let indicesByteOffset = sparse.indices.byteOffset ?? 0
            let indicesComponentType = GLTFComponentType(rawValue: sparse.indices.componentType) ?? .unsignedShort

            var sparseIndices = [Int]()
            sparseIndices.reserveCapacity(sparse.count)

            for i in 0..<sparse.count {
                let offset = indicesByteOffset + i * indicesComponentType.byteSize
                let indexValue: Int = indicesBufferViewData.withUnsafeBytes { buffer in
                    switch indicesComponentType {
                    case .unsignedByte:
                        return Int(buffer.load(fromByteOffset: offset, as: UInt8.self))
                    case .unsignedShort:
                        return Int(buffer.load(fromByteOffset: offset, as: UInt16.self))
                    case .unsignedInt:
                        return Int(buffer.load(fromByteOffset: offset, as: UInt32.self))
                    default:
                        return 0
                    }
                }
                sparseIndices.append(indexValue)
            }

            // Read sparse values
            let valuesBufferViewData = try getBufferViewData(bufferViewIndex: sparse.values.bufferView)
            let valuesByteOffset = sparse.values.byteOffset ?? 0
            let valueStride = accessor.elementByteSize

            for (sparseIndex, targetIndex) in sparseIndices.enumerated() {
                let valueOffset = valuesByteOffset + sparseIndex * valueStride

                for j in 0..<accessor.componentCount {
                    let componentOffset = valueOffset + j * accessor.componentByteSize
                    let value = readComponent(
                        data: valuesBufferViewData,
                        offset: componentOffset,
                        componentType: accessor.componentTypeEnum,
                        normalized: accessor.normalized ?? false
                    )

                    // Apply sparse value to result array
                    let resultIndex = targetIndex * accessor.componentCount + j
                    if resultIndex < result.count {
                        result[resultIndex] = value
                    }
                }
            }
        }

        return result
    }

    /// Get accessor data as UInt32 array (for indices AND joints)
    func getAccessorDataAsUInt32(accessorIndex: Int) throws -> [UInt32] {
        guard let accessors = document.accessors,
              accessorIndex < accessors.count else {
            throw VRM1Error.accessorIndexOutOfBounds(accessorIndex)
        }

        let accessor = accessors[accessorIndex]

        guard let bufferViewIndex = accessor.bufferView else {
            return []
        }

        let bufferViewData = try getBufferViewData(bufferViewIndex: bufferViewIndex)
        let byteOffset = accessor.byteOffset ?? 0

        guard let bufferViews = document.bufferViews else {
            throw VRM1Error.bufferViewIndexOutOfBounds(bufferViewIndex)
        }
        let bufferView = bufferViews[bufferViewIndex]
        // Strideが指定されていない場合は、要素サイズ（密な配列）とみなす
        let byteStride = bufferView.byteStride ?? accessor.elementByteSize

        var result = [UInt32]()
        result.reserveCapacity(accessor.count * accessor.componentCount)

        for i in 0..<accessor.count {
            let elementOffset = byteOffset + i * byteStride

            for j in 0..<accessor.componentCount {
                let componentOffset = elementOffset + j * accessor.componentByteSize

                var value: UInt32 = 0

                // バッファ範囲チェック
                if componentOffset < bufferViewData.count {
                    // ★決定版: Dataのインデックスアクセスで確実に1バイトずつ読む
                    let startIndex = bufferViewData.startIndex + componentOffset

                    switch accessor.componentTypeEnum {
                    case .unsignedByte: // 1 byte (5121)
                        value = UInt32(bufferViewData[startIndex])

                    case .unsignedShort: // 2 bytes (5123)
                        if startIndex + 1 < bufferViewData.endIndex {
                            let b0 = UInt32(bufferViewData[startIndex])
                            let b1 = UInt32(bufferViewData[startIndex + 1])
                            value = b0 | (b1 << 8) // Little Endian
                        }

                    case .unsignedInt: // 4 bytes (5125)
                        if startIndex + 3 < bufferViewData.endIndex {
                            let b0 = UInt32(bufferViewData[startIndex])
                            let b1 = UInt32(bufferViewData[startIndex + 1])
                            let b2 = UInt32(bufferViewData[startIndex + 2])
                            let b3 = UInt32(bufferViewData[startIndex + 3])
                            value = b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
                        }

                    case .byte: // 1 byte signed (5120)
                        let v = Int8(bitPattern: bufferViewData[startIndex])
                        value = UInt32(bitPattern: Int32(v))

                    case .short: // 2 bytes signed (5122)
                        if startIndex + 1 < bufferViewData.endIndex {
                            let b0 = UInt32(bufferViewData[startIndex])
                            let b1 = UInt32(bufferViewData[startIndex + 1])
                            let u16 = UInt16(b0 | (b1 << 8))
                            let v = Int16(bitPattern: u16)
                            value = UInt32(bitPattern: Int32(v))
                        }

                    default:
                        value = 0
                    }
                }

                result.append(value)
            }
        }

        return result
    }

    /// Read a single component value
    private func readComponent(
        data: Data,
        offset: Int,
        componentType: GLTFComponentType,
        normalized: Bool
    ) -> Float {
        // ★修正: 厳密な境界チェック（データ型サイズ分を考慮）
        guard offset >= 0 else { return 0 }

        let typeSize = componentType.byteSize
        guard offset + typeSize <= data.count else {
            return 0
        }

        let rawValue: Float = data.withUnsafeBytes { buffer in
            switch componentType {
            case .byte:
                let v = buffer.load(fromByteOffset: offset, as: Int8.self)
                return normalized ? max(Float(v) / 127.0, -1.0) : Float(v)
            case .unsignedByte:
                let v = buffer.load(fromByteOffset: offset, as: UInt8.self)
                return normalized ? Float(v) / 255.0 : Float(v)
            case .short:
                let v = buffer.load(fromByteOffset: offset, as: Int16.self)
                return normalized ? max(Float(v) / 32767.0, -1.0) : Float(v)
            case .unsignedShort:
                let v = buffer.load(fromByteOffset: offset, as: UInt16.self)
                return normalized ? Float(v) / 65535.0 : Float(v)
            case .unsignedInt:
                let v = buffer.load(fromByteOffset: offset, as: UInt32.self)
                return Float(v)
            case .float:
                return buffer.load(fromByteOffset: offset, as: Float.self)
            }
        }

        return rawValue
    }

    /// Decode base64 data URI
    private func decodeDataURI(_ uri: String) throws -> Data {
        // Format: data:[<mediatype>][;base64],<data>
        guard let commaIndex = uri.firstIndex(of: ",") else {
            throw VRM1Error.invalidBufferData
        }

        let base64String = String(uri[uri.index(after: commaIndex)...])

        guard let data = Data(base64Encoded: base64String) else {
            throw VRM1Error.invalidBufferData
        }

        return data
    }
}

// MARK: - Image Data Access

public extension GLTFBinaryParser.ParseResult {

    /// Get image data for the specified image index
    func getImageData(imageIndex: Int) throws -> Data {
        guard let images = document.images,
              imageIndex < images.count else {
            throw VRM1Error.imageIndexOutOfBounds(imageIndex)
        }

        let image = images[imageIndex]

        // Image from buffer view
        if let bufferViewIndex = image.bufferView {
            return try getBufferViewData(bufferViewIndex: bufferViewIndex)
        }

        // Image from URI
        if let uri = image.uri {
            if uri.hasPrefix("data:") {
                return try decodeDataURI(uri)
            } else {
                throw VRM1Error.fileNotFound(uri)
            }
        }

        throw VRM1Error.imageDecodingFailed
    }
}
