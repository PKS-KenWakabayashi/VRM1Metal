import Foundation
import simd
import Compression

/// FBX Binary format animation loader
/// Extracts animation curves from FBX files for VRM character animation
public final class FBXAnimationLoader {

    // MARK: - FBX Node Structure

    private struct FBXNode {
        let name: String
        let properties: [FBXProperty]
        var children: [FBXNode]
    }

    private enum FBXProperty {
        case int16(Int16)
        case bool(Bool)
        case int32(Int32)
        case float(Float)
        case double(Double)
        case int64(Int64)
        case floatArray([Float])
        case doubleArray([Double])
        case int64Array([Int64])
        case int32Array([Int32])
        case boolArray([Bool])
        case string(String)
        case rawData(Data)
    }

    // MARK: - Animation Data Structures

    public struct AnimationCurve {
        public let boneName: String
        public let times: [Float]
        public let rotations: [simd_quatf]
        public let translations: [SIMD3<Float>]?
        public let scales: [SIMD3<Float>]?
    }

    public struct FBXAnimation {
        public let name: String
        public let duration: Float
        public let curves: [String: AnimationCurve]  // bone name -> curve
    }

    // MARK: - Parsing State

    private var data: Data = Data()
    private var offset: Int = 0
    private var version: UInt32 = 0

    // MARK: - Public API

    public init() {}

    /// Load animation from FBX file
    public func loadAnimation(from url: URL) throws -> FBXAnimation {
        data = try Data(contentsOf: url)
        offset = 0

        // Parse header
        try parseHeader()

        // Parse root nodes
        var rootNodes: [FBXNode] = []
        while offset < data.count - 13 {  // 13 bytes for null terminator node
            if let node = try parseNode() {
                rootNodes.append(node)
            } else {
                break
            }
        }

        // Extract animation data
        return try extractAnimation(from: rootNodes, fileName: url.deletingPathExtension().lastPathComponent)
    }

    // MARK: - Header Parsing

    private func parseHeader() throws {
        // Check magic bytes: "Kaydara FBX Binary  \0"
        let magic = "Kaydara FBX Binary  "
        guard data.count >= 27 else {
            throw FBXError.invalidFormat("File too small")
        }

        let headerString = String(data: data.subdata(in: 0..<20), encoding: .utf8)
        guard headerString == magic else {
            throw FBXError.invalidFormat("Invalid FBX magic bytes")
        }

        offset = 23  // Skip magic + 2 unknown bytes + null

        // Read version (little-endian uint32)
        version = readUInt32()
    }

    // MARK: - Node Parsing

    private func parseNode() throws -> FBXNode? {
        let nodeStart = offset

        // Read node record header
        let endOffset: UInt64
        let numProperties: UInt64
        let propertyListLen: UInt64

        if version >= 7500 {
            // 64-bit offsets for FBX 7.5+
            endOffset = readUInt64()
            numProperties = readUInt64()
            propertyListLen = readUInt64()
        } else {
            // 32-bit offsets for older versions
            endOffset = UInt64(readUInt32())
            numProperties = UInt64(readUInt32())
            propertyListLen = UInt64(readUInt32())
        }

        // Null node check
        if endOffset == 0 {
            return nil
        }

        // Read node name
        let nameLen = readUInt8()
        let name = readString(length: Int(nameLen))

        // Read properties
        var properties: [FBXProperty] = []
        let propertyStart = offset
        for _ in 0..<numProperties {
            if let prop = try parseProperty() {
                properties.append(prop)
            }
        }
        offset = propertyStart + Int(propertyListLen)

        // Read children
        var children: [FBXNode] = []
        while offset < Int(endOffset) - 13 {
            if let child = try parseNode() {
                children.append(child)
            } else {
                break
            }
        }

        offset = Int(endOffset)

        return FBXNode(name: name, properties: properties, children: children)
    }

