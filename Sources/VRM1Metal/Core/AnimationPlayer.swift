import Foundation
import simd

// MARK: - Animation Clip

/// Animation clip containing keyframe data for bones
public final class AnimationClip {
    public let name: String
    public let duration: Float
    public var isLooping: Bool = true

    /// Bone animation tracks
    public var tracks: [String: AnimationTrack] = [:]

    public init(name: String, duration: Float) {
        self.name = name
        self.duration = duration
    }

    /// Create from FBX animation
    public static func fromFBX(_ fbxAnimation: FBXAnimationLoader.FBXAnimation) -> AnimationClip {
        let clip = AnimationClip(name: fbxAnimation.name, duration: fbxAnimation.duration)
        clip.isLooping = true

        for (boneName, curve) in fbxAnimation.curves {
            clip.addRotationTrack(boneName: boneName, times: curve.times, rotations: curve.rotations)
            if let translations = curve.translations {
                clip.addTranslationTrack(boneName: boneName, times: curve.times, translations: translations)
            }
        }

        return clip
    }

    /// Add a rotation track for a bone
    public func addRotationTrack(boneName: String, times: [Float], rotations: [simd_quatf]) {
        var track = tracks[boneName] ?? AnimationTrack(boneName: boneName)
        track.rotationTimes = times
        track.rotations = rotations
        tracks[boneName] = track
    }

    /// Add a translation track for a bone
    public func addTranslationTrack(boneName: String, times: [Float], translations: [SIMD3<Float>]) {
        var track = tracks[boneName] ?? AnimationTrack(boneName: boneName)
        track.translationTimes = times
        track.translations = translations
        tracks[boneName] = track
    }

    /// Add a scale track for a bone
    public func addScaleTrack(boneName: String, times: [Float], scales: [SIMD3<Float>]) {
        var track = tracks[boneName] ?? AnimationTrack(boneName: boneName)
        track.scaleTimes = times
        track.scales = scales
        tracks[boneName] = track
    }
}

// MARK: - Animation Track

/// Single bone's animation data
public struct AnimationTrack {
    public let boneName: String

    public var rotationTimes: [Float] = []
    public var rotations: [simd_quatf] = []

    public var translationTimes: [Float] = []
    public var translations: [SIMD3<Float>] = []

    public var scaleTimes: [Float] = []
    public var scales: [SIMD3<Float>] = []

    public init(boneName: String) {
        self.boneName = boneName
    }

    /// Get interpolated rotation at time t
    public func getRotation(at time: Float) -> simd_quatf? {
        guard !rotations.isEmpty, !rotationTimes.isEmpty else { return nil }

        // Find keyframe indices
        let (i0, i1, t) = findKeyframeIndices(time: time, times: rotationTimes)

        // Spherical interpolation between quaternions
        return simd_slerp(rotations[i0], rotations[i1], t)
    }

    /// Get interpolated translation at time t
    public func getTranslation(at time: Float) -> SIMD3<Float>? {
        guard !translations.isEmpty, !translationTimes.isEmpty else { return nil }

        let (i0, i1, t) = findKeyframeIndices(time: time, times: translationTimes)
        return mix(translations[i0], translations[i1], t: t)
    }

    /// Get interpolated scale at time t
    public func getScale(at time: Float) -> SIMD3<Float>? {
        guard !scales.isEmpty, !scaleTimes.isEmpty else { return nil }

        let (i0, i1, t) = findKeyframeIndices(time: time, times: scaleTimes)
        return mix(scales[i0], scales[i1], t: t)
    }

    private func findKeyframeIndices(time: Float, times: [Float]) -> (Int, Int, Float) {
        guard times.count > 1 else {
            return (0, 0, 0)
        }

        // Find the two keyframes we're between
        for i in 0..<(times.count - 1) {
            if time >= times[i] && time <= times[i + 1] {
                let segmentDuration = times[i + 1] - times[i]
                let t = segmentDuration > 0 ? (time - times[i]) / segmentDuration : 0
                return (i, i + 1, t)
            }
        }

        // Past end - return last keyframe
        if time >= times.last! {
            return (times.count - 1, times.count - 1, 0)
        }

        // Before start - return first keyframe
        return (0, 0, 0)
    }
}

