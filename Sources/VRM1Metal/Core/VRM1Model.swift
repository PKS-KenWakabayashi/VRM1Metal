import Foundation
import simd
import Metal

/// Complete VRM 1.0 model representation
public final class VRM1Model {

    // MARK: - Properties

    /// Original glTF document
    public let document: GLTFDocument

    /// Parsed binary data
    public let parseResult: GLTFBinaryParser.ParseResult

    /// Scene graph root nodes
    public private(set) var rootNodes: [VRM1Node] = []

    /// All nodes in the scene
    public private(set) var allNodes: [VRM1Node] = []

    /// All meshes
    public private(set) var meshes: [VRM1Mesh] = []

    /// All materials
    public private(set) var materials: [VRM1Material] = []

    /// Skeleton/skin data
    public private(set) var skins: [VRM1Skin] = []

    /// VRM metadata
    public private(set) var meta: VRMMeta?

    /// VRM humanoid bone mapping
    public private(set) var humanoid: VRMHumanoid?

    /// VRM expressions
    public private(set) var expressions: VRMExpressions?

    /// VRM look-at settings
    public private(set) var lookAt: VRMLookAt?

    /// VRM first-person settings
    public private(set) var firstPerson: VRMFirstPerson?

    // MARK: - Initialization

    public init(parseResult: GLTFBinaryParser.ParseResult) throws {
        self.document = parseResult.document
        self.parseResult = parseResult

        // Build scene graph
        try buildSceneGraph()

        // Parse VRM extensions
        try parseVRMExtensions()
    }

    // MARK: - Scene Graph Building

    private func buildSceneGraph() throws {
        // Create all nodes
        if let nodes = document.nodes {
            allNodes = nodes.enumerated().map { index, gltfNode in
                VRM1Node(index: index, gltfNode: gltfNode)
            }
        }

        // Set up parent-child relationships
        for (index, gltfNode) in (document.nodes ?? []).enumerated() {
            if let children = gltfNode.children {
                for childIndex in children {
                    guard childIndex < allNodes.count else { continue }
                    allNodes[index].children.append(allNodes[childIndex])
                    allNodes[childIndex].parent = allNodes[index]
                }
            }
        }

        // Find root nodes
        rootNodes = allNodes.filter { $0.parent == nil }

        // Build meshes
        try buildMeshes()

        // Build materials
        try buildMaterials()

        // Build skins
        try buildSkins()

        // Assign meshes to nodes
        for node in allNodes {
            if let meshIndex = node.gltfNode.mesh, meshIndex < meshes.count {
                node.mesh = meshes[meshIndex]
            }
            if let skinIndex = node.gltfNode.skin, skinIndex < skins.count {
                node.skin = skins[skinIndex]
            }
        }

        // Compute initial world transforms
        updateWorldTransforms()
    }

    private func buildMeshes() throws {
        guard let gltfMeshes = document.meshes else { return }

        for (meshIndex, gltfMesh) in gltfMeshes.enumerated() {
            var primitives: [VRM1Primitive] = []

            for gltfPrimitive in gltfMesh.primitives {
                let primitive = try buildPrimitive(gltfPrimitive)
                primitives.append(primitive)
            }

            // Determine morph weight count from glTF weights or from morph targets in primitives
            var morphWeights: [Float]
            if let weights = gltfMesh.weights, !weights.isEmpty {
                morphWeights = weights.map { Float($0) }
            } else {
                // Calculate max morph target count across all primitives
                let maxMorphTargetCount = primitives.map { $0.morphTargets.count }.max() ?? 0
                morphWeights = [Float](repeating: 0.0, count: maxMorphTargetCount)
            }

            // Extract morph target names from extras
            var targetNames: [String]?
            if let extras = gltfMesh.extras?.dictionary,
               let names = extras["targetNames"] as? [String] {
                targetNames = names
            } else if let firstPrimitive = gltfMesh.primitives.first,
                      let extras = firstPrimitive.extras?.dictionary,
                      let names = extras["targetNames"] as? [String] {
                targetNames = names
            }

            let mesh = VRM1Mesh(
                index: meshIndex,
                name: gltfMesh.name,
                primitives: primitives,
                morphWeights: morphWeights,
                morphTargetNames: targetNames
            )
            meshes.append(mesh)
        }
    }