    private func parseProperty() throws -> FBXProperty? {
        guard offset < data.count else { return nil }

        let typeCode = Character(UnicodeScalar(data[offset]))
        offset += 1

        switch typeCode {
        case "Y":  // Int16
            return .int16(readInt16())
        case "C":  // Bool
            return .bool(readUInt8() != 0)
        case "I":  // Int32
            return .int32(readInt32())
        case "F":  // Float
            return .float(readFloat())
        case "D":  // Double
            return .double(readDouble())
        case "L":  // Int64
            return .int64(readInt64())
        case "f":  // Float array
            return .floatArray(try readFloatArray())
        case "d":  // Double array
            return .doubleArray(try readDoubleArray())
        case "l":  // Int64 array
            return .int64Array(try readInt64Array())
        case "i":  // Int32 array
            return .int32Array(try readInt32Array())
        case "b":  // Bool array
            return .boolArray(try readBoolArray())
        case "S":  // String
            let length = readUInt32()
            return .string(readString(length: Int(length)))
        case "R":  // Raw data
            let length = readUInt32()
            return .rawData(readData(length: Int(length)))
        default:
            throw FBXError.invalidFormat("Unknown property type: \(typeCode)")
        }
    }

    // MARK: - Primitive Reading

    private func readUInt8() -> UInt8 {
        let value = data[offset]
        offset += 1
        return value
    }

    private func readInt16() -> Int16 {
        let value = data.subdata(in: offset..<offset+2).withUnsafeBytes { $0.load(as: Int16.self) }
        offset += 2
        return value
    }

    private func readUInt32() -> UInt32 {
        let value = data.subdata(in: offset..<offset+4).withUnsafeBytes { $0.load(as: UInt32.self) }
        offset += 4
        return value
    }

    private func readInt32() -> Int32 {
        let value = data.subdata(in: offset..<offset+4).withUnsafeBytes { $0.load(as: Int32.self) }
        offset += 4
        return value
    }

    private func readUInt64() -> UInt64 {
        let value = data.subdata(in: offset..<offset+8).withUnsafeBytes { $0.load(as: UInt64.self) }
        offset += 8
        return value
    }

    private func readInt64() -> Int64 {
        let value = data.subdata(in: offset..<offset+8).withUnsafeBytes { $0.load(as: Int64.self) }
        offset += 8
        return value
    }

    private func readFloat() -> Float {
        let value = data.subdata(in: offset..<offset+4).withUnsafeBytes { $0.load(as: Float.self) }
        offset += 4
        return value
    }

    private func readDouble() -> Double {
        let value = data.subdata(in: offset..<offset+8).withUnsafeBytes { $0.load(as: Double.self) }
        offset += 8
        return value
    }

    private func readString(length: Int) -> String {
        guard length > 0 else { return "" }
        let strData = data.subdata(in: offset..<offset+length)
        offset += length
        return String(data: strData, encoding: .utf8) ?? ""
    }

    private func readData(length: Int) -> Data {
        let result = data.subdata(in: offset..<offset+length)
        offset += length
        return result
    }

    // MARK: - Array Reading

    private func readArrayHeader() throws -> (count: Int, encoding: UInt32, compressedLength: Int) {
        let count = Int(readUInt32())
        let encoding = readUInt32()
        let compressedLength = Int(readUInt32())
        return (count, encoding, compressedLength)
    }

    private func readFloatArray() throws -> [Float] {
        let (count, encoding, compressedLength) = try readArrayHeader()

        if encoding == 0 {
            // Uncompressed
            var result: [Float] = []
            for _ in 0..<count {
                result.append(readFloat())
            }
            return result
        } else {
            // Compressed (zlib)
            let compressedData = readData(length: compressedLength)
            let decompressed = try decompressZlib(compressedData)
            return decompressed.withUnsafeBytes { buffer in
                Array(buffer.bindMemory(to: Float.self))
            }
        }
    }

    private func readDoubleArray() throws -> [Double] {
        let (count, encoding, compressedLength) = try readArrayHeader()

        if encoding == 0 {
            var result: [Double] = []
            for _ in 0..<count {
                result.append(readDouble())
            }
            return result
        } else {
            let compressedData = readData(length: compressedLength)
            let decompressed = try decompressZlib(compressedData)
            return decompressed.withUnsafeBytes { buffer in
                Array(buffer.bindMemory(to: Double.self))
            }
        }
    }

