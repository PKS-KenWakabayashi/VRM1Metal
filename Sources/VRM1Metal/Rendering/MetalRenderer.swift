import Foundation
import Metal
import MetalKit
import simd

// MetalのVertex構造体(ShaderTypes.h)と完全に一致させる定義
// Total: 96 bytes (16 + 16 + 8 + 8 + 16 + 16 + 16)
// ★注意: SIMD3<Float>は内部で16バイト（12データ+4パディング）のサイズを持つ
struct VertexInput {
    // Position (16 bytes): SIMD3は内部で16バイト
    var position: SIMD3<Float>

    // Normal (16 bytes): SIMD3は内部で16バイト
    var normal: SIMD3<Float>

    // TexCoord (8 bytes)
    var texCoord: SIMD2<Float>

    // TexCoord Padding (8 bytes) - 次のTangent(16byte)のアライメントを揃えるために必須
    var _texCoordPad: SIMD2<Float>

    // Tangent (16 bytes)
    var tangent: SIMD4<Float>

    // Joints (16 bytes) - Floatとして渡し、Shaderでintにキャスト
    var joints: SIMD4<Float>

    // Weights (16 bytes)
    var weights: SIMD4<Float>
    // Total: 96 bytes
}

// MARK: - Frustum Culling Structures

/// 境界ボックス（Axis-Aligned Bounding Box）
struct AABB {
    var min: SIMD3<Float>
    var max: SIMD3<Float>

    /// 中心点
    var center: SIMD3<Float> { (min + max) * 0.5 }
    /// サイズ（各軸の長さ）
    var size: SIMD3<Float> { max - min }

    /// 8つの頂点を取得
    func getCorners() -> [SIMD3<Float>] {
        return [
            SIMD3<Float>(min.x, min.y, min.z),
            SIMD3<Float>(max.x, min.y, min.z),
            SIMD3<Float>(min.x, max.y, min.z),
            SIMD3<Float>(max.x, max.y, min.z),
            SIMD3<Float>(min.x, min.y, max.z),
            SIMD3<Float>(max.x, min.y, max.z),
            SIMD3<Float>(min.x, max.y, max.z),
            SIMD3<Float>(max.x, max.y, max.z)
        ]
    }
}

/// 視錐台（カメラの見える範囲）
struct Frustum {
    /// 6つの平面 (Left, Right, Bottom, Top, Near, Far)
    /// xyz = 法線, w = 距離
    var planes: [SIMD4<Float>] = []

    init(viewProjection: simd_float4x4) {
        // 【修正】simd行列はColumn-Majorなので、平面抽出のために転置(transpose)してRowにアクセス
        let m = viewProjection.transpose  // Row-Major風に扱えるようになる

        // m.columns[0] が Row0 に相当するようになる
        let row0 = m.columns.0
        let row1 = m.columns.1
        let row2 = m.columns.2
        let row3 = m.columns.3

        planes = [
            row3 + row0, // Left:   w + x > 0
            row3 - row0, // Right:  w - x > 0
            row3 + row1, // Bottom: w + y > 0
            row3 - row1, // Top:    w - y > 0
            row2,        // Near:   z > 0     (Metal標準は 0 <= z <= w)
            row3 - row2  // Far:    w - z > 0 (z <= w)
        ]

        // 法線を正規化
        for i in 0..<planes.count {
            let length = simd_length(SIMD3<Float>(planes[i].x, planes[i].y, planes[i].z))
            if length > 0 {
                planes[i] /= length
            }
        }
    }

    /// AABBが視錐台内（または交差）にあるか判定
    func intersects(aabb: AABB) -> Bool {
        for plane in planes {
            let normal = SIMD3<Float>(plane.x, plane.y, plane.z)

            // "Positive Vertex" (法線方向にあるAABBの角) を見つける
            // この点が平面の「外側(裏側)」にあれば、箱全体が外側にあることになる
            let pVertex = SIMD3<Float>(
                normal.x >= 0 ? aabb.max.x : aabb.min.x,
                normal.y >= 0 ? aabb.max.y : aabb.min.y,
                normal.z >= 0 ? aabb.max.z : aabb.min.z
            )

            // 平面の方程式: dot(n, p) + d = 0
            // dot(n, p) + d < 0 なら外側
            if simd_dot(normal, pVertex) + plane.w < 0 {
                return false
            }
        }
        return true
    }
}

/// Main Metal renderer for VRM models
public final class MetalRenderer {

    // MARK: - Properties

    public let device: MTLDevice
    public let commandQueue: MTLCommandQueue

    private var pipelineState: MTLRenderPipelineState?
    private var skinnedPipelineState: MTLRenderPipelineState?
    private var mtoonPipelineState: MTLRenderPipelineState?
    private var outlinePipelineState: MTLRenderPipelineState?
    private var depthStencilState: MTLDepthStencilState?

    private var defaultSampler: MTLSamplerState?
    private var whiteTexture: MTLTexture?

    private var uniformsBuffer: MTLBuffer?
    private var materialBuffer: MTLBuffer?
    private var lightBuffer: MTLBuffer?
    private var boneMatricesBuffer: MTLBuffer?
    private var morphWeightsBuffer: MTLBuffer?
    private var morphDeltasBuffer: MTLBuffer?

    private var model: VRM1Model?
    private var meshBuffers: [Int: MeshGPUData] = [:]
    private var textures: [MTLTexture?] = []

    // 【追加】視錐台カリング用プロパティ
    /// Hips（腰）ノード - アニメーションで移動するキャラクターの基準点
    private var hipsNode: VRM1Node?
    /// フォールバック用ルートノード
    private var rootNode: VRM1Node?
    /// 判定結果のキャッシュ（2回計算防止用）
    public private(set) var isVisible: Bool = true

    // Camera
    public var cameraPosition: SIMD3<Float> = SIMD3<Float>(0, 1, 1)
    public var cameraTarget: SIMD3<Float> = SIMD3<Float>(0, 1, 0)
    public var cameraUp: SIMD3<Float> = SIMD3<Float>(0, 1, 0)
    public var fieldOfView: Float = 45.0
    public var nearPlane: Float = 0.01
    public var farPlane: Float = 100.0

    // Lighting (reduced for more natural VRM appearance)
    public var ambientColor: SIMD3<Float> = SIMD3<Float>(0.15, 0.15, 0.15)
    public var lightDirection: SIMD3<Float> = normalize(SIMD3<Float>(-1.0, -1.0, -0.5))  // Light from left-top
    public var lightColor: SIMD3<Float> = SIMD3<Float>(1.0, 1.0, 1.0)
    public var lightIntensity: Float = 0.7

    private var viewportSize: CGSize = CGSize(width: 1, height: 1)

    // MSAA
    private var sampleCount: Int = 1

    // Skinning
    private var hasSkinning: Bool = false

    /// Debug mode: 0=normal PBR, 1=show UV, 2=unlit texture, 3=show normals
    public var debugMode: Int32 = 0

    // MARK: - GPU Data Structures

    private struct MeshGPUData {
        let vertexBuffer: MTLBuffer
        let indexBuffer: MTLBuffer?
        let indexCount: Int
        let vertexCount: Int
        let materialIndex: Int?
        let skinIndex: Int?  // Which skin this mesh uses (for per-mesh skinning)
    }

    /// Morph target data for GPU-based morphing
    private struct MeshMorphData {
        let morphDeltasBuffer: MTLBuffer
        let morphTargetCount: Int
        let vertexCount: Int
    }