// MARK: - Animation State

/// 個々のアニメーション再生状態を管理するクラス
public class AnimationState: Identifiable {
    public let id = UUID()
    public let clip: AnimationClip
    public var time: Float = 0
    public var weight: Float = 0
    public var speed: Float = 1.0

    /// フェード処理用
    public var targetWeight: Float = 1.0
    public var fadeSpeed: Float = 0.0 // 1.0 / duration

    public init(clip: AnimationClip, weight: Float = 1.0) {
        self.clip = clip
        self.weight = weight
        self.targetWeight = weight
    }

    /// 時間を進め、ウェイトを更新する
    /// - Returns: アニメーションが終了（ウェイトが0になり、かつターゲットも0）していれば true
    func update(deltaTime: Float) -> Bool {
        // 時間の更新
        time += deltaTime * speed

        if clip.isLooping {
            // 安全策: durationが極端に短い場合のゼロ除算/無限ループ防止
            let duration = max(clip.duration, 0.001)
            time = time.truncatingRemainder(dividingBy: duration)
        } else if time > clip.duration {
            time = clip.duration
        }

        // ウェイトの更新（フェード処理）
        if abs(weight - targetWeight) > 0.0001 {
            let change = fadeSpeed * deltaTime
            if weight < targetWeight {
                weight = min(targetWeight, weight + change)
            } else {
                weight = max(targetWeight, weight - change)
            }
        }

        // ターゲットが0で、現在もほぼ0なら終了とみなす
        return targetWeight == 0 && weight <= 0.0001
    }
}

// MARK: - Animation Player

/// アニメーション再生・ブレンドコントローラー
public final class AnimationPlayer: ObservableObject {

    /// 再生中の全アニメーションレイヤー
    @Published public var layers: [AnimationState] = []

    /// 再生状態
    @Published public var isPlaying: Bool = false
    @Published public var globalSpeed: Float = 1.0

    /// 現在のクリップ（互換性のため）
    @Published public var currentClip: AnimationClip?
    /// 【最適化】@Published を外してCombine通知を抑制（毎フレーム60回の通知が不要）
    public var currentTime: Float = 0
    @Published public var playbackSpeed: Float = 1.0

    /// ボーン名マッピング (Animation Bone Name -> VRM Bone Name)
    public var boneMapping: [String: String] = [:]

    /// ノード検索用コールバック
    public var nodeForBone: ((String) -> VRM1Node?)? {
        didSet {
            // コールバックが変わったらキャッシュをクリア
            nodeCache.removeAll()
        }
    }

    /// デフォルトの遷移時間（30フレーム @ 60fps）
    public var defaultTransitionDuration: Float = 30.0 / 60.0

    // デバッグ用カウンタ
    private var debugUpdateCounter = 0

    // 【最適化】ボーン検索の高速化用キャッシュ
    // Animationのトラック名 -> 実際のVRM1Node
    private var nodeCache: [String: VRM1Node] = [:]

    // 【最適化】毎フレームのDictionary生成を回避するための事前確保バッファ
    // ObjectIdentifier -> 配列インデックス
    private var nodeIndexMap: [ObjectIdentifier: Int] = [:]
    // 事前確保された配列（ノードへの参照、変換データ、ウェイト合計）
    private var rotationNodes: [VRM1Node?] = []
    private var rotationQuats: [simd_quatf] = []
    private var rotationWeights: [Float] = []
    private var translationNodes: [VRM1Node?] = []
    private var translationPos: [SIMD3<Float>] = []
    private var translationWeights: [Float] = []
    private var activeRotationCount: Int = 0
    private var activeTranslationCount: Int = 0
    private var buffersReady: Bool = false

    public init() {
        setupDefaultBoneMapping()
    }