    private func buildPrimitive(_ gltfPrimitive: GLTFPrimitive) throws -> VRM1Primitive {
        // Get position data (required)
        guard let positionAccessorIndex = gltfPrimitive.attributes["POSITION"] else {
            throw VRM1Error.primitiveHasNoPositions
        }
        let positions = try parseResult.getAccessorDataAsFloats(accessorIndex: positionAccessorIndex)

        // Get normal data (optional)
        var normals: [Float]?
        if let normalAccessorIndex = gltfPrimitive.attributes["NORMAL"] {
            normals = try parseResult.getAccessorDataAsFloats(accessorIndex: normalAccessorIndex)
        }

        // Get UV data (optional)
        var texCoords: [Float]?
        if let uvAccessorIndex = gltfPrimitive.attributes["TEXCOORD_0"] {
            texCoords = try parseResult.getAccessorDataAsFloats(accessorIndex: uvAccessorIndex)
        }

        // Get tangent data (optional)
        var tangents: [Float]?
        if let tangentAccessorIndex = gltfPrimitive.attributes["TANGENT"] {
            tangents = try parseResult.getAccessorDataAsFloats(accessorIndex: tangentAccessorIndex)
        }

        // Get joint indices (optional, for skinning)
        var joints: [UInt32]?
        if let jointsAccessorIndex = gltfPrimitive.attributes["JOINTS_0"] {
            joints = try? parseResult.getAccessorDataAsUInt32(accessorIndex: jointsAccessorIndex)
        }

        // Get joint weights (optional, for skinning)
        var weights: [Float]?
        if let weightsAccessorIndex = gltfPrimitive.attributes["WEIGHTS_0"] {
            weights = try? parseResult.getAccessorDataAsFloats(accessorIndex: weightsAccessorIndex)
        }

        // Get indices (optional)
        var indices: [UInt32]?
        if let indicesAccessorIndex = gltfPrimitive.indices {
            indices = try parseResult.getAccessorDataAsUInt32(accessorIndex: indicesAccessorIndex)
        }

        // Parse morph targets
        var morphTargets: [VRM1MorphTarget] = []
        if let targets = gltfPrimitive.targets {
            for (targetIndex, target) in targets.enumerated() {
                var positionDeltas: [Float]?
                var normalDeltas: [Float]?

                if let posIndex = target["POSITION"] {
                    positionDeltas = try parseResult.getAccessorDataAsFloats(accessorIndex: posIndex)
                }
                if let normIndex = target["NORMAL"] {
                    normalDeltas = try parseResult.getAccessorDataAsFloats(accessorIndex: normIndex)
                }

                morphTargets.append(VRM1MorphTarget(
                    index: targetIndex,
                    positionDeltas: positionDeltas ?? [],
                    normalDeltas: normalDeltas ?? []
                ))
            }
        }

        return VRM1Primitive(
            positions: positions,
            normals: normals,
            texCoords: texCoords,
            tangents: tangents,
            joints: joints,
            weights: weights,
            indices: indices,
            materialIndex: gltfPrimitive.material,
            morphTargets: morphTargets,
            mode: gltfPrimitive.renderMode
        )
    }

    private func buildMaterials() throws {
        guard let gltfMaterials = document.materials else { return }

        // Check for VRM 0.x material properties
        var vrm0MaterialProps: [[String: Any]]? = nil
        if let extensions = document.extensions,
           let vrmExt = extensions["VRM"]?.dictionary,
           let materialProperties = vrmExt["materialProperties"] as? [[String: Any]] {
            vrm0MaterialProps = materialProperties
        }

        for (index, gltfMaterial) in gltfMaterials.enumerated() {
            // Get VRM 0.x material properties for this material if available
            let vrm0Props = (vrm0MaterialProps != nil && index < vrm0MaterialProps!.count) ? vrm0MaterialProps![index] : nil
            let material = VRM1Material(gltfMaterial: gltfMaterial, vrm0MaterialProps: vrm0Props)
            materials.append(material)
        }
    }