    /// Per-mesh morph target buffers (key: meshIndex * 1000 + primitiveIndex)
    private var meshMorphData: [Int: MeshMorphData] = [:]

    /// 【最適化】描画コマンド構造体（メソッド外に定義してクラスプロパティで再利用）
    private struct DrawCommand {
        let gpuData: MeshGPUData
        let material: VRM1Material?
        let useMToon: Bool
        let skinIndex: Int?
        let worldTransform: simd_float4x4  // ノードごとのワールド行列
        let key: Int                        // meshIndex * 1000 + primitiveIndex (for morph lookup)
        let morphWeights: [Float]           // Current morph weights for this mesh
    }

    /// 【最適化】描画コマンド配列を再利用（毎フレームのメモリ確保を回避）
    private var opaqueCommands: [DrawCommand] = []
    private var transparentCommands: [DrawCommand] = []

    // MARK: - Initialization

    public init(device: MTLDevice, sampleCount: Int = 1) throws {
        self.device = device
        self.sampleCount = sampleCount

        guard let commandQueue = device.makeCommandQueue() else {
            throw VRM1Error.metalDeviceNotAvailable
        }
        self.commandQueue = commandQueue

        try setupPipelines()
        setupDefaultResources()
    }

    private func setupPipelines() throws {
        // Load shader library
        guard let library = try? device.makeDefaultLibrary(bundle: Bundle.module) else {
            // Fallback: try to compile shaders at runtime
            throw VRM1Error.shaderCompilationFailed("Could not load shader library")
        }

        // Vertex descriptors
        let vertexDescriptor = MTLVertexDescriptor()

        // Position
        vertexDescriptor.attributes[0].format = .float3
        vertexDescriptor.attributes[0].offset = 0
        vertexDescriptor.attributes[0].bufferIndex = 0

        // Normal
        vertexDescriptor.attributes[1].format = .float3
        vertexDescriptor.attributes[1].offset = MemoryLayout<SIMD3<Float>>.stride
        vertexDescriptor.attributes[1].bufferIndex = 0

        // TexCoord
        vertexDescriptor.attributes[2].format = .float2
        vertexDescriptor.attributes[2].offset = MemoryLayout<SIMD3<Float>>.stride * 2
        vertexDescriptor.attributes[2].bufferIndex = 0

        // Tangent - at offset 48 (32 + 8 UV + 8 padding for 16-byte alignment)
        vertexDescriptor.attributes[3].format = .float4
        vertexDescriptor.attributes[3].offset = 48
        vertexDescriptor.attributes[3].bufferIndex = 0

        // Joints - at offset 64 (stored as float, cast to int in shader)
        vertexDescriptor.attributes[4].format = .float4
        vertexDescriptor.attributes[4].offset = 64
        vertexDescriptor.attributes[4].bufferIndex = 0

        // Weights - at offset 80
        vertexDescriptor.attributes[5].format = .float4
        vertexDescriptor.attributes[5].offset = 80
        vertexDescriptor.attributes[5].bufferIndex = 0

        // Layout - 96 bytes total (24 floats * 4 bytes)
        // Position(16) + Normal(16) + TexCoord(8) + Padding(8) + Tangent(16) + Joints(16) + Weights(16) = 96
        vertexDescriptor.layouts[0].stride = 96
        vertexDescriptor.layouts[0].stepFunction = .perVertex

        // Basic pipeline with skinning - using unlit for anime-style VRM
        let basicDescriptor = MTLRenderPipelineDescriptor()
        basicDescriptor.rasterSampleCount = sampleCount  // MSAA support
        basicDescriptor.vertexFunction = library.makeFunction(name: "skinned_vertex")
        basicDescriptor.fragmentFunction = library.makeFunction(name: "unlit_fragment")
        basicDescriptor.vertexDescriptor = vertexDescriptor
        basicDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        basicDescriptor.depthAttachmentPixelFormat = .depth32Float

        // Alpha blending
        basicDescriptor.colorAttachments[0].isBlendingEnabled = true
        basicDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        basicDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        basicDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        basicDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        pipelineState = try device.makeRenderPipelineState(descriptor: basicDescriptor)

        // Skinned pipeline - using unlit for anime-style VRM
        let skinnedDescriptor = MTLRenderPipelineDescriptor()
        skinnedDescriptor.rasterSampleCount = sampleCount  // MSAA support
        skinnedDescriptor.vertexFunction = library.makeFunction(name: "skinned_vertex")
        skinnedDescriptor.fragmentFunction = library.makeFunction(name: "unlit_fragment")
        skinnedDescriptor.vertexDescriptor = vertexDescriptor
        skinnedDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        skinnedDescriptor.depthAttachmentPixelFormat = .depth32Float
        skinnedDescriptor.colorAttachments[0].isBlendingEnabled = true
        skinnedDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        skinnedDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha

        skinnedPipelineState = try device.makeRenderPipelineState(descriptor: skinnedDescriptor)

        // MToon pipeline with skinning support
        let mtoonDescriptor = MTLRenderPipelineDescriptor()
        mtoonDescriptor.rasterSampleCount = sampleCount  // MSAA support
        mtoonDescriptor.vertexFunction = library.makeFunction(name: "skinned_vertex")
        mtoonDescriptor.fragmentFunction = library.makeFunction(name: "mtoon_fragment")
        mtoonDescriptor.vertexDescriptor = vertexDescriptor
        mtoonDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        mtoonDescriptor.depthAttachmentPixelFormat = .depth32Float
        mtoonDescriptor.colorAttachments[0].isBlendingEnabled = true
        mtoonDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        mtoonDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha

        mtoonPipelineState = try device.makeRenderPipelineState(descriptor: mtoonDescriptor)

        // Outline pipeline (cull front faces)
        let outlineDescriptor = MTLRenderPipelineDescriptor()
        outlineDescriptor.rasterSampleCount = sampleCount  // MSAA support
        outlineDescriptor.vertexFunction = library.makeFunction(name: "mtoon_outline_vertex")
        outlineDescriptor.fragmentFunction = library.makeFunction(name: "mtoon_outline_fragment")
        outlineDescriptor.vertexDescriptor = vertexDescriptor
        outlineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        outlineDescriptor.depthAttachmentPixelFormat = .depth32Float

        outlinePipelineState = try device.makeRenderPipelineState(descriptor: outlineDescriptor)

        // Depth stencil state
        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.depthCompareFunction = .less
        depthDescriptor.isDepthWriteEnabled = true
        depthStencilState = device.makeDepthStencilState(descriptor: depthDescriptor)
    }