    /// 【最適化】バッファを事前確保（モデル読み込み時に呼び出す）
    public func prepareBuffers(nodeCount: Int) {
        let capacity = max(nodeCount, 64)
        rotationNodes = Array(repeating: nil, count: capacity)
        rotationQuats = Array(repeating: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1), count: capacity)
        rotationWeights = Array(repeating: 0, count: capacity)
        translationNodes = Array(repeating: nil, count: capacity)
        translationPos = Array(repeating: SIMD3<Float>(0, 0, 0), count: capacity)
        translationWeights = Array(repeating: 0, count: capacity)
        nodeIndexMap.reserveCapacity(capacity)
        buffersReady = true
    }

    // MARK: - Playback Control

    /// アニメーションを再生する（クロスフェード対応）
    /// - Parameters:
    ///   - clip: 再生するクリップ
    ///   - transitionDuration: 遷移にかける時間（秒）。nilの場合はdefaultTransitionDurationを使用。
    public func play(_ clip: AnimationClip, transitionDuration: Float? = nil) {
        // 【最適化】再生開始時に、このクリップで使うボーンを事前にキャッシュする
        prewarmCache(for: clip)

        isPlaying = true
        currentClip = clip
        currentTime = 0

        let duration = transitionDuration ?? defaultTransitionDuration

        // 新しいアニメーションの状態を作成
        let newState = AnimationState(clip: clip, weight: 0.0)
        newState.targetWeight = 1.0

        if duration > 0 && !layers.isEmpty {
            newState.fadeSpeed = 1.0 / duration

            // 既存のアニメーションをフェードアウトさせる
            for layer in layers {
                layer.targetWeight = 0.0
                layer.fadeSpeed = 1.0 / duration
            }
        } else {
            // 即時切り替えの場合、既存レイヤーを全て削除
            layers.removeAll()
            newState.weight = 1.0
        }

        layers.append(newState)
    }

    /// 全てのアニメーションを停止・削除
    public func stop() {
        isPlaying = false
        currentTime = 0
        layers.removeAll()
    }

    /// 一時停止
    public func pause() {
        isPlaying = false
    }

    /// 再開
    public func resume() {
        isPlaying = true
    }

    // MARK: - Update Logic

    /// フレーム更新処理
    public func update(deltaTime: Float) {
        guard isPlaying else { return }

        // 【二重安全装置】異常なDeltaTimeを無視
        // VRM1View側で0.5秒以上を検出してリセットするが、念のためここでも1秒以上をガード
        // スリープ/バックグラウンド復帰時の「爆速ループ」問題を防止
        let safeDelta = (deltaTime > 1.0 || deltaTime < 0) ? 0.016 : deltaTime
        let adjustedDelta = safeDelta * globalSpeed * playbackSpeed

        // 1. 各レイヤーの状態更新
        // 終了したレイヤー（ウェイト0）は除去する
        layers.removeAll { state in
            state.update(deltaTime: adjustedDelta)
        }

        // 互換性のために情報を更新
        if let activeLayer = layers.last {
            currentTime = activeLayer.time
        }

        guard !layers.isEmpty else { return }

        // 2. ブレンド計算と適用
        applyBlendedAnimation()

        debugUpdateCounter += 1
    }

    // 【最適化】高速化されたキャッシュ解決メソッド
    private func resolveNode(trackName: String) -> VRM1Node? {
        // 1. キャッシュにあれば即リターン（最速）
        if let cached = nodeCache[trackName] {
            return cached
        }

        // 2. なければマッピングして検索
        let vrmBoneName = boneMapping[trackName] ?? trackName

        if let node = nodeForBone?(vrmBoneName) {
            // 3. 見つかったらキャッシュに保存
            nodeCache[trackName] = node
            return node
        }

        return nil
    }

    // 【最適化】クリップに含まれる全トラックのノードを事前に解決しておく
    private func prewarmCache(for clip: AnimationClip) {
        for (trackName, _) in clip.tracks {
            _ = resolveNode(trackName: trackName)
        }
    }

    /// ブレンドされたアニメーションを適用（最適化版）
    private func applyBlendedAnimation() {
        // 【最適化】事前確保バッファを使用（Dictionaryの毎フレーム生成を回避）
        if !buffersReady {
            // バッファ未初期化の場合はフォールバック（初回のみ）
            applyBlendedAnimationLegacy()
            return
        }

        // カウンタをリセット（配列自体は再利用）
        activeRotationCount = 0
        activeTranslationCount = 0
        nodeIndexMap.removeAll(keepingCapacity: true)

        // 各レイヤーからトランスフォームを収集
        for layer in layers {
            let layerWeight = layer.weight
            guard layerWeight > 0.0001 else { continue }
            let time = layer.time

            for (animBoneName, track) in layer.clip.tracks {
                // 【最適化】キャッシュからノードを取得（文字列検索なし）
                guard let node = resolveNode(trackName: animBoneName) else { continue }
                let key = ObjectIdentifier(node)

                // 回転の取得と加算
                if let rotation = track.getRotation(at: time) {
                    if let idx = nodeIndexMap[key] {
                        // 既存エントリを更新
                        let currentWeight = rotationWeights[idx]
                        let newWeightSum = currentWeight + layerWeight
                        let t = layerWeight / newWeightSum
                        rotationQuats[idx] = simd_slerp(rotationQuats[idx], rotation, t)
                        rotationWeights[idx] = newWeightSum
                    } else {
                        // 新規エントリ
                        let idx = activeRotationCount
                        if idx < rotationNodes.count {
                            rotationNodes[idx] = node
                            rotationQuats[idx] = rotation
                            rotationWeights[idx] = layerWeight
                            nodeIndexMap[key] = idx
                            activeRotationCount += 1
                        }
                    }
                }

                // 移動の取得と加算
                if let translation = track.getTranslation(at: time) {
                    // 簡易実装: 移動は稀なので別配列で線形検索
                    var foundIdx: Int? = nil
                    for i in 0..<activeTranslationCount {
                        if translationNodes[i] === node {
                            foundIdx = i
                            break
                        }
                    }

                    if let idx = foundIdx {
                        // 既存エントリを更新
                        let currentWeight = translationWeights[idx]
                        let newWeightSum = currentWeight + layerWeight
                        let t = layerWeight / newWeightSum
                        translationPos[idx] = mix(translationPos[idx], translation, t: t)
                        translationWeights[idx] = newWeightSum
                    } else {
                        // 新規エントリ
                        let idx = activeTranslationCount
                        if idx < translationNodes.count {
                            translationNodes[idx] = node
                            translationPos[idx] = translation
                            translationWeights[idx] = layerWeight
                            activeTranslationCount += 1
                        }
                    }
                }
            }
        }

        // 結果をVRMノードに適用（配列のインデックスアクセスで高速）
        for i in 0..<activeRotationCount {
            rotationNodes[i]?.setRotation(rotationQuats[i])
        }

        for i in 0..<activeTranslationCount {
            translationNodes[i]?.setTranslation(translationPos[i])
        }
    }

    /// フォールバック用の旧実装（バッファ未初期化時）
    private func applyBlendedAnimationLegacy() {
        var accumulatedRotations: [ObjectIdentifier: (node: VRM1Node, quat: simd_quatf, weightSum: Float)] = [:]
        var accumulatedTranslations: [ObjectIdentifier: (node: VRM1Node, pos: SIMD3<Float>, weightSum: Float)] = [:]

        for layer in layers {
            let layerWeight = layer.weight
            guard layerWeight > 0.0001 else { continue }
            let time = layer.time

            for (animBoneName, track) in layer.clip.tracks {
                guard let node = resolveNode(trackName: animBoneName) else { continue }
                let key = ObjectIdentifier(node)

                if let rotation = track.getRotation(at: time) {
                    if let current = accumulatedRotations[key] {
                        let newWeightSum = current.weightSum + layerWeight
                        let t = layerWeight / newWeightSum
                        let blendedRot = simd_slerp(current.quat, rotation, t)
                        accumulatedRotations[key] = (node, blendedRot, newWeightSum)
                    } else {
                        accumulatedRotations[key] = (node, rotation, layerWeight)
                    }
                }

                if let translation = track.getTranslation(at: time) {
                    if let current = accumulatedTranslations[key] {
                        let newWeightSum = current.weightSum + layerWeight
                        let t = layerWeight / newWeightSum
                        let blendedPos = mix(current.pos, translation, t: t)
                        accumulatedTranslations[key] = (node, blendedPos, newWeightSum)
                    } else {
                        accumulatedTranslations[key] = (node, translation, layerWeight)
                    }
                }
            }
        }

        for data in accumulatedRotations.values {
            data.node.setRotation(data.quat)
        }

        for data in accumulatedTranslations.values {
            data.node.setTranslation(data.pos)
        }
    }

    /// デフォルトのボーンマッピング設定 (Unity-chan to VRM)
    private func setupDefaultBoneMapping() {
        boneMapping = [
            // Spine
            "Character1_Hips": "hips",
            "Character1_Spine": "spine",
            "Character1_Spine1": "chest",
            "Character1_Spine2": "chest",  // Map to chest if upperChest doesn't exist
            "Character1_Neck": "neck",
            "Character1_Head": "head",

            // Left arm
            "Character1_LeftShoulder": "leftShoulder",
            "Character1_LeftArm": "leftUpperArm",
            "Character1_LeftForeArm": "leftLowerArm",
            "Character1_LeftHand": "leftHand",

            // Right arm
            "Character1_RightShoulder": "rightShoulder",
            "Character1_RightArm": "rightUpperArm",
            "Character1_RightForeArm": "rightLowerArm",
            "Character1_RightHand": "rightHand",

            // Left leg
            "Character1_LeftUpLeg": "leftUpperLeg",
            "Character1_LeftLeg": "leftLowerLeg",
            "Character1_LeftFoot": "leftFoot",
            "Character1_LeftToeBase": "leftToes",

            // Right leg
            "Character1_RightUpLeg": "rightUpperLeg",
            "Character1_RightLeg": "rightLowerLeg",
            "Character1_RightFoot": "rightFoot",
            "Character1_RightToeBase": "rightToes",

            // Fingers - Left (VRM 1.0: Metacarpal, Proximal, Distal - no Intermediate for thumb)
            "Character1_LeftHandThumb1": "leftThumbMetacarpal",
            "Character1_LeftHandThumb2": "leftThumbProximal",
            "Character1_LeftHandThumb3": "leftThumbDistal",
            "Character1_LeftHandIndex1": "leftIndexProximal",
            "Character1_LeftHandIndex2": "leftIndexIntermediate",
            "Character1_LeftHandIndex3": "leftIndexDistal",
            "Character1_LeftHandMiddle1": "leftMiddleProximal",
            "Character1_LeftHandMiddle2": "leftMiddleIntermediate",
            "Character1_LeftHandMiddle3": "leftMiddleDistal",
            "Character1_LeftHandRing1": "leftRingProximal",
            "Character1_LeftHandRing2": "leftRingIntermediate",
            "Character1_LeftHandRing3": "leftRingDistal",
            "Character1_LeftHandPinky1": "leftLittleProximal",
            "Character1_LeftHandPinky2": "leftLittleIntermediate",
            "Character1_LeftHandPinky3": "leftLittleDistal",

            // Fingers - Right (VRM 1.0: Metacarpal, Proximal, Distal - no Intermediate for thumb)
            "Character1_RightHandThumb1": "rightThumbMetacarpal",
            "Character1_RightHandThumb2": "rightThumbProximal",
            "Character1_RightHandThumb3": "rightThumbDistal",
            "Character1_RightHandIndex1": "rightIndexProximal",
            "Character1_RightHandIndex2": "rightIndexIntermediate",
            "Character1_RightHandIndex3": "rightIndexDistal",
            "Character1_RightHandMiddle1": "rightMiddleProximal",
            "Character1_RightHandMiddle2": "rightMiddleIntermediate",
            "Character1_RightHandMiddle3": "rightMiddleDistal",
            "Character1_RightHandRing1": "rightRingProximal",
            "Character1_RightHandRing2": "rightRingIntermediate",
            "Character1_RightHandRing3": "rightRingDistal",
            "Character1_RightHandPinky1": "rightLittleProximal",
            "Character1_RightHandPinky2": "rightLittleIntermediate",
            "Character1_RightHandPinky3": "rightLittleDistal",
        ]
    }
}