    private func buildSkins() throws {
        guard let gltfSkins = document.skins else { return }

        for gltfSkin in gltfSkins {
            var inverseBindMatrices: [simd_float4x4] = []

            if let ibmAccessorIndex = gltfSkin.inverseBindMatrices {
                let ibmData = try parseResult.getAccessorDataAsFloats(accessorIndex: ibmAccessorIndex)

                // Convert flat array to matrices
                let matrixCount = ibmData.count / 16
                for i in 0..<matrixCount {
                    let offset = i * 16
                    let matrix = simd_float4x4(
                        SIMD4<Float>(ibmData[offset], ibmData[offset+1], ibmData[offset+2], ibmData[offset+3]),
                        SIMD4<Float>(ibmData[offset+4], ibmData[offset+5], ibmData[offset+6], ibmData[offset+7]),
                        SIMD4<Float>(ibmData[offset+8], ibmData[offset+9], ibmData[offset+10], ibmData[offset+11]),
                        SIMD4<Float>(ibmData[offset+12], ibmData[offset+13], ibmData[offset+14], ibmData[offset+15])
                    )
                    inverseBindMatrices.append(matrix)
                }
            }

            let jointNodes = gltfSkin.joints.compactMap { jointIndex -> VRM1Node? in
                guard jointIndex < allNodes.count else { return nil }
                return allNodes[jointIndex]
            }

            let skin = VRM1Skin(
                name: gltfSkin.name,
                joints: jointNodes,
                inverseBindMatrices: inverseBindMatrices
            )
            skins.append(skin)
        }
    }

    // MARK: - VRM Extension Parsing

    private func parseVRMExtensions() throws {
        // Try VRM 1.0 first (VRMC_vrm)
        if let extensions = document.extensions,
           let vrmExtension = extensions["VRMC_vrm"]?.dictionary {
            parseVRM1Extensions(vrmExtension)
            return
        }

        // Try VRM 0.x (VRM)
        if let extensions = document.extensions,
           let vrmExtension = extensions["VRM"]?.dictionary {
            parseVRM0Extensions(vrmExtension)
            return
        }
    }

    private func parseVRM1Extensions(_ vrmExtension: [String: Any]) {

        // Parse meta
        if let metaDict = vrmExtension["meta"] as? [String: Any] {
            meta = VRMMeta(from: metaDict)
        }

        // Parse humanoid
        if let humanoidDict = vrmExtension["humanoid"] as? [String: Any] {
            humanoid = VRMHumanoid(from: humanoidDict, nodes: allNodes)
        }

        // Parse expressions
        if let expressionsDict = vrmExtension["expressions"] as? [String: Any] {
            expressions = VRMExpressions(from: expressionsDict)
        } else {
            // Try auto-mapping from morph target names
            expressions = VRMExpressions(autoMappingFromMeshes: meshes, document: document)
        }

        // Parse lookAt
        if let lookAtDict = vrmExtension["lookAt"] as? [String: Any] {
            lookAt = VRMLookAt(from: lookAtDict)
        }

        // Parse firstPerson
        if let firstPersonDict = vrmExtension["firstPerson"] as? [String: Any] {
            firstPerson = VRMFirstPerson(from: firstPersonDict)
        }
    }

    /// Parse VRM 0.x extensions (legacy format)
    private func parseVRM0Extensions(_ vrmExtension: [String: Any]) {
        // Parse meta
        if let metaDict = vrmExtension["meta"] as? [String: Any] {
            meta = VRMMeta(from: metaDict)
        }

        // Parse humanoid
        if let humanoidDict = vrmExtension["humanoid"] as? [String: Any] {
            humanoid = VRMHumanoid(from: humanoidDict, nodes: allNodes)
        }

        // Parse blendShapeMaster (VRM 0.x expressions)
        if let blendShapeMaster = vrmExtension["blendShapeMaster"] as? [String: Any],
           let blendShapeGroups = blendShapeMaster["blendShapeGroups"] as? [[String: Any]] {
            // Convert VRM 0.x blendShapeGroups to VRM 1.0 style expressions
            expressions = VRMExpressions(fromVRM0BlendShapeGroups: blendShapeGroups, meshes: meshes)
        } else {
            // Try auto-mapping from morph target names
            expressions = VRMExpressions(autoMappingFromMeshes: meshes, document: document)
        }
    }

    // MARK: - Transform Updates

    /// Update world transforms for all nodes
    public func updateWorldTransforms() {
        for rootNode in rootNodes {
            updateNodeTransform(rootNode, parentTransform: matrix_identity_float4x4)
        }
    }

    private func updateNodeTransform(_ node: VRM1Node, parentTransform: simd_float4x4) {
        node.worldTransform = parentTransform * node.localTransform
        for child in node.children {
            updateNodeTransform(child, parentTransform: node.worldTransform)
        }
    }

    // MARK: - Morph Weight Updates

    /// Set morph weight for a specific mesh at a given index
    public func setMorphWeight(meshIndex: Int, weightIndex: Int, value: Float) {
        guard meshIndex < meshes.count, weightIndex < meshes[meshIndex].morphWeights.count else {
            return
        }
        meshes[meshIndex].morphWeights[weightIndex] = value
    }