    private func setupDefaultResources() {
        // Default sampler
        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.mipFilter = .linear
        samplerDescriptor.sAddressMode = .repeat
        samplerDescriptor.tAddressMode = .repeat
        defaultSampler = device.makeSamplerState(descriptor: samplerDescriptor)

        // White texture (1x1)
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: 1,
            height: 1,
            mipmapped: false
        )
        textureDescriptor.usage = .shaderRead
        whiteTexture = device.makeTexture(descriptor: textureDescriptor)
        let white: [UInt8] = [255, 255, 255, 255]
        whiteTexture?.replace(
            region: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0),
                             size: MTLSize(width: 1, height: 1, depth: 1)),
            mipmapLevel: 0,
            withBytes: white,
            bytesPerRow: 4
        )

        // Buffers
        uniformsBuffer = device.makeBuffer(length: MemoryLayout<Uniforms>.stride, options: .storageModeShared)
        materialBuffer = device.makeBuffer(length: MemoryLayout<MaterialUniforms>.stride, options: .storageModeShared)
        lightBuffer = device.makeBuffer(length: MemoryLayout<LightUniforms>.stride, options: .storageModeShared)
        // Bone matrices buffer - 256 bones max * 64 bytes per matrix
        boneMatricesBuffer = device.makeBuffer(length: 256 * MemoryLayout<simd_float4x4>.stride, options: .storageModeShared)
        // Morph target buffers (dummy for now - 64 weights, minimal deltas)
        morphWeightsBuffer = device.makeBuffer(length: 64 * MemoryLayout<Float>.stride, options: .storageModeShared)
        morphDeltasBuffer = device.makeBuffer(length: 64 * MemoryLayout<SIMD3<Float>>.stride, options: .storageModeShared)
    }

    // MARK: - Model Loading

    public func setModel(_ model: VRM1Model) {
        self.model = model
        meshBuffers.removeAll()
        meshMorphData.removeAll()

        // 【追加】ルートノードの取得（視錐台カリング用フォールバック）
        self.rootNode = model.rootNodes.first

        // 【追加】Hips（腰）ノードの取得（視錐台カリング用 - キャラクター移動に追従）
        // VRMではHumanoidボーンとして "hips" が定義されている
        self.hipsNode = model.humanoid?.getBone(named: "hips")

        // Humanoidから取れない場合は名前で検索
        if self.hipsNode == nil {
            for node in model.allNodes {
                if let name = node.name?.lowercased(), name.contains("hips") {
                    self.hipsNode = node
                    break
                }
            }
        }

        // Load textures from model
        loadTextures(from: model)

        // 1. メインスキンの検出（最も多くのボーンを持つスキンを探す）
        let mainSkinIndex = model.skins.enumerated().max(by: { $0.element.joints.count < $1.element.joints.count })?.offset

        // メインスキンのジョイント一覧（ノードIndex -> スキン内JointIndex のマップ）を作成
        var nodeIndexToJointIndex: [Int: Int] = [:]
        var headJointIndex: Int? = nil  // Headボーンのジョイントインデックス

        if let mainIdx = mainSkinIndex {
            for (jointIdx, node) in model.skins[mainIdx].joints.enumerated() {
                nodeIndexToJointIndex[node.index] = jointIdx

                // Headボーンを名前で検出（VRM標準では "Head" または "head"）
                if let name = node.name?.lowercased(), name.contains("head") && !name.contains("headtop") {
                    headJointIndex = jointIdx
                }
            }
        }

        // ボーン行列バッファの再確保（すべてのスキン分）
        let skinCount = max(model.skins.count, 1)
        let matrixSize = MemoryLayout<simd_float4x4>.stride
        let bufferSize = skinCount * 256 * matrixSize  // 256 = MAX_BONES per skin
        boneMatricesBuffer = device.makeBuffer(length: bufferSize, options: .storageModeShared)

        // Build mesh-to-skin mapping by finding which node owns each mesh
        var meshToSkinIndex: [Int: Int] = [:]
        var meshToNodeIndex: [Int: VRM1Node] = [:]  // Mesh -> Node の逆引き（ノード参照を保持）
        for node in model.allNodes {
            if let meshIndex = node.gltfNode.mesh {
                meshToNodeIndex[meshIndex] = node
                if let skinIndex = node.gltfNode.skin {
                    meshToSkinIndex[meshIndex] = skinIndex
                }
            }
        }

        // Create GPU buffers for each mesh primitive
        for mesh in model.meshes {
            var skinIndex = meshToSkinIndex[mesh.index]
            var forcedJointIndex: Int? = nil

            // ★修正: Parent Walk（スキンなしメッシュに無理やりボーンを割り当てる処理）を無効化
            // アクセサリ等は親ノードのworldTransformに従うだけで十分であり、
            // 強制スキニングとpreTransformの併用は座標変換の重複を引き起こしポリゴン爆発の原因となる
            var preTransform: simd_float4x4? = nil  // 事前変換行列（使用しない）

            // 【決定的な修正】スキンがなく、かつモーフターゲットを持つメッシュ（顔パーツ）は、
            // 強制的にHeadボーンに追従させる
            // これにより、EL_DEF（まぶた）やMTH_DEF（口）などの顔メッシュが
            // ボディと一緒に動くようになる
            if skinIndex == nil {
                // Check if any primitive has morph targets
                let hasMorphTargets = mesh.primitives.contains { !$0.morphTargets.isEmpty }
                let hasMorphWeights = !mesh.morphWeights.isEmpty

                if hasMorphTargets || hasMorphWeights {
                    if let mainIdx = mainSkinIndex, let headIdx = headJointIndex {
                        skinIndex = mainIdx
                        forcedJointIndex = headIdx
                    }
                }
            }

            /*
            // ★旧ロジック（無効化）: スキンがない場合、親階層を遡ってボーンを探す (Parent Walk)
            if skinIndex == nil, let mainIdx = mainSkinIndex, let startNode = meshToNodeIndex[mesh.index] {
                var currentNode: VRM1Node? = startNode

                // 親を辿って、メインスキンに含まれるボーンを探す
                while let node = currentNode {
                    if let jointIdx = nodeIndexToJointIndex[node.index] {
                        skinIndex = mainIdx
                        forcedJointIndex = jointIdx

                        // ★決定版修正: ノードの現在位置ではなく、「ボーンのBindPose（本来あるべき位置）」を使用する
                        // InverseBindMatrix (World->BoneLocal) の逆行列 (BoneLocal->World) を計算することで
                        // 頂点を強制的に「ボーンの基準位置」へ移動させる
                        if let skin = model.skins[safe: mainIdx],
                           jointIdx < skin.inverseBindMatrices.count {

                            let ibm = skin.inverseBindMatrices[jointIdx]
                            // IBMが単位行列（未定義）の場合は、ノード位置をフォールバックとして使う
                            if isIdentityMatrix(ibm) {
                                preTransform = startNode.worldTransform
                            } else {
                                preTransform = ibm.inverse  // ★ここが重要: IBMの逆行列を使用
                            }
                        } else {
                            preTransform = startNode.worldTransform
                        }
                        break
                    }
                    currentNode = node.parent
                }
            }
            */

            // さらにフォールバック: Joint情報を持っているがスキンがない場合
            for (primitiveIndex, primitive) in mesh.primitives.enumerated() {
                var effectiveSkinIndex = skinIndex
                var effectiveForcedJoint = forcedJointIndex
                var effectivePreTransform = preTransform

                if effectiveSkinIndex == nil, let joints = primitive.joints, !joints.isEmpty, let fallback = mainSkinIndex {
                    effectiveSkinIndex = fallback
                }

                let key = mesh.index * 1000 + primitiveIndex
                if let gpuData = createMeshGPUData(primitive, skinIndex: effectiveSkinIndex, forcedJointIndex: effectiveForcedJoint, preTransform: effectivePreTransform) {
                    meshBuffers[key] = gpuData

                    // Create morph target buffer if this primitive has morph targets
                    if !primitive.morphTargets.isEmpty {
                        if let morphData = createMorphDeltasBuffer(primitive) {
                            meshMorphData[key] = morphData
                        }
                    }
                }
            }
        }

    }

    private func loadTextures(from model: VRM1Model) {
        textures.removeAll()

        guard let gltfTextures = model.document.textures else {
            return
        }

        let loader = MTKTextureLoader(device: device)

        for (_, gltfTexture) in gltfTextures.enumerated() {
            var texture: MTLTexture? = nil

            if let sourceIndex = gltfTexture.source {
                do {
                    let imageData = try model.parseResult.getImageData(imageIndex: sourceIndex)

                    let options: [MTKTextureLoader.Option: Any] = [
                        .SRGB: true,
                        .generateMipmaps: true
                    ]

                    texture = try loader.newTexture(data: imageData, options: options)
                } catch {
                    // Texture loading failed
                }
            }

            textures.append(texture)
        }
    }

    private func createMeshGPUData(_ primitive: VRM1Primitive, skinIndex: Int?, forcedJointIndex: Int? = nil, preTransform: simd_float4x4? = nil) -> MeshGPUData? {
        let vertexCount = primitive.vertexCount
        guard vertexCount > 0 else { return nil }

        // スキニング情報の有効性チェック
        var finalSkinIndex = skinIndex
        let hasValidSkinData = (primitive.joints != nil && primitive.weights != nil &&
                                (primitive.joints!.count >= vertexCount * 4) &&
                                (primitive.weights!.count >= vertexCount * 4))

        if !hasValidSkinData && forcedJointIndex == nil {
            finalSkinIndex = nil
        }

        // 法線変換行列
        let normalTransform: simd_float3x3?
        if let transform = preTransform {
            let col0 = SIMD3<Float>(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z)
            let col1 = SIMD3<Float>(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z)
            let col2 = SIMD3<Float>(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)
            normalTransform = simd_float3x3(normalize(col0), normalize(col1), normalize(col2))
        } else {
            normalTransform = nil
        }

        // ★★★ 構造体ベースの頂点バッファ構築 ★★★
        var vertices = [VertexInput]()
        vertices.reserveCapacity(vertexCount)

        for i in 0..<vertexCount {
            // 初期化（SIMD3は内部で16バイトなのでパディング不要）
            var vertex = VertexInput(
                position: SIMD3<Float>(0, 0, 0),
                normal: SIMD3<Float>(0, 1, 0),
                texCoord: SIMD2<Float>(0, 0),
                _texCoordPad: SIMD2<Float>(0, 0),
                tangent: SIMD4<Float>(1, 0, 0, 1),
                joints: SIMD4<Float>(0, 0, 0, 0),
                weights: SIMD4<Float>(0, 0, 0, 0)
            )

            // 1. Position
            var vx = primitive.positions[i * 3]
            var vy = primitive.positions[i * 3 + 1]
            var vz = primitive.positions[i * 3 + 2]

            if let transform = preTransform {
                let v = transform * SIMD4<Float>(vx, vy, vz, 1.0)
                vx = v.x; vy = v.y; vz = v.z
            }
            vertex.position = SIMD3<Float>(vx, vy, vz)

            // 2. Normal
            if let normals = primitive.normals, i * 3 + 2 < normals.count {
                var nx = normals[i * 3]
                var ny = normals[i * 3 + 1]
                var nz = normals[i * 3 + 2]
                if let nTransform = normalTransform {
                    let n = nTransform * SIMD3<Float>(nx, ny, nz)
                    nx = n.x; ny = n.y; nz = n.z
                }
                vertex.normal = SIMD3<Float>(nx, ny, nz)
            }

            // 3. TexCoord
            if let texCoords = primitive.texCoords, i * 2 + 1 < texCoords.count {
                vertex.texCoord = SIMD2<Float>(texCoords[i * 2], texCoords[i * 2 + 1])
            }

            // 4. Tangent
            if let tangents = primitive.tangents, i * 4 + 3 < tangents.count {
                vertex.tangent = SIMD4<Float>(tangents[i * 4], tangents[i * 4 + 1], tangents[i * 4 + 2], tangents[i * 4 + 3])
            }

            // 5. Joints & Weights
            if let joints = primitive.joints, let weights = primitive.weights,
               i * 4 + 3 < joints.count, i * 4 + 3 < weights.count {
                // UInt32をFloatに変換（シェーダー側でint4にキャスト）
                vertex.joints = SIMD4<Float>(
                    Float(joints[i * 4]),
                    Float(joints[i * 4 + 1]),
                    Float(joints[i * 4 + 2]),
                    Float(joints[i * 4 + 3])
                )
                vertex.weights = SIMD4<Float>(
                    weights[i * 4],
                    weights[i * 4 + 1],
                    weights[i * 4 + 2],
                    weights[i * 4 + 3]
                )
            } else if let forcedJoint = forcedJointIndex {
                vertex.joints = SIMD4<Float>(Float(forcedJoint), 0, 0, 0)
                vertex.weights = SIMD4<Float>(1.0, 0, 0, 0)
            }

            vertices.append(vertex)
        }

        // ★★★ バッファ作成: withUnsafeBytesで確実にコピー ★★★
        let bufferSize = vertices.count * MemoryLayout<VertexInput>.stride
        guard let vertexBuffer = vertices.withUnsafeBytes({ ptr -> MTLBuffer? in
            return device.makeBuffer(bytes: ptr.baseAddress!, length: bufferSize, options: .storageModeShared)
        }) else { return nil }

        var indexBuffer: MTLBuffer?
        var indexCount = 0
        if let indices = primitive.indices, !indices.isEmpty {
            indexCount = indices.count
            indexBuffer = device.makeBuffer(bytes: indices, length: indices.count * MemoryLayout<UInt32>.stride, options: .storageModeShared)
        } else {
            indexCount = vertexCount
        }

        return MeshGPUData(
            vertexBuffer: vertexBuffer,
            indexBuffer: indexBuffer,
            indexCount: indexCount,
            vertexCount: vertexCount,
            materialIndex: primitive.materialIndex,
            skinIndex: finalSkinIndex
        )
    }

    /// Create morph target deltas buffer for GPU-based morphing
    /// Layout: For each vertex, store all morph target deltas consecutively
    /// [v0_morph0, v0_morph1, ..., v1_morph0, v1_morph1, ...]
    private func createMorphDeltasBuffer(_ primitive: VRM1Primitive) -> MeshMorphData? {
        let morphTargets = primitive.morphTargets
        guard !morphTargets.isEmpty else { return nil }

        let vertexCount = primitive.vertexCount
        let morphTargetCount = morphTargets.count

        // Limit to MAX_MORPH_TARGETS
        let effectiveMorphCount = min(morphTargetCount, 64)

        // Create delta array: vertexCount * morphTargetCount * 3 floats (packed_float3)
        let totalDeltas = vertexCount * effectiveMorphCount
        var deltas = [SIMD3<Float>](repeating: SIMD3<Float>(0, 0, 0), count: totalDeltas)

        // Fill in the deltas
        for morphIndex in 0..<effectiveMorphCount {
            let morphTarget = morphTargets[morphIndex]
            let positionDeltas = morphTarget.positionDeltas

            for vertexIndex in 0..<vertexCount {
                let bufferIndex = vertexIndex * effectiveMorphCount + morphIndex

                // Get position delta for this vertex
                if positionDeltas.count >= (vertexIndex + 1) * 3 {
                    let dx = positionDeltas[vertexIndex * 3]
                    let dy = positionDeltas[vertexIndex * 3 + 1]
                    let dz = positionDeltas[vertexIndex * 3 + 2]
                    deltas[bufferIndex] = SIMD3<Float>(dx, dy, dz)
                }
            }
        }

        // Create GPU buffer
        let bufferSize = totalDeltas * MemoryLayout<SIMD3<Float>>.stride
        guard let buffer = deltas.withUnsafeBytes({ ptr -> MTLBuffer? in
            return device.makeBuffer(bytes: ptr.baseAddress!, length: bufferSize, options: .storageModeShared)
        }) else { return nil }

        return MeshMorphData(
            morphDeltasBuffer: buffer,
            morphTargetCount: effectiveMorphCount,
            vertexCount: vertexCount
        )
    }

    // MARK: - Rendering

    public func resize(to size: CGSize) {
        viewportSize = size
    }

    /// 【最適化】localTransformチェーンを再帰的に辿ってワールド変換を計算
    /// 画面外でupdateWorldTransformsがスキップされても、Hipsの正確な位置を取得できる
    private func computeWorldTransform(for node: VRM1Node) -> simd_float4x4 {
        var current = node
        var matrix = current.localTransform

        while let parent = current.parent {
            matrix = parent.localTransform * matrix
            current = parent
        }

        return matrix
    }

    /// 【最適化】視錐台カリング判定を更新（Hips基準のAABBを使用）
    /// VRM1View側から毎フレーム呼び出し、結果はisVisibleプロパティにキャッシュ
    public func updateVisibility() {
        // View/Projection行列を計算
        let viewMatrix = lookAt(eye: cameraPosition, center: cameraTarget, up: cameraUp)
        let aspect = Float(viewportSize.width / viewportSize.height)
        let projectionMatrix = perspective(fovY: fieldOfView * .pi / 180.0, aspect: aspect, near: nearPlane, far: farPlane)
        let viewProjection = projectionMatrix * viewMatrix

        // 視錐台の作成
        let frustum = Frustum(viewProjection: viewProjection)

        // Hips（腰）の位置を取得（Hipsがなければルートノード）
        guard let baseNode = hipsNode ?? rootNode else {
            self.isVisible = true
            return
        }

        // 【修正】localTransformチェーンを再帰的に辿ってワールド変換を計算
        // アニメーション適用後(localTransform更新後)だが、updateWorldTransforms(全更新)は
        // スキップされるため、ここで局所的にルートから再計算する
        let currentWorldTransform = computeWorldTransform(for: baseNode)

        // 【修正】人型にフィットさせた境界ボックス（Bounding Box）
        // Hips（腰）を基準としたローカル座標
        // 幅(X): 左右30cmずつ (計60cm)
        // 高さ(Y): 下に1m(足元), 上に0.8m(頭頂部)
        // 奥行(Z): 前後20cmずつ (計40cm)
        // ※太すぎるボックスだとカリングが遅れるため、人体サイズに合わせて調整
        let localMin = SIMD3<Float>(-0.3, -1.0, -0.2)
        let localMax = SIMD3<Float>( 0.3,  0.8,  0.2)

        // AABBの8頂点を作成
        let corners = [
            SIMD3<Float>(localMin.x, localMin.y, localMin.z),
            SIMD3<Float>(localMax.x, localMin.y, localMin.z),
            SIMD3<Float>(localMin.x, localMax.y, localMin.z),
            SIMD3<Float>(localMax.x, localMax.y, localMin.z),
            SIMD3<Float>(localMin.x, localMin.y, localMax.z),
            SIMD3<Float>(localMax.x, localMin.y, localMax.z),
            SIMD3<Float>(localMin.x, localMax.y, localMax.z),
            SIMD3<Float>(localMax.x, localMax.y, localMax.z)
        ]

        // ワールド座標に変換して新しいAABBを作成
        var worldMin = SIMD3<Float>(Float.greatestFiniteMagnitude, Float.greatestFiniteMagnitude, Float.greatestFiniteMagnitude)
        var worldMax = SIMD3<Float>(-Float.greatestFiniteMagnitude, -Float.greatestFiniteMagnitude, -Float.greatestFiniteMagnitude)

        for corner in corners {
            let worldPos4 = currentWorldTransform * SIMD4<Float>(corner.x, corner.y, corner.z, 1.0)
            let worldPos = SIMD3<Float>(worldPos4.x, worldPos4.y, worldPos4.z)
            worldMin = simd_min(worldMin, worldPos)
            worldMax = simd_max(worldMax, worldPos)
        }

        let currentAABB = AABB(min: worldMin, max: worldMax)

        // 交差判定結果をプロパティに保存
        // ★ 修正: アニメーション適用前のHips位置で判定しているため、カリング無効化
        // self.isVisible = frustum.intersects(aabb: currentAABB)
        self.isVisible = true
    }

    public func render(in view: MTKView) {
        guard let drawable = view.currentDrawable else { return }
        guard let renderPassDescriptor = view.currentRenderPassDescriptor else { return }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        commandBuffer.addCompletedHandler { cb in
            if let error = cb.error as NSError? {
                print("GPU Command Buffer Error: \(error.localizedDescription) (code \(error.code))")
            }
        }

        guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else { return }

        if self.isVisible {
            updateBoneMatrices()
            updateUniforms()

            renderEncoder.setDepthStencilState(depthStencilState)
            renderEncoder.setFrontFacing(.counterClockwise)

            if let model = model {
                renderModel(model, encoder: renderEncoder)
            }
        }

        renderEncoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    /// Pre-computed joint matrices for each skin (updated per frame)
    private var skinJointMatricesCache: [[simd_float4x4]] = []

    /// Update joint matrices for all skins
    private func updateAllSkinMatrices() {
        guard let model = model, let boneMatricesBuffer = boneMatricesBuffer else {
            skinJointMatricesCache = []
            hasSkinning = false
            return
        }

        // 1. 各スキンのボーン行列を計算
        skinJointMatricesCache = model.skins.map { $0.computeJointMatrices() }

        if !skinJointMatricesCache.isEmpty {
            hasSkinning = true

            // 2. すべてのスキンの行列をバッファに書き込む
            let bufferPtr = boneMatricesBuffer.contents().assumingMemoryBound(to: simd_float4x4.self)
            let maxBones = 256  // ShaderTypes.h の MAX_BONES と一致

            for (skinIndex, matrices) in skinJointMatricesCache.enumerated() {
                // 書き込み開始位置（オフセット）を計算
                let offset = skinIndex * maxBones

                // バッファオーバーラン防止
                let count = min(matrices.count, maxBones)

                for i in 0..<count {
                    bufferPtr[offset + i] = matrices[i]
                }
            }
        } else {
            hasSkinning = false
        }
    }

    /// Update bone matrices buffer for a specific skin index before drawing
    /// Note: Per-mesh skinning is temporarily disabled - using global hasSkinning flag
    private func bindBoneMatricesForSkin(_ skinIndex: Int?, encoder: MTLRenderCommandEncoder) {
        // Per-mesh skinning disabled - do nothing here
        // Bone matrices are set once in updateBoneMatrices
    }

    // Legacy updateBoneMatrices for compatibility - now calls updateAllSkinMatrices
    private func updateBoneMatrices() {
        updateAllSkinMatrices()
    }

    private func updateUniforms() {
        let viewMatrix = lookAt(eye: cameraPosition, center: cameraTarget, up: cameraUp)
        let aspect = Float(viewportSize.width / viewportSize.height)
        let projectionMatrix = perspective(fovY: fieldOfView * .pi / 180.0, aspect: aspect, near: nearPlane, far: farPlane)

        var uniforms = Uniforms(
            modelMatrix: matrix_identity_float4x4,
            viewMatrix: viewMatrix,
            projectionMatrix: projectionMatrix,
            viewProjectionMatrix: projectionMatrix * viewMatrix,
            normalMatrix: matrix_identity_float4x4,
            cameraPosition: cameraPosition,
            time: Float(CACurrentMediaTime()),
            morphTargetCount: 0,
            morphTargetStride: 0,
            hasSkinning: hasSkinning ? 1 : 0
        )

        uniformsBuffer?.contents().copyMemory(from: &uniforms, byteCount: MemoryLayout<Uniforms>.stride)

        // Light uniforms
        var lightUniforms = LightUniforms()
        lightUniforms.lightCount = 1
        lightUniforms.ambientColor = SIMD4<Float>(ambientColor.x, ambientColor.y, ambientColor.z, 0)
        lightUniforms.lights.0.direction = SIMD4<Float>(lightDirection.x, lightDirection.y, lightDirection.z, 0)
        lightUniforms.lights.0.color = SIMD4<Float>(lightColor.x, lightColor.y, lightColor.z, 0)
        lightUniforms.lights.0.intensity = lightIntensity
        lightUniforms.lights.0.type = 0 // Directional

        lightBuffer?.contents().copyMemory(from: &lightUniforms, byteCount: MemoryLayout<LightUniforms>.stride)
    }

    private func renderModel(_ model: VRM1Model, encoder: MTLRenderCommandEncoder) {
        guard let pipelineState = pipelineState,
              let mtoonPipelineState = mtoonPipelineState else { return }

        // ベースとなるUniformsを作成（View/Projection行列など共通部分）
        let viewMatrix = lookAt(eye: cameraPosition, center: cameraTarget, up: cameraUp)
        let aspect = Float(viewportSize.width / viewportSize.height)
        let projectionMatrix = perspective(fovY: fieldOfView * .pi / 180.0, aspect: aspect, near: nearPlane, far: farPlane)

        var baseUniforms = Uniforms(
            modelMatrix: matrix_identity_float4x4,
            viewMatrix: viewMatrix,
            projectionMatrix: projectionMatrix,
            viewProjectionMatrix: projectionMatrix * viewMatrix,
            normalMatrix: matrix_identity_float4x4,
            cameraPosition: cameraPosition,
            time: Float(CACurrentMediaTime()),
            morphTargetCount: 0,
            morphTargetStride: 0,
            hasSkinning: 0
        )

        // 共通バッファの設定（boneMatricesBufferは描画ごとにオフセット指定でバインド）
        encoder.setVertexBuffer(morphWeightsBuffer, offset: 0, index: 3)  // Morph weights
        encoder.setVertexBuffer(morphDeltasBuffer, offset: 0, index: 4)   // Morph deltas
        encoder.setFragmentBuffer(lightBuffer, offset: 0, index: 6)
        encoder.setFragmentSamplerState(defaultSampler, index: 0)

        // 【最適化】配列を再利用（メモリ確保を回避）
        opaqueCommands.removeAll(keepingCapacity: true)
        transparentCommands.removeAll(keepingCapacity: true)

        // ノード単位でイテレーション（スキニングされていないメッシュも正しい位置で描画）
        for node in model.allNodes {
            // 【修正】node.meshは初期化時のコピー（Struct）なので、最新のウェイトが反映されていません。
            // そのため、インデックスを使って model.meshes（原本）から最新のデータを取得します。
            guard let meshInfo = node.mesh,
                  meshInfo.index < model.meshes.count else { continue }

            let mesh = model.meshes[meshInfo.index]

            for (primitiveIndex, _) in mesh.primitives.enumerated() {
                let key = mesh.index * 1000 + primitiveIndex
                guard let gpuData = meshBuffers[key] else { continue }

                // gpuData.skinIndexを優先（setModelで全ノード走査して解決済み）
                // なければノードのスキン情報を使用
                let effectiveSkinIndex = gpuData.skinIndex ?? node.gltfNode.skin

                var material: VRM1Material?
                var useMToon = false
                if let materialIndex = gpuData.materialIndex, materialIndex < model.materials.count {
                    material = model.materials[materialIndex]
                    useMToon = material?.isMToon ?? false
                }

                let command = DrawCommand(
                    gpuData: gpuData,
                    material: material,
                    useMToon: useMToon,
                    skinIndex: effectiveSkinIndex,
                    worldTransform: node.worldTransform,
                    key: key,
                    morphWeights: mesh.morphWeights
                )

                // Sort by alpha mode: BLEND goes to transparent, others to opaque
                if material?.alphaMode == .blend {
                    transparentCommands.append(command)
                } else {
                    opaqueCommands.append(command)
                }
            }
        }

        // コマンド実行用ヘルパー関数
        func executeCommands(_ commands: [DrawCommand]) {
            let maxBones = 256
            let matrixStride = MemoryLayout<simd_float4x4>.stride

            for cmd in commands {
                // この描画呼び出し用のUniformsを準備
                var currentUniforms = baseUniforms

                if let skinIndex = cmd.skinIndex {
                    // スキニングあり: そのスキン専用のオフセットでバッファをバインド
                    let bufferOffset = skinIndex * maxBones * matrixStride
                    encoder.setVertexBuffer(boneMatricesBuffer, offset: bufferOffset, index: 2)

                    currentUniforms.modelMatrix = matrix_identity_float4x4
                    currentUniforms.normalMatrix = matrix_identity_float4x4
                    currentUniforms.hasSkinning = 1
                } else {
                    // スキニングなし: ノードのワールド行列を使用
                    encoder.setVertexBuffer(boneMatricesBuffer, offset: 0, index: 2)

                    currentUniforms.modelMatrix = cmd.worldTransform
                    currentUniforms.normalMatrix = cmd.worldTransform  // 簡易的（等方スケール前提）
                    currentUniforms.hasSkinning = 0
                }

                // モーフターゲットの処理
                // ★修正: setVertexBytes を使用してコマンドごとにウェイトを埋め込む
                // これにより、GPU実行時にバッファが上書きされる問題を回避
                if let morphData = meshMorphData[cmd.key], !cmd.morphWeights.isEmpty {
                    // ウェイト配列の準備（MAX_MORPH_TARGETS=64に合わせる）
                    var weights = cmd.morphWeights
                    let maxTargets = 64
                    if weights.count < maxTargets {
                        weights.append(contentsOf: repeatElement(Float(0), count: maxTargets - weights.count))
                    } else if weights.count > maxTargets {
                        weights = Array(weights.prefix(maxTargets))
                    }

                    // モーフデルタバッファをバインド
                    encoder.setVertexBuffer(morphData.morphDeltasBuffer, offset: 0, index: 4)

                    // ★修正: setVertexBytes でウェイトをコマンドバッファに直接埋め込む
                    encoder.setVertexBytes(&weights, length: weights.count * MemoryLayout<Float>.stride, index: 3)

                    // morphTargetCountを設定（ループ回数）
                    let weightsCount = min(cmd.morphWeights.count, morphData.morphTargetCount)
                    currentUniforms.morphTargetCount = UInt32(weightsCount)

                    // 【追加】morphTargetStrideを設定（バッファ生成時の固定カウントを使用）
                    currentUniforms.morphTargetStride = UInt32(morphData.morphTargetCount)
                } else {
                    // モーフターゲットなし - ゼロ埋めウェイトを送信
                    var zeroWeights = [Float](repeating: 0, count: 64)
                    encoder.setVertexBytes(&zeroWeights, length: zeroWeights.count * MemoryLayout<Float>.stride, index: 3)
                    encoder.setVertexBuffer(morphDeltasBuffer, offset: 0, index: 4)
                    currentUniforms.morphTargetCount = 0
                    currentUniforms.morphTargetStride = 0  // 【追加】安全のため
                }

                encoder.setVertexBytes(&currentUniforms, length: MemoryLayout<Uniforms>.stride, index: 1)

                // 【最適化】マテリアルの設定に従ってカリングを行う
                // doubleSided=trueなら両面描画(.none)、falseなら裏面削除(.back)
                if let material = cmd.material, material.doubleSided {
                    encoder.setCullMode(.none)
                } else {
                    encoder.setCullMode(.back)
                }

                if cmd.useMToon, let mat = cmd.material {
                    encoder.setRenderPipelineState(mtoonPipelineState)
                    renderMToonPrimitive(encoder: encoder, gpuData: cmd.gpuData, material: mat)
                } else {
                    encoder.setRenderPipelineState(pipelineState)
                    renderPBRPrimitive(encoder: encoder, gpuData: cmd.gpuData, material: cmd.material)
                }
            }
        }

        // 1. Draw opaque objects first (writes to Z-buffer)
        executeCommands(opaqueCommands)

        // 2. Draw transparent objects last (proper blending)
        executeCommands(transparentCommands)
    }

    private func renderPBRPrimitive(encoder: MTLRenderCommandEncoder, gpuData: MeshGPUData, material: VRM1Material?) {
        var materialUniforms = MaterialUniforms()
        materialUniforms.debugMode = debugMode

        if let material = material {
            materialUniforms.baseColorFactor = material.baseColorFactor
            materialUniforms.emissiveFactor = material.emissiveFactor
            materialUniforms.metallicFactor = material.metallicFactor
            materialUniforms.roughnessFactor = material.roughnessFactor
            materialUniforms.alphaCutoff = material.alphaCutoff
            materialUniforms.alphaMode = Int32(material.alphaMode == .mask ? 1 : (material.alphaMode == .blend ? 2 : 0))
            materialUniforms.doubleSided = material.doubleSided ? 1 : 0
            materialUniforms.textureTransform = material.textureTransform

            // Bind base color texture
            if let textureIndex = material.baseColorTextureIndex,
               textureIndex < textures.count,
               let texture = textures[textureIndex] {
                encoder.setFragmentTexture(texture, index: 0)
                materialUniforms.hasBaseColorTexture = 1
            } else {
                encoder.setFragmentTexture(whiteTexture, index: 0)
                materialUniforms.hasBaseColorTexture = 0
            }
        } else {
            materialUniforms.baseColorFactor = SIMD4<Float>(1, 1, 1, 1)
            materialUniforms.metallicFactor = 0.0
            materialUniforms.roughnessFactor = 0.5
            materialUniforms.hasBaseColorTexture = 0
            materialUniforms.textureTransform = SIMD4<Float>(1, 1, 0, 0)
            encoder.setFragmentTexture(whiteTexture, index: 0)
        }

        encoder.setFragmentBytes(&materialUniforms, length: MemoryLayout<MaterialUniforms>.stride, index: 5)
        drawPrimitive(encoder: encoder, gpuData: gpuData)
    }

    private func renderMToonPrimitive(encoder: MTLRenderCommandEncoder, gpuData: MeshGPUData, material: VRM1Material) {
        var mtoonUniforms = MToonMaterialUniforms()

        // Base colors
        mtoonUniforms.litColor = material.baseColorFactor
        mtoonUniforms.shadeColor = material.shadeColorFactor
        mtoonUniforms.emissionColor = SIMD4<Float>(material.emissiveFactor.x, material.emissiveFactor.y, material.emissiveFactor.z, 1.0)
        mtoonUniforms.matcapColor = material.matcapFactor
        mtoonUniforms.rimColor = material.rimColorFactor
        mtoonUniforms.outlineColor = material.outlineColorFactor

        // Shading parameters
        mtoonUniforms.shadeShift = material.shadingShiftFactor
        mtoonUniforms.shadeToony = material.shadingToonyFactor
        mtoonUniforms.rimLightingMix = material.rimLightingMixFactor
        mtoonUniforms.rimFresnelPower = material.rimFresnelPowerFactor
        mtoonUniforms.rimLift = material.rimLiftFactor

        // Outline
        mtoonUniforms.outlineWidth = material.outlineWidthFactor
        mtoonUniforms.outlineWidthMode = Int32(material.outlineWidthMode)
        mtoonUniforms.outlineLightingMix = material.outlineLightingMixFactor
        mtoonUniforms.outlineScaledMaxDistance = 1.0

        // Alpha
        mtoonUniforms.alphaCutoff = material.alphaCutoff
        mtoonUniforms.alphaMode = Int32(material.alphaMode == .mask ? 1 : (material.alphaMode == .blend ? 2 : 0))
        mtoonUniforms.isOutlinePass = 0

        // Debug mode
        mtoonUniforms.debugMode = debugMode

        // Texture transform
        mtoonUniforms.textureTransform = material.textureTransform

        // Texture flags - initialize to 0, set to 1 only when texture actually binds
        mtoonUniforms.hasShadeMultiplyTexture = 0
        mtoonUniforms.hasMatcapTexture = 0
        mtoonUniforms.hasRimMultiplyTexture = 0
        mtoonUniforms.hasOutlineWidthTexture = 0
        mtoonUniforms.hasUVAnimationMaskTexture = 0

        // Bind textures - only set flag when texture actually exists
        if let textureIndex = material.baseColorTextureIndex,
           textureIndex < textures.count,
           let texture = textures[textureIndex] {
            encoder.setFragmentTexture(texture, index: 0)  // TextureIndexBaseColor
        } else {
            encoder.setFragmentTexture(whiteTexture, index: 0)
        }

        // ShadeMultiplyTexture - only set flag if texture actually binds
        if let textureIndex = material.shadeMultiplyTextureIndex,
           textureIndex < textures.count,
           let texture = textures[textureIndex] {
            encoder.setFragmentTexture(texture, index: 5)  // TextureIndexShadeMultiply
            mtoonUniforms.hasShadeMultiplyTexture = 1      // Set flag only on successful bind
        }
        // If no shade texture, flag stays 0 and shader will use baseTexColor for shading

        // Matcap texture
        if let textureIndex = material.matcapTextureIndex,
           textureIndex < textures.count,
           let texture = textures[textureIndex] {
            encoder.setFragmentTexture(texture, index: 6)  // TextureIndexMatcap
            mtoonUniforms.hasMatcapTexture = 1             // Set flag only on successful bind
        }

        encoder.setFragmentBytes(&mtoonUniforms, length: MemoryLayout<MToonMaterialUniforms>.stride, index: 5)
        drawPrimitive(encoder: encoder, gpuData: gpuData)
    }

    private func drawPrimitive(encoder: MTLRenderCommandEncoder, gpuData: MeshGPUData) {
        encoder.setVertexBuffer(gpuData.vertexBuffer, offset: 0, index: 0)

        if let indexBuffer = gpuData.indexBuffer {
            encoder.drawIndexedPrimitives(
                type: .triangle,
                indexCount: gpuData.indexCount,
                indexType: .uint32,
                indexBuffer: indexBuffer,
                indexBufferOffset: 0
            )
        } else {
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: gpuData.vertexCount)
        }
    }

    // MARK: - Matrix Helpers

    private func lookAt(eye: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
        let f = normalize(center - eye)
        let s = normalize(cross(f, up))
        let u = cross(s, f)

        return simd_float4x4(
            SIMD4<Float>(s.x, u.x, -f.x, 0),
            SIMD4<Float>(s.y, u.y, -f.y, 0),
            SIMD4<Float>(s.z, u.z, -f.z, 0),
            SIMD4<Float>(-dot(s, eye), -dot(u, eye), dot(f, eye), 1)
        )
    }

    private func perspective(fovY: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
        let y = 1.0 / tan(fovY * 0.5)
        let x = y / aspect
        let z = far / (near - far)

        return simd_float4x4(
            SIMD4<Float>(x, 0, 0, 0),
            SIMD4<Float>(0, y, 0, 0),
            SIMD4<Float>(0, 0, z, -1),
            SIMD4<Float>(0, 0, z * near, 0)
        )
    }

    /// Check if matrix is close to identity (used for detecting undefined IBMs)
    private func isIdentityMatrix(_ matrix: simd_float4x4) -> Bool {
        let epsilon: Float = 0.001
        return abs(matrix.columns.0.x - 1) < epsilon &&
               abs(matrix.columns.0.y) < epsilon &&
               abs(matrix.columns.0.z) < epsilon &&
               abs(matrix.columns.1.x) < epsilon &&
               abs(matrix.columns.1.y - 1) < epsilon &&
               abs(matrix.columns.1.z) < epsilon &&
               abs(matrix.columns.2.x) < epsilon &&
               abs(matrix.columns.2.y) < epsilon &&
               abs(matrix.columns.2.z - 1) < epsilon &&
               abs(matrix.columns.3.x) < epsilon &&
               abs(matrix.columns.3.y) < epsilon &&
               abs(matrix.columns.3.z) < epsilon
    }
}