    private func readInt64Array() throws -> [Int64] {
        let (count, encoding, compressedLength) = try readArrayHeader()

        if encoding == 0 {
            var result: [Int64] = []
            for _ in 0..<count {
                result.append(readInt64())
            }
            return result
        } else {
            let compressedData = readData(length: compressedLength)
            let decompressed = try decompressZlib(compressedData)
            return decompressed.withUnsafeBytes { buffer in
                Array(buffer.bindMemory(to: Int64.self))
            }
        }
    }

    private func readInt32Array() throws -> [Int32] {
        let (count, encoding, compressedLength) = try readArrayHeader()

        if encoding == 0 {
            var result: [Int32] = []
            for _ in 0..<count {
                result.append(readInt32())
            }
            return result
        } else {
            let compressedData = readData(length: compressedLength)
            let decompressed = try decompressZlib(compressedData)
            return decompressed.withUnsafeBytes { buffer in
                Array(buffer.bindMemory(to: Int32.self))
            }
        }
    }

    private func readBoolArray() throws -> [Bool] {
        let (count, encoding, compressedLength) = try readArrayHeader()

        if encoding == 0 {
            var result: [Bool] = []
            for _ in 0..<count {
                result.append(readUInt8() != 0)
            }
            return result
        } else {
            let compressedData = readData(length: compressedLength)
            let decompressed = try decompressZlib(compressedData)
            return decompressed.map { $0 != 0 }
        }
    }

    private func decompressZlib(_ data: Data) throws -> Data {
        // Use Compression framework for zlib decompression
        // Estimate decompressed size (typical compression ratio ~3-4x)
        var destinationBuffer = [UInt8](repeating: 0, count: data.count * 10)

        let decompressedSize = data.withUnsafeBytes { sourceBuffer -> Int in
            guard let sourcePtr = sourceBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return 0
            }
            return compression_decode_buffer(
                &destinationBuffer,
                destinationBuffer.count,
                sourcePtr,
                data.count,
                nil,
                COMPRESSION_ZLIB
            )
        }

        guard decompressedSize > 0 else {
            throw FBXError.decompressionFailed
        }