    /// Reset all morph weights for a mesh to zero
    public func resetMorphWeights(meshIndex: Int) {
        guard meshIndex < meshes.count else { return }
        for i in 0..<meshes[meshIndex].morphWeights.count {
            meshes[meshIndex].morphWeights[i] = 0
        }
    }

    /// Get mesh by index
    public func getMesh(at index: Int) -> VRM1Mesh? {
        guard index < meshes.count else { return nil }
        return meshes[index]
    }

    // MARK: - Material Texture Transform Updates (目のUVオフセット制御用)

    /// Get material by index
    public func getMaterial(at index: Int) -> VRM1Material? {
        guard index < materials.count else { return nil }
        return materials[index]
    }

    /// Set texture transform offset for a specific material (for eye UV control)
    /// - Parameters:
    ///   - materialIndex: Index of the material to modify
    ///   - offsetX: UV offset X (0.0 = center, positive = right, negative = left)
    ///   - offsetY: UV offset Y (0.0 = center, positive = up, negative = down)
    public func setMaterialTextureOffset(materialIndex: Int, offsetX: Float, offsetY: Float) {
        guard materialIndex < materials.count else { return }
        let current = materials[materialIndex].textureTransform
        // Keep scale (x, y), update offset (z, w)
        materials[materialIndex].textureTransform = SIMD4<Float>(current.x, current.y, offsetX, offsetY)
    }

    /// Find material indices by name (partial match)
    /// - Parameter nameContains: String to search for in material names
    /// - Returns: Array of material indices that match
    public func findMaterialIndices(nameContains: String) -> [Int] {
        var indices: [Int] = []
        for (index, material) in materials.enumerated() {
            if let name = material.name, name.lowercased().contains(nameContains.lowercased()) {
                indices.append(index)
            }
        }
        return indices
    }
}

// MARK: - VRM1Node

public final class VRM1Node {
    public let index: Int
    public let gltfNode: GLTFNode

    public var name: String? { gltfNode.name }

    public weak var parent: VRM1Node?
    public var children: [VRM1Node] = []

    public var mesh: VRM1Mesh?
    public var skin: VRM1Skin?

    public var localTransform: simd_float4x4
    public var worldTransform: simd_float4x4 = matrix_identity_float4x4

    /// Bind pose rotation (T-pose, stored at initialization)
    public let bindPoseRotation: simd_quatf

    /// Bind pose translation (stored at initialization)
    public let bindPoseTranslation: SIMD3<Float>

    /// Current animated rotation (updated by AnimationPlayer)
    public var currentRotation: simd_quatf

    /// Current animated translation (updated by AnimationPlayer)
    public var currentTranslation: SIMD3<Float>

    init(index: Int, gltfNode: GLTFNode) {
        self.index = index
        self.gltfNode = gltfNode
        self.localTransform = gltfNode.localTransform()

        // Store bind pose rotation (T-pose)
        let r = gltfNode.rotation ?? [0, 0, 0, 1]
        self.bindPoseRotation = simd_quatf(ix: r[0], iy: r[1], iz: r[2], r: r[3])
        self.currentRotation = self.bindPoseRotation

        // Store bind pose translation
        let t = gltfNode.translation ?? [0, 0, 0]
        self.bindPoseTranslation = SIMD3<Float>(t[0], t[1], t[2])
        self.currentTranslation = self.bindPoseTranslation
    }

    /// Set local rotation (quaternion) - combines with bind pose and rebuilds localTransform
    /// animationRotation is applied relative to bind pose: finalRotation = bindPose * animationRotation
    public func setRotation(_ animationRotation: simd_quatf) {
        // ★BindPoseを基準にアニメーション回転を適用
        currentRotation = bindPoseRotation * animationRotation
        rebuildLocalTransform()
    }

    /// Set local translation - stores translation and rebuilds localTransform
    public func setTranslation(_ translation: SIMD3<Float>) {
        currentTranslation = translation
        rebuildLocalTransform()
    }

    /// Apply additive rotation on top of current rotation (for procedural animation)
    /// This allows adding sway/breathing/gaze rotations after FBX animation
    public func applyAdditiveRotation(_ additiveRotation: simd_quatf) {
        currentRotation = currentRotation * additiveRotation
        rebuildLocalTransform()
    }

    /// Apply additive translation on top of current translation (for procedural animation)
    public func applyAdditiveTranslation(_ additiveTranslation: SIMD3<Float>) {
        currentTranslation = currentTranslation + additiveTranslation
        rebuildLocalTransform()
    }