// MARK: - Safe Array Subscript
private extension Array {
    subscript(safe index: Int) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}

// MARK: - Shader Uniform Structures (Mirror ShaderTypes.h)

struct Uniforms {
    var modelMatrix: simd_float4x4
    var viewMatrix: simd_float4x4
    var projectionMatrix: simd_float4x4
    var viewProjectionMatrix: simd_float4x4
    var normalMatrix: simd_float4x4
    var cameraPosition: SIMD3<Float>
    var time: Float
    var morphTargetCount: UInt32
    var morphTargetStride: UInt32
    var hasSkinning: UInt32
}

// MaterialUniforms must match Metal ShaderTypes.h layout exactly
// SIMD3<Float> in Swift automatically uses 16 bytes (12 data + 4 padding) in structs
struct MaterialUniforms {
    var baseColorFactor: SIMD4<Float> = SIMD4<Float>(1, 1, 1, 1)  // 16 bytes, offset 0
    var emissiveFactor: SIMD3<Float> = SIMD3<Float>(0, 0, 0)      // 16 bytes (auto-padded), offset 16
    var metallicFactor: Float = 0.0                                // 4 bytes, offset 32 (default 0 for dielectric)
    var roughnessFactor: Float = 0.5                               // 4 bytes, offset 36 (default 0.5)
    var alphaCutoff: Float = 0.5                                   // 4 bytes, offset 40
    var alphaMode: Int32 = 0                                       // 4 bytes, offset 44
    var doubleSided: Int32 = 0                                     // 4 bytes, offset 48
    var hasBaseColorTexture: Int32 = 0                             // 4 bytes, offset 52
    var hasNormalTexture: Int32 = 0                                // 4 bytes, offset 56
    var hasEmissiveTexture: Int32 = 0                              // 4 bytes, offset 60
    var hasMetallicRoughnessTexture: Int32 = 0                     // 4 bytes, offset 64
    var debugMode: Int32 = 0                                       // 4 bytes, offset 68
    var _pad1: Float = 0                                           // 4 bytes, offset 72
    var _pad2: Float = 0                                           // 4 bytes, offset 76
    var textureTransform: SIMD4<Float> = SIMD4<Float>(1, 1, 0, 0) // 16 bytes, offset 80 (ScaleXY, OffsetXY)
    // Total: 96 bytes
}