        return Data(destinationBuffer.prefix(decompressedSize))
    }

    // MARK: - Animation Extraction

    private func extractAnimation(from nodes: [FBXNode], fileName: String) throws -> FBXAnimation {
        // Find Objects node
        guard let objectsNode = nodes.first(where: { $0.name == "Objects" }) else {
            throw FBXError.invalidFormat("No Objects node found")
        }

        // Find AnimationStack, AnimationLayer, AnimationCurveNode, AnimationCurve
        var animationCurves: [Int64: [Double]] = [:]  // ID -> keyframe values
        var animationTimes: [Int64: [Double]] = [:]    // ID -> keyframe times
        var curveNodeConnections: [Int64: (boneID: Int64, property: String)] = [:]
        var boneNames: [Int64: String] = [:]  // bone ID -> bone name

        // Parse all objects
        for child in objectsNode.children {
            switch child.name {
            case "Model":
                // Extract bone name and ID
                if let id = extractInt64(from: child.properties, at: 0),
                   let nameStr = extractString(from: child.properties, at: 1) {
                    // Name format: "BoneName\x00\x01Model"
                    let boneName = nameStr.components(separatedBy: "\0").first ?? nameStr
                    boneNames[id] = boneName
                }

            case "AnimationCurve":
                // Extract keyframe data
                if let id = extractInt64(from: child.properties, at: 0) {

                    // Find KeyTime and KeyValueFloat/Default children
                    for subChild in child.children {
                        if subChild.name == "KeyTime" {
                            if case .int64Array(let times) = subChild.properties.first {
                                animationTimes[id] = times.map { Double($0) / 46186158000.0 }  // FBX time to seconds
                            }
                        } else if subChild.name == "KeyValueFloat" || subChild.name == "Default" {
                            if case .floatArray(let values) = subChild.properties.first {
                                animationCurves[id] = values.map { Double($0) }
                            } else if case .doubleArray(let values) = subChild.properties.first {
                                animationCurves[id] = values
                            } else if case .float(let value) = subChild.properties.first {
                                animationCurves[id] = [Double(value)]
                            } else if case .double(let value) = subChild.properties.first {
                                animationCurves[id] = [value]
                            }
                        }
                    }
                }

            case "AnimationCurveNode":
                // Extract connection info
                if let id = extractInt64(from: child.properties, at: 0),
                   let nameStr = extractString(from: child.properties, at: 1) {
                    // Name format: "T", "R", or "S" for translate, rotate, scale
                    let property = nameStr.components(separatedBy: "\0").first ?? nameStr
                    curveNodeConnections[id] = (boneID: 0, property: property)
                }

            default:
                break
            }
        }

        var connectionCount = 0
        if let connectionsNode = nodes.first(where: { $0.name == "Connections" }) {
            for child in connectionsNode.children {
                if child.name == "C" && child.properties.count >= 3 {
                    // Handle both "OO" and "OP" connections
                    if let srcID = extractInt64(from: child.properties, at: 1),
                       let dstID = extractInt64(from: child.properties, at: 2) {
                        // Link AnimationCurveNode to Model (bone)
                        if var connection = curveNodeConnections[srcID] {
                            connection.boneID = dstID
                            curveNodeConnections[srcID] = connection
                            connectionCount += 1
                        }
                    }
                }
            }
        }

        // Build animation curves per bone
        var boneCurves: [String: AnimationCurve] = [:]
        var maxDuration: Float = 0

        // Track curve node to curve ID mappings with axis info
        struct CurveAxisInfo {
            var xCurveID: Int64?
            var yCurveID: Int64?
            var zCurveID: Int64?
        }
        var curveNodeToCurves: [Int64: CurveAxisInfo] = [:]

        // Find connections from AnimationCurve to AnimationCurveNode
        if let connectionsNode = nodes.first(where: { $0.name == "Connections" }) {
            for child in connectionsNode.children {
                if child.name == "C" && child.properties.count >= 4 {
                    // OP connection with property name (d|X, d|Y, d|Z)
                    if case .string(let connType) = child.properties[0], connType == "OP",
                       let srcID = extractInt64(from: child.properties, at: 1),
                       let dstID = extractInt64(from: child.properties, at: 2) {
                        // srcID is AnimationCurve, dstID is AnimationCurveNode
                        if animationCurves[srcID] != nil {
                            if curveNodeToCurves[dstID] == nil {
                                curveNodeToCurves[dstID] = CurveAxisInfo()
                            }
                            // Check property name for axis
                            if case .string(let propName) = child.properties[3] {
                                if propName.contains("X") || propName.hasSuffix("X") {
                                    curveNodeToCurves[dstID]?.xCurveID = srcID
                                } else if propName.contains("Y") || propName.hasSuffix("Y") {
                                    curveNodeToCurves[dstID]?.yCurveID = srcID
                                } else if propName.contains("Z") || propName.hasSuffix("Z") {
                                    curveNodeToCurves[dstID]?.zCurveID = srcID
                                }
                            }
                        }
                    }
                } else if child.name == "C" && child.properties.count >= 3 {
                    // OO connection (fallback, assume order)
                    if let srcID = extractInt64(from: child.properties, at: 1),
                       let dstID = extractInt64(from: child.properties, at: 2) {
                        if animationCurves[srcID] != nil {
                            if curveNodeToCurves[dstID] == nil {
                                curveNodeToCurves[dstID] = CurveAxisInfo()
                            }
                            // Add in order (X, Y, Z)
                            if curveNodeToCurves[dstID]?.xCurveID == nil {
                                curveNodeToCurves[dstID]?.xCurveID = srcID
                            } else if curveNodeToCurves[dstID]?.yCurveID == nil {
                                curveNodeToCurves[dstID]?.yCurveID = srcID
                            } else if curveNodeToCurves[dstID]?.zCurveID == nil {
                                curveNodeToCurves[dstID]?.zCurveID = srcID
                            }
                        }
                    }
                }
            }
        }

        // Group rotation data by bone
        struct BoneRotationData {
            var times: [Float] = []
            var xValues: [Double] = []
            var yValues: [Double] = []
            var zValues: [Double] = []
        }
        var boneRotations: [String: BoneRotationData] = [:]
        var rotationNodeCount = 0
        for (curveNodeID, connection) in curveNodeConnections {
            guard let boneName = boneNames[connection.boneID] else { continue }
            guard connection.property == "R" || connection.property.hasPrefix("Lcl Rotation") else { continue }
            rotationNodeCount += 1

            guard let curveInfo = curveNodeToCurves[curveNodeID] else { continue }

            // Get X, Y, Z curves using axis info
            var data = BoneRotationData()

            if let xID = curveInfo.xCurveID, let xValues = animationCurves[xID] {
                data.xValues = xValues
                if let times = animationTimes[xID] {
                    data.times = times.map { Float($0) }
                    if let lastTime = data.times.last, lastTime > maxDuration {
                        maxDuration = lastTime
                    }
                }
            }
            if let yID = curveInfo.yCurveID, let yValues = animationCurves[yID] {
                data.yValues = yValues
            }
            if let zID = curveInfo.zCurveID, let zValues = animationCurves[zID] {
                data.zValues = zValues
            }

            if !data.times.isEmpty && !data.xValues.isEmpty && !data.yValues.isEmpty && !data.zValues.isEmpty {
                boneRotations[boneName] = data
            } else if !data.xValues.isEmpty || !data.yValues.isEmpty || !data.zValues.isEmpty {
                // Fill missing axes with zeros
                let count = max(data.xValues.count, max(data.yValues.count, data.zValues.count))
                if data.xValues.isEmpty { data.xValues = [Double](repeating: 0, count: count) }
                if data.yValues.isEmpty { data.yValues = [Double](repeating: 0, count: count) }
                if data.zValues.isEmpty { data.zValues = [Double](repeating: 0, count: count) }
                if data.times.isEmpty { data.times = (0..<count).map { Float($0) / 30.0 } }  // Assume 30fps
                boneRotations[boneName] = data
            }
        }

        // Convert Euler angles to quaternions
        for (boneName, data) in boneRotations {
            let keyframeCount = min(data.times.count, data.xValues.count, data.yValues.count, data.zValues.count)
            guard keyframeCount > 0 else { continue }

            var rotations: [simd_quatf] = []
            for i in 0..<keyframeCount {
                // FBX uses degrees, convert to radians
                let rx = Float(data.xValues[i]) * .pi / 180.0
                let ry = Float(data.yValues[i]) * .pi / 180.0
                let rz = Float(data.zValues[i]) * .pi / 180.0

                // Convert Euler XYZ to quaternion
                let qx = simd_quatf(angle: rx, axis: SIMD3<Float>(1, 0, 0))
                let qy = simd_quatf(angle: ry, axis: SIMD3<Float>(0, 1, 0))
                let qz = simd_quatf(angle: rz, axis: SIMD3<Float>(0, 0, 1))
                let rotation = qz * qy * qx  // ZYX order (common in FBX)
                rotations.append(rotation)
            }

            let curve = AnimationCurve(
                boneName: boneName,
                times: Array(data.times.prefix(keyframeCount)),
                rotations: rotations,
                translations: nil,
                scales: nil
            )
            boneCurves[boneName] = curve
        }

        return FBXAnimation(
            name: fileName,
            duration: max(maxDuration, 1.0),
            curves: boneCurves
        )
    }

    private func extractInt64(from properties: [FBXProperty], at index: Int) -> Int64? {
        guard index < properties.count else { return nil }
        if case .int64(let value) = properties[index] {
            return value
        }
        return nil
    }

    private func extractString(from properties: [FBXProperty], at index: Int) -> String? {
        guard index < properties.count else { return nil }
        if case .string(let value) = properties[index] {
            return value
        }
        return nil
    }
}

// MARK: - Errors

public enum FBXError: Error {
    case invalidFormat(String)
    case decompressionFailed
    case unsupportedVersion(UInt32)
}