    /// Rebuild localTransform from currentRotation, currentTranslation, and original scale
    private func rebuildLocalTransform() {
        let s = gltfNode.scale ?? [1, 1, 1]

        let translationMatrix = simd_float4x4(
            SIMD4<Float>(1, 0, 0, 0),
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(currentTranslation.x, currentTranslation.y, currentTranslation.z, 1)
        )

        let rotationMatrix = simd_float4x4(currentRotation)

        let scaleMatrix = simd_float4x4(
            SIMD4<Float>(s[0], 0, 0, 0),
            SIMD4<Float>(0, s[1], 0, 0),
            SIMD4<Float>(0, 0, s[2], 0),
            SIMD4<Float>(0, 0, 0, 1)
        )

        localTransform = translationMatrix * rotationMatrix * scaleMatrix
    }
}

// MARK: - VRM1Mesh

public struct VRM1Mesh {
    public let index: Int
    public let name: String?
    public let primitives: [VRM1Primitive]
    public var morphWeights: [Float]
    /// Morph target names (e.g., "blendShape1.MTH_A", "blendShape2.EYE_DEF_C")
    public let morphTargetNames: [String]?
}

// MARK: - VRM1Primitive

public struct VRM1Primitive {
    public let positions: [Float]
    public let normals: [Float]?
    public let texCoords: [Float]?
    public let tangents: [Float]?
    public let joints: [UInt32]?
    public let weights: [Float]?
    public let indices: [UInt32]?
    public let materialIndex: Int?
    public let morphTargets: [VRM1MorphTarget]
    public let mode: GLTFPrimitiveMode

    /// Number of vertices
    public var vertexCount: Int {
        positions.count / 3
    }
}

// MARK: - VRM1MorphTarget

public struct VRM1MorphTarget {
    public let index: Int
    public let positionDeltas: [Float]
    public let normalDeltas: [Float]
}

// MARK: - VRM1Material

public struct VRM1Material {
    public let name: String?
    public let baseColorFactor: SIMD4<Float>
    public let baseColorTextureIndex: Int?
    public let metallicFactor: Float
    public let roughnessFactor: Float
    public let emissiveFactor: SIMD3<Float>
    public let alphaMode: GLTFAlphaMode
    public let alphaCutoff: Float
    public let doubleSided: Bool

    // Texture coordinate transform (ScaleX, ScaleY, OffsetX, OffsetY)
    // Default: Scale(1,1), Offset(0,0)
    // ★ var に変更: ランタイムでUVオフセットを変更可能（目の視線制御用）
    public var textureTransform: SIMD4<Float>

    // MToon specific properties
    public let isMToon: Bool
    public let shadeColorFactor: SIMD4<Float>
    public let shadeMultiplyTextureIndex: Int?
    public let shadingShiftFactor: Float
    public let shadingToonyFactor: Float
    public let rimColorFactor: SIMD4<Float>
    public let rimFresnelPowerFactor: Float
    public let rimLiftFactor: Float
    public let rimLightingMixFactor: Float
    public let matcapTextureIndex: Int?
    public let matcapFactor: SIMD4<Float>
    public let outlineWidthMode: Int  // 0=none, 1=worldCoordinates, 2=screenCoordinates
    public let outlineWidthFactor: Float
    public let outlineColorFactor: SIMD4<Float>
    public let outlineLightingMixFactor: Float