// LightData must match Metal shader layout exactly (64 bytes per light)
// Using SIMD4 to ensure correct 16-byte alignment
struct LightData {
    // direction.xyz = light direction, direction.w = padding
    var direction: SIMD4<Float> = SIMD4<Float>(0, -1, 0, 0)  // 16 bytes

    // intensity + padding to 16 bytes
    var intensity: Float = 1.0
    private var _pad1: Float = 0
    private var _pad2: Float = 0
    private var _pad3: Float = 0  // 16 bytes total

    // color.xyz = light color, color.w = padding
    var color: SIMD4<Float> = SIMD4<Float>(1, 1, 1, 0)  // 16 bytes

    // type + padding to 16 bytes
    var type: Int32 = 0
    private var _pad4: Float = 0
    private var _pad5: Float = 0
    private var _pad6: Float = 0  // 16 bytes total

    // Total: 64 bytes per LightData
}

// LightUniforms must match Metal shader layout (288 bytes total)
struct LightUniforms {
    // 4 lights × 64 bytes = 256 bytes
    var lights: (LightData, LightData, LightData, LightData) = (LightData(), LightData(), LightData(), LightData())

    // int lightCount + padding to 16 bytes
    var lightCount: Int32 = 0
    private var _pad1: Float = 0
    private var _pad2: Float = 0
    private var _pad3: Float = 0  // 16 bytes total