// MARK: - Idle Animation Generator

public extension AnimationClip {
    /// Create a simple idle breathing animation
    static func createIdleBreathing(duration: Float = 3.0) -> AnimationClip {
        let clip = AnimationClip(name: "idle_breathing", duration: duration)
        clip.isLooping = true

        // Subtle spine rotation for breathing effect
        let frameCount = 30
        var times: [Float] = []
        var rotations: [simd_quatf] = []

        for i in 0...frameCount {
            let t = Float(i) / Float(frameCount) * duration
            times.append(t)

            // Subtle forward/back rotation (breathing)
            let phase = Float(i) / Float(frameCount) * Float.pi * 2
            let breathAngle = sin(phase) * 0.02  // Very subtle ~1 degree

            let rotation = simd_quatf(angle: breathAngle, axis: SIMD3<Float>(1, 0, 0))
            rotations.append(rotation)
        }

        clip.addRotationTrack(boneName: "spine", times: times, rotations: rotations)
        clip.addRotationTrack(boneName: "chest", times: times, rotations: rotations)

        return clip
    }

    /// Create a natural arm rest pose (arms down from T-pose)
    static func createRestPose() -> AnimationClip {
        let clip = AnimationClip(name: "rest_pose", duration: 0.001)
        clip.isLooping = false

        // Rotate arms down from T-pose
        let armAngle: Float = .pi * 0.4  // ~72 degrees down

        // Left arm rotations
        let leftUpperArmRotation = simd_quatf(angle: armAngle, axis: SIMD3<Float>(0, 0, 1))
        let leftLowerArmRotation = simd_quatf(angle: 0.15, axis: SIMD3<Float>(0, 1, 0))

        // Right arm rotations
        let rightUpperArmRotation = simd_quatf(angle: -armAngle, axis: SIMD3<Float>(0, 0, 1))
        let rightLowerArmRotation = simd_quatf(angle: -0.15, axis: SIMD3<Float>(0, 1, 0))

        clip.addRotationTrack(boneName: "leftUpperArm", times: [0], rotations: [leftUpperArmRotation])
        clip.addRotationTrack(boneName: "leftLowerArm", times: [0], rotations: [leftLowerArmRotation])
        clip.addRotationTrack(boneName: "rightUpperArm", times: [0], rotations: [rightUpperArmRotation])
        clip.addRotationTrack(boneName: "rightLowerArm", times: [0], rotations: [rightLowerArmRotation])

        return clip
    }