    init(gltfMaterial: GLTFMaterial, vrm0MaterialProps: [String: Any]? = nil) {
        self.name = gltfMaterial.name

        let pbr = gltfMaterial.pbrMetallicRoughness
        let hasTexture = pbr?.baseColorTexture?.index != nil
        self.baseColorTextureIndex = pbr?.baseColorTexture?.index

        // Handle base color factor
        if let bcf = pbr?.baseColorFactor {
            self.baseColorFactor = SIMD4<Float>(bcf[0], bcf[1], bcf[2], bcf[3])
        } else if !hasTexture {
            // No texture and no color specified - use a neutral skin-tone for better appearance
            // This handles VRM files with missing material data
            let materialName = gltfMaterial.name?.lowercased() ?? ""
            if materialName.contains("face") || materialName.contains("skin") ||
               materialName.contains("eye") || materialName.contains("eyebase") {
                // Skin-tone color for face/skin related materials
                self.baseColorFactor = SIMD4<Float>(1.0, 0.9, 0.85, 1.0)
            } else {
                self.baseColorFactor = SIMD4<Float>(1, 1, 1, 1)
            }
        } else {
            self.baseColorFactor = SIMD4<Float>(1, 1, 1, 1)
        }

        // VRM character models are typically non-metallic (skin, cloth, hair)
        // If material has no texture and metallicFactor is 1.0 (glTF default),
        // force it to 0.0 to avoid metallic look on untextured surfaces
        let rawMetallic = pbr?.metallicFactor ?? 0.0
        if !hasTexture && rawMetallic == 1.0 {
            self.metallicFactor = 0.0  // Override metallic for untextured materials
        } else {
            self.metallicFactor = rawMetallic
        }
        self.roughnessFactor = pbr?.roughnessFactor ?? 0.5

        let ef = gltfMaterial.emissiveFactor ?? [0, 0, 0]
        self.emissiveFactor = SIMD3<Float>(ef[0], ef[1], ef[2])

        self.alphaMode = gltfMaterial.alphaModeEnum
        self.alphaCutoff = gltfMaterial.alphaCutoff ?? 0.5
        self.doubleSided = gltfMaterial.doubleSided ?? false

        // Parse texture transform (KHR_texture_transform for VRM 1.0, _MainTex_ST for VRM 0.x)
        var scale = SIMD2<Float>(1, 1)
        var offset = SIMD2<Float>(0, 0)

        // 1. VRM 1.0 (glTF KHR_texture_transform)
        if let pbr = gltfMaterial.pbrMetallicRoughness,
           let texInfo = pbr.baseColorTexture,
           let extensions = texInfo.extensions,
           let transform = extensions["KHR_texture_transform"]?.dictionary {

            if let s = transform["scale"] as? [Double], s.count >= 2 {
                scale = SIMD2<Float>(Float(s[0]), Float(s[1]))
            } else if let s = transform["scale"] as? [Any], s.count >= 2 {
                // Try to convert from Any
                if let s0 = (s[0] as? Double) ?? (s[0] as? NSNumber)?.doubleValue,
                   let s1 = (s[1] as? Double) ?? (s[1] as? NSNumber)?.doubleValue {
                    scale = SIMD2<Float>(Float(s0), Float(s1))
                }
            }
            if let o = transform["offset"] as? [Double], o.count >= 2 {
                offset = SIMD2<Float>(Float(o[0]), Float(o[1]))
            } else if let o = transform["offset"] as? [Any], o.count >= 2 {
                // Try to convert from Any
                if let o0 = (o[0] as? Double) ?? (o[0] as? NSNumber)?.doubleValue,
                   let o1 = (o[1] as? Double) ?? (o[1] as? NSNumber)?.doubleValue {
                    offset = SIMD2<Float>(Float(o0), Float(o1))
                }
            }
        }
        // 2. VRM 0.x (_MainTex_ST)
        else if let vrm0Props = vrm0MaterialProps,
                let vectorProps = vrm0Props["vectorProperties"] as? [String: [Double]],
                let mainTexSt = vectorProps["_MainTex_ST"],
                mainTexSt.count >= 4 {
            // Unity's _MainTex_ST is [Scale X, Scale Y, Offset X, Offset Y]
            scale = SIMD2<Float>(Float(mainTexSt[0]), Float(mainTexSt[1]))

            // Unity (bottom-left origin) -> Metal (top-left origin) conversion
            // Metal Offset Y = 1.0 - Scale Y - Unity Offset Y
            let unityOffsetY = Float(mainTexSt[3])
            let metalOffsetY = 1.0 - scale.y - unityOffsetY

            offset = SIMD2<Float>(Float(mainTexSt[2]), metalOffsetY)
        }

        self.textureTransform = SIMD4<Float>(scale.x, scale.y, offset.x, offset.y)

        // Try VRM 1.0 MToon first (VRMC_materials_mtoon)
        if let extensions = gltfMaterial.extensions,
           let mtoonExt = extensions["VRMC_materials_mtoon"]?.dictionary {
            self.isMToon = true

            // Shade color - try multiple types since JSON decoder may vary
            let shadeColorValue = mtoonExt["shadeColorFactor"]

            // Try multiple ways to extract the array (JSON decoder may produce different types)
            var shadeColorArray: [Float]? = nil
            if let arr = shadeColorValue as? [Double] {
                shadeColorArray = arr.map { Float($0) }
            } else if let arr = shadeColorValue as? [Float] {
                shadeColorArray = arr
            } else if let arr = shadeColorValue as? [NSNumber] {
                shadeColorArray = arr.map { $0.floatValue }
            } else if let arr = shadeColorValue as? [Any] {
                // Try to convert each element individually
                shadeColorArray = arr.compactMap { elem -> Float? in
                    if let d = elem as? Double { return Float(d) }
                    if let f = elem as? Float { return f }
                    if let n = elem as? NSNumber { return n.floatValue }
                    if let i = elem as? Int { return Float(i) }
                    return nil
                }
                if shadeColorArray?.count != arr.count {
                    shadeColorArray = nil // Conversion failed for some elements
                }
            }

            if let shadeColorFactor = shadeColorArray, shadeColorFactor.count >= 3 {
                self.shadeColorFactor = SIMD4<Float>(
                    shadeColorFactor[0],
                    shadeColorFactor[1],
                    shadeColorFactor[2],
                    shadeColorFactor.count > 3 ? shadeColorFactor[3] : 1.0
                )
            } else {
                // Use baseColorFactor as fallback for shade color
                self.shadeColorFactor = SIMD4<Float>(
                    self.baseColorFactor.x * 0.7,
                    self.baseColorFactor.y * 0.7,
                    self.baseColorFactor.z * 0.7,
                    1.0
                )
            }

            if let shadeMultiplyTex = mtoonExt["shadeMultiplyTexture"] as? [String: Any],
               let index = shadeMultiplyTex["index"] as? Int {
                self.shadeMultiplyTextureIndex = index
            } else {
                self.shadeMultiplyTextureIndex = nil
            }

            self.shadingShiftFactor = Float(mtoonExt["shadingShiftFactor"] as? Double ?? 0.0)
            self.shadingToonyFactor = Float(mtoonExt["shadingToonyFactor"] as? Double ?? 0.9)

            if let rimColorFactor = mtoonExt["parametricRimColorFactor"] as? [Double] {
                self.rimColorFactor = SIMD4<Float>(Float(rimColorFactor[0]), Float(rimColorFactor[1]), Float(rimColorFactor[2]), 1.0)
            } else {
                self.rimColorFactor = SIMD4<Float>(0, 0, 0, 1)
            }
            self.rimFresnelPowerFactor = Float(mtoonExt["parametricRimFresnelPowerFactor"] as? Double ?? 5.0)
            self.rimLiftFactor = Float(mtoonExt["parametricRimLiftFactor"] as? Double ?? 0.0)
            self.rimLightingMixFactor = Float(mtoonExt["rimLightingMixFactor"] as? Double ?? 1.0)

            if let matcapTex = mtoonExt["matcapTexture"] as? [String: Any],
               let index = matcapTex["index"] as? Int {
                self.matcapTextureIndex = index
            } else {
                self.matcapTextureIndex = nil
            }
            if let matcapFactor = mtoonExt["matcapFactor"] as? [Double] {
                self.matcapFactor = SIMD4<Float>(Float(matcapFactor[0]), Float(matcapFactor[1]), Float(matcapFactor[2]), 1.0)
            } else {
                self.matcapFactor = SIMD4<Float>(1, 1, 1, 1)
            }

            let outlineModeStr = mtoonExt["outlineWidthMode"] as? String ?? "none"
            switch outlineModeStr {
            case "worldCoordinates": self.outlineWidthMode = 1
            case "screenCoordinates": self.outlineWidthMode = 2
            default: self.outlineWidthMode = 0
            }
            self.outlineWidthFactor = Float(mtoonExt["outlineWidthFactor"] as? Double ?? 0.0)
            if let outlineColorFactor = mtoonExt["outlineColorFactor"] as? [Double] {
                self.outlineColorFactor = SIMD4<Float>(Float(outlineColorFactor[0]), Float(outlineColorFactor[1]), Float(outlineColorFactor[2]), 1.0)
            } else {
                self.outlineColorFactor = SIMD4<Float>(0, 0, 0, 1)
            }
            self.outlineLightingMixFactor = Float(mtoonExt["outlineLightingMixFactor"] as? Double ?? 1.0)

        // Try VRM 0.x MToon (check materialProperties from VRM extension)
        } else if let vrm0Props = vrm0MaterialProps,
                  let shader = vrm0Props["shader"] as? String,
                  shader.contains("MToon") {
            self.isMToon = true

            // VRM 0.x stores properties in floatProperties, vectorProperties, textureProperties
            let floatProps = vrm0Props["floatProperties"] as? [String: Double] ?? [:]
            let vectorProps = vrm0Props["vectorProperties"] as? [String: [Double]] ?? [:]
            let textureProps = vrm0Props["textureProperties"] as? [String: Int] ?? [:]

            // Shade color (_ShadeColor in VRM 0.x)
            if let shadeColor = vectorProps["_ShadeColor"] {
                self.shadeColorFactor = SIMD4<Float>(
                    Float(shadeColor[0]),
                    Float(shadeColor[1]),
                    Float(shadeColor[2]),
                    shadeColor.count > 3 ? Float(shadeColor[3]) : 1.0
                )
            } else {
                self.shadeColorFactor = SIMD4<Float>(self.baseColorFactor.x * 0.7, self.baseColorFactor.y * 0.7, self.baseColorFactor.z * 0.7, 1.0)
            }

            // Shade texture
            self.shadeMultiplyTextureIndex = textureProps["_ShadeTexture"]

            // Shading parameters
            // VRM 0.x: _ShadeShift (-1 to 1), _ShadeToony (0 to 1)
            self.shadingShiftFactor = Float(floatProps["_ShadeShift"] ?? 0.0)
            self.shadingToonyFactor = Float(floatProps["_ShadeToony"] ?? 0.9)

            // Rim lighting (_RimColor, _RimFresnelPower, _RimLift, _RimLightingMix)
            if let rimColor = vectorProps["_RimColor"] {
                self.rimColorFactor = SIMD4<Float>(Float(rimColor[0]), Float(rimColor[1]), Float(rimColor[2]), 1.0)
            } else {
                self.rimColorFactor = SIMD4<Float>(0, 0, 0, 1)
            }
            self.rimFresnelPowerFactor = Float(floatProps["_RimFresnelPower"] ?? 5.0)
            self.rimLiftFactor = Float(floatProps["_RimLift"] ?? 0.0)
            self.rimLightingMixFactor = Float(floatProps["_RimLightingMix"] ?? 1.0)

            // Matcap
            self.matcapTextureIndex = textureProps["_SphereAdd"]
            if let matcapColor = vectorProps["_SphereAddColor"] {
                self.matcapFactor = SIMD4<Float>(Float(matcapColor[0]), Float(matcapColor[1]), Float(matcapColor[2]), 1.0)
            } else {
                self.matcapFactor = SIMD4<Float>(1, 1, 1, 1)
            }

            // Outline (_OutlineWidthMode, _OutlineWidth, _OutlineColor, _OutlineLightingMix)
            let outlineMode = Int(floatProps["_OutlineWidthMode"] ?? 0)
            self.outlineWidthMode = outlineMode
            self.outlineWidthFactor = Float(floatProps["_OutlineWidth"] ?? 0.0)
            if let outlineColor = vectorProps["_OutlineColor"] {
                self.outlineColorFactor = SIMD4<Float>(Float(outlineColor[0]), Float(outlineColor[1]), Float(outlineColor[2]), 1.0)
            } else {
                self.outlineColorFactor = SIMD4<Float>(0, 0, 0, 1)
            }
            self.outlineLightingMixFactor = Float(floatProps["_OutlineLightingMix"] ?? 1.0)

        } else {
            // Not MToon - use defaults
            self.isMToon = false
            self.shadeColorFactor = SIMD4<Float>(0.5, 0.5, 0.5, 1.0)
            self.shadeMultiplyTextureIndex = nil
            self.shadingShiftFactor = 0.0
            self.shadingToonyFactor = 0.9
            self.rimColorFactor = SIMD4<Float>(0, 0, 0, 1)
            self.rimFresnelPowerFactor = 5.0
            self.rimLiftFactor = 0.0
            self.rimLightingMixFactor = 1.0
            self.matcapTextureIndex = nil
            self.matcapFactor = SIMD4<Float>(1, 1, 1, 1)
            self.outlineWidthMode = 0
            self.outlineWidthFactor = 0.0
            self.outlineColorFactor = SIMD4<Float>(0, 0, 0, 1)
            self.outlineLightingMixFactor = 1.0
        }
    }
}

// MARK: - VRM1Skin

public struct VRM1Skin {
    public let name: String?
    public let joints: [VRM1Node]
    public let inverseBindMatrices: [simd_float4x4]

    /// Compute joint matrices for GPU skinning
    public func computeJointMatrices() -> [simd_float4x4] {
        var matrices: [simd_float4x4] = []
        matrices.reserveCapacity(joints.count)

        for (index, joint) in joints.enumerated() {
            let ibm = index < inverseBindMatrices.count ?
                inverseBindMatrices[index] : matrix_identity_float4x4
            matrices.append(joint.worldTransform * ibm)
        }

        return matrices
    }
}