    // ambientColor.xyz + padding
    var ambientColor: SIMD4<Float> = SIMD4<Float>(0.3, 0.3, 0.3, 0)  // 16 bytes

    // Total: 256 + 16 + 16 = 288 bytes
}

// MToonMaterialUniforms must match Metal ShaderTypes.h MToonMaterialUniforms layout
struct MToonMaterialUniforms {
    // Base colors (each SIMD4 = 16 bytes)
    var litColor: SIMD4<Float> = SIMD4<Float>(1, 1, 1, 1)
    var shadeColor: SIMD4<Float> = SIMD4<Float>(0.5, 0.5, 0.5, 1)
    var emissionColor: SIMD4<Float> = SIMD4<Float>(0, 0, 0, 1)
    var matcapColor: SIMD4<Float> = SIMD4<Float>(1, 1, 1, 1)
    var rimColor: SIMD4<Float> = SIMD4<Float>(0, 0, 0, 1)
    var outlineColor: SIMD4<Float> = SIMD4<Float>(0, 0, 0, 1)

    // Shading parameters
    var shadeShift: Float = 0.0
    var shadeToony: Float = 0.9
    var rimLightingMix: Float = 1.0
    var rimFresnelPower: Float = 5.0
    var rimLift: Float = 0.0

    // Outline parameters
    var outlineWidth: Float = 0.0
    var outlineScaledMaxDistance: Float = 1.0
    var outlineLightingMix: Float = 1.0
    var outlineWidthMode: Int32 = 0

    // Texture flags
    var hasShadeMultiplyTexture: Int32 = 0
    var hasMatcapTexture: Int32 = 0
    var hasRimMultiplyTexture: Int32 = 0
    var hasOutlineWidthTexture: Int32 = 0
    var hasUVAnimationMaskTexture: Int32 = 0

    // UV animation
    var uvAnimationScrollXSpeed: Float = 0.0
    var uvAnimationScrollYSpeed: Float = 0.0
    var uvAnimationRotationSpeed: Float = 0.0

    // Alpha
    var alphaCutoff: Float = 0.5
    var alphaMode: Int32 = 0
    var isOutlinePass: Int32 = 0

    // Debug mode: 0=normal, 1=UV, 2=unlit texture, 3=normals, 4=white highlight
    var debugMode: Int32 = 0

    // Texture transform (ScaleX, ScaleY, OffsetX, OffsetY)
    var textureTransform: SIMD4<Float> = SIMD4<Float>(1, 1, 0, 0)
}