    /// Create a combined idle animation with rest pose and breathing
    static func createIdleAnimation(breathingDuration: Float = 4.0) -> AnimationClip {
        let clip = AnimationClip(name: "idle", duration: breathingDuration)
        clip.isLooping = true

        // Arm rotation (static at rest pose)
        let armAngle: Float = .pi * 0.4
        let leftUpperArmRotation = simd_quatf(angle: armAngle, axis: SIMD3<Float>(0, 0, 1))
        let rightUpperArmRotation = simd_quatf(angle: -armAngle, axis: SIMD3<Float>(0, 0, 1))

        clip.addRotationTrack(boneName: "leftUpperArm", times: [0], rotations: [leftUpperArmRotation])
        clip.addRotationTrack(boneName: "rightUpperArm", times: [0], rotations: [rightUpperArmRotation])

        // Breathing animation on spine/chest
        let frameCount = 60
        var times: [Float] = []
        var spineRotations: [simd_quatf] = []
        var headRotations: [simd_quatf] = []

        for i in 0...frameCount {
            let t = Float(i) / Float(frameCount) * breathingDuration
            times.append(t)

            let phase = Float(i) / Float(frameCount) * Float.pi * 2

            // Breathing - subtle spine rotation
            let breathAngle = sin(phase) * 0.015
            let spineRotation = simd_quatf(angle: breathAngle, axis: SIMD3<Float>(1, 0, 0))
            spineRotations.append(spineRotation)

            // Subtle head movement
            let headNodAngle = sin(phase * 0.5) * 0.01
            let headTiltAngle = sin(phase * 0.3) * 0.008
            let headRotation = simd_quatf(angle: headNodAngle, axis: SIMD3<Float>(1, 0, 0)) *
                               simd_quatf(angle: headTiltAngle, axis: SIMD3<Float>(0, 0, 1))
            headRotations.append(headRotation)
        }

        clip.addRotationTrack(boneName: "spine", times: times, rotations: spineRotations)
        clip.addRotationTrack(boneName: "chest", times: times, rotations: spineRotations)
        clip.addRotationTrack(boneName: "head", times: times, rotations: headRotations)

        return clip
    }
}
