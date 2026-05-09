import Foundation

/// VRM 1.0 expression system (facial expressions)
public final class VRMExpressions {

    // MARK: - Expression Definition

    public struct Expression {
        public let name: String
        public let isBinary: Bool
        public let morphTargetBinds: [MorphTargetBind]
        public let materialColorBinds: [MaterialColorBind]
        public let textureTransformBinds: [TextureTransformBind]
        public let overrideBlink: OverrideType
        public let overrideLookAt: OverrideType
        public let overrideMouth: OverrideType

        public struct MorphTargetBind {
            public let node: Int
            public let index: Int
            public let weight: Float
        }

        public struct MaterialColorBind {
            public let material: Int
            public let type: ColorType
            public let targetValue: [Float]

            public enum ColorType: String {
                case color
                case emissionColor
                case shadeColor
                case rimColor
                case outlineColor
                case unknown
            }
        }

        public struct TextureTransformBind {
            public let material: Int
            public let scale: (Float, Float)?
            public let offset: (Float, Float)?
        }

        public enum OverrideType: String {
            case none
            case blend
            case block
        }
    }

    // MARK: - Preset Expression Names

    public enum PresetExpression: String, CaseIterable {
        // Emotion presets
        case happy
        case angry
        case sad
        case relaxed
        case surprised

        // Lip-sync presets (Japanese vowels)
        case aa   // あ
        case ih   // い
        case ou   // う
        case ee   // え
        case oh   // お

        // Blink presets
        case blink
        case blinkLeft
        case blinkRight

        // Look-at presets
        case lookUp
        case lookDown
        case lookLeft
        case lookRight

        // Neutral
        case neutral
    }

    // MARK: - Properties

    private var presetExpressions: [PresetExpression: Expression] = [:]
    private var customExpressions: [String: Expression] = [:]

    // MARK: - Initialization

    init(from dict: [String: Any]) {
        // Parse preset expressions
        if let preset = dict["preset"] as? [String: Any] {
            for presetName in PresetExpression.allCases {
                if let expressionDict = preset[presetName.rawValue] as? [String: Any] {
                    presetExpressions[presetName] = parseExpression(
                        name: presetName.rawValue,
                        from: expressionDict
                    )
                }
            }
        }

        // Parse custom expressions
        if let custom = dict["custom"] as? [String: Any] {
            for (name, value) in custom {
                if let expressionDict = value as? [String: Any] {
                    customExpressions[name] = parseExpression(name: name, from: expressionDict)
                }
            }
        }
    }

    private func parseExpression(name: String, from dict: [String: Any]) -> Expression {
        // Parse morph target binds
        var morphTargetBinds: [Expression.MorphTargetBind] = []
        if let binds = dict["morphTargetBinds"] as? [[String: Any]] {
            for bind in binds {
                if let node = bind["node"] as? Int,
                   let index = bind["index"] as? Int {
                    let weight = (bind["weight"] as? Double).map { Float($0) } ?? 1.0
                    morphTargetBinds.append(Expression.MorphTargetBind(
                        node: node,
                        index: index,
                        weight: weight
                    ))
                }
            }
        }

        // Parse material color binds
        var materialColorBinds: [Expression.MaterialColorBind] = []
        if let binds = dict["materialColorBinds"] as? [[String: Any]] {
            for bind in binds {
                if let material = bind["material"] as? Int,
                   let typeStr = bind["type"] as? String,
                   let targetValue = bind["targetValue"] as? [Double] {
                    let colorType = Expression.MaterialColorBind.ColorType(rawValue: typeStr) ?? .unknown
                    materialColorBinds.append(Expression.MaterialColorBind(
                        material: material,
                        type: colorType,
                        targetValue: targetValue.map { Float($0) }
                    ))
                }
            }
        }

        // Parse texture transform binds
        var textureTransformBinds: [Expression.TextureTransformBind] = []
        if let binds = dict["textureTransformBinds"] as? [[String: Any]] {
            for bind in binds {
                if let material = bind["material"] as? Int {
                    var scale: (Float, Float)?
                    var offset: (Float, Float)?

                    if let scaleArr = bind["scale"] as? [Double], scaleArr.count >= 2 {
                        scale = (Float(scaleArr[0]), Float(scaleArr[1]))
                    }
                    if let offsetArr = bind["offset"] as? [Double], offsetArr.count >= 2 {
                        offset = (Float(offsetArr[0]), Float(offsetArr[1]))
                    }

                    textureTransformBinds.append(Expression.TextureTransformBind(
                        material: material,
                        scale: scale,
                        offset: offset
                    ))
                }
            }
        }

        // Parse override types
        let overrideBlink = Expression.OverrideType(rawValue: dict["overrideBlink"] as? String ?? "none") ?? .none
        let overrideLookAt = Expression.OverrideType(rawValue: dict["overrideLookAt"] as? String ?? "none") ?? .none
        let overrideMouth = Expression.OverrideType(rawValue: dict["overrideMouth"] as? String ?? "none") ?? .none

        return Expression(
            name: name,
            isBinary: dict["isBinary"] as? Bool ?? false,
            morphTargetBinds: morphTargetBinds,
            materialColorBinds: materialColorBinds,
            textureTransformBinds: textureTransformBinds,
            overrideBlink: overrideBlink,
            overrideLookAt: overrideLookAt,
            overrideMouth: overrideMouth
        )
    }

    // MARK: - Accessors

    /// Get a preset expression
    public func getPreset(_ preset: PresetExpression) -> Expression? {
        return presetExpressions[preset]
    }

    /// Get a custom expression by name
    public func getCustom(_ name: String) -> Expression? {
        return customExpressions[name]
    }

    /// Get an expression by name (checks both preset and custom)
    public func get(_ name: String) -> Expression? {
        if let preset = PresetExpression(rawValue: name) {
            return presetExpressions[preset]
        }
        return customExpressions[name]
    }

    /// Get all available expression names
    public var allExpressionNames: [String] {
        var names = presetExpressions.keys.map { $0.rawValue }
        names.append(contentsOf: customExpressions.keys)
        return names
    }

    // MARK: - Auto-mapping from Morph Target Names

    /// Initialize by auto-detecting morph targets from mesh names
    /// This is used when VRM has morph targets but no expression definitions
    init(autoMappingFromMeshes meshes: [VRM1Mesh], document: GLTFDocument) {
        guard let gltfMeshes = document.meshes else { return }

        // Common morph target name patterns mapped to VRM expressions
        // Maps various naming conventions to VRM 1.0 preset expressions
        let morphNameToPreset: [String: PresetExpression] = [
            // Japanese vowel lip-sync (various naming conventions)
            "a": .aa, "あ": .aa, "aa": .aa, "vrc.v_aa": .aa, "mouth_a": .aa, "mth_a": .aa,
            "i": .ih, "い": .ih, "ih": .ih, "vrc.v_ih": .ih, "mouth_i": .ih, "mth_i": .ih,
            "u": .ou, "う": .ou, "ou": .ou, "vrc.v_ou": .ou, "mouth_u": .ou, "mth_u": .ou,
            "e": .ee, "え": .ee, "ee": .ee, "vrc.v_ee": .ee, "mouth_e": .ee, "mth_e": .ee,
            "o": .oh, "お": .oh, "oh": .oh, "vrc.v_oh": .oh, "mouth_o": .oh, "mth_o": .oh,

            // Blink expressions
            "blink": .blink, "まばたき": .blink, "close": .blink,
            "blink_l": .blinkLeft, "blinkleft": .blinkLeft, "wink_l": .blinkLeft,
            "blink_r": .blinkRight, "blinkright": .blinkRight, "wink_r": .blinkRight,

            // Emotion expressions
            "happy": .happy, "joy": .happy, "smile": .happy, "smile1": .happy, "smile2": .happy,
            "笑い": .happy, "にこ": .happy,
            "angry": .angry, "anger": .angry, "ang1": .angry, "ang2": .angry, "怒り": .angry,
            "sad": .sad, "sorrow": .sad, "sap": .sad, "悲しい": .sad, "悲しみ": .sad,
            "relaxed": .relaxed, "fun": .relaxed, "楽": .relaxed,
            "surprised": .surprised, "surprise": .surprised, "conf": .surprised, "驚き": .surprised,

            // Look-at expressions
            "lookup": .lookUp, "look_up": .lookUp,
            "lookdown": .lookDown, "look_down": .lookDown,
            "lookleft": .lookLeft, "look_left": .lookLeft,
            "lookright": .lookRight, "look_right": .lookRight,

            // Neutral
            "neutral": .neutral, "default": .neutral
        ]

        for (meshIndex, gltfMesh) in gltfMeshes.enumerated() {
            // Try to get morph target names from mesh.extras.targetNames
            var targetNames: [String] = []

            if let extras = gltfMesh.extras?.dictionary,
               let names = extras["targetNames"] as? [String] {
                targetNames = names
            }

            // If no targetNames in extras, try primitive extras
            if targetNames.isEmpty, let firstPrimitive = gltfMesh.primitives.first,
               let extras = firstPrimitive.extras?.dictionary,
               let names = extras["targetNames"] as? [String] {
                targetNames = names
            }

            // Process each morph target
            for (morphIndex, name) in targetNames.enumerated() {
                // Normalize the name: handle patterns like "blendShape1.MTH_A" -> extract "a"
                var normalizedName = name.lowercased()
                    .replacingOccurrences(of: " ", with: "_")
                    .replacingOccurrences(of: "-", with: "_")

                // Remove common prefixes like "blendShape1.", "blendShape2.", etc.
                if let dotIndex = normalizedName.lastIndex(of: ".") {
                    normalizedName = String(normalizedName[normalizedName.index(after: dotIndex)...])
                }

                // Extract the last part after underscore for patterns like "mth_a" -> "a"
                var extractedName = normalizedName
                if let lastUnderscoreIndex = normalizedName.lastIndex(of: "_") {
                    let suffix = String(normalizedName[normalizedName.index(after: lastUnderscoreIndex)...])
                    // Only use suffix if it's a single vowel or known expression name
                    let knownSuffixes = [
                        "a", "i", "u", "e", "o",  // vowels
                        "smile1", "smile2", "ang1", "ang2", "sap", "conf",
                        "blink", "angry", "sad", "happy", "surprised"  // common expressions
                    ]
                    if knownSuffixes.contains(suffix) {
                        extractedName = suffix
                    }
                }


                // Check if this name matches any known pattern (try both normalized and extracted)
                let preset = morphNameToPreset[extractedName] ?? morphNameToPreset[normalizedName]
                let newBind = Expression.MorphTargetBind(
                    node: meshIndex,  // Using mesh index for auto-mapped expressions
                    index: morphIndex,
                    weight: 1.0
                )

                if let preset = preset {
                    // 【修正】既存の表情がある場合は、morphTargetBindsに追加する（上書きしない）
                    if let existing = presetExpressions[preset] {
                        // Append new bind to existing expression
                        var updatedBinds = existing.morphTargetBinds
                        updatedBinds.append(newBind)
                        let updatedExpression = Expression(
                            name: existing.name,
                            isBinary: existing.isBinary,
                            morphTargetBinds: updatedBinds,
                            materialColorBinds: existing.materialColorBinds,
                            textureTransformBinds: existing.textureTransformBinds,
                            overrideBlink: existing.overrideBlink,
                            overrideLookAt: existing.overrideLookAt,
                            overrideMouth: existing.overrideMouth
                        )
                        presetExpressions[preset] = updatedExpression
                    } else {
                        // Create new expression
                        let expression = Expression(
                            name: preset.rawValue,
                            isBinary: preset == .blink || preset == .blinkLeft || preset == .blinkRight,
                            morphTargetBinds: [newBind],
                            materialColorBinds: [],
                            textureTransformBinds: [],
                            overrideBlink: preset == .happy || preset == .angry || preset == .sad ? .blend : .none,
                            overrideLookAt: .none,
                            overrideMouth: .none
                        )
                        presetExpressions[preset] = expression
                    }
                } else {
                    // 【修正】カスタム表情も同様に追加する
                    if let existing = customExpressions[name] {
                        var updatedBinds = existing.morphTargetBinds
                        updatedBinds.append(newBind)
                        let updatedExpression = Expression(
                            name: existing.name,
                            isBinary: existing.isBinary,
                            morphTargetBinds: updatedBinds,
                            materialColorBinds: existing.materialColorBinds,
                            textureTransformBinds: existing.textureTransformBinds,
                            overrideBlink: existing.overrideBlink,
                            overrideLookAt: existing.overrideLookAt,
                            overrideMouth: existing.overrideMouth
                        )
                        customExpressions[name] = updatedExpression
                    } else {
                        let expression = Expression(
                            name: name,
                            isBinary: false,
                            morphTargetBinds: [newBind],
                            materialColorBinds: [],
                            textureTransformBinds: [],
                            overrideBlink: .none,
                            overrideLookAt: .none,
                            overrideMouth: .none
                        )
                        customExpressions[name] = expression
                    }
                }
            }
        }
    }

    // MARK: - VRM 0.x Compatibility

    /// Initialize from VRM 0.x blendShapeGroups
    /// VRM 0.x structure:
    /// - blendShapeGroup.name: expression name (e.g., "A", "I", "U", "E", "O")
    /// - blendShapeGroup.presetName: preset identifier (e.g., "a", "i", "u", "e", "o")
    /// - blendShapeGroup.binds[].mesh: mesh index (NOT node index)
    /// - blendShapeGroup.binds[].index: morph target index
    /// - blendShapeGroup.binds[].weight: weight (0-100 in VRM 0.x)
    init(fromVRM0BlendShapeGroups blendShapeGroups: [[String: Any]], meshes: [VRM1Mesh]) {
        // Build mesh-to-node mapping (VRM 0.x uses mesh index, we need node index)
        // For simplicity, we'll assume mesh index equals the first node that references it
        // This is a common pattern in VRM models

        for group in blendShapeGroups {
            let groupName = group["name"] as? String ?? ""
            let presetName = (group["presetName"] as? String)?.lowercased() ?? groupName.lowercased()

            var morphTargetBinds: [Expression.MorphTargetBind] = []

            if let binds = group["binds"] as? [[String: Any]] {
                for bind in binds {
                    // VRM 0.x uses mesh index, not node index
                    guard let meshIndex = bind["mesh"] as? Int,
                          let morphIndex = bind["index"] as? Int else {
                        continue
                    }

                    // VRM 0.x weight is 0-100, convert to 0-1
                    let weightRaw = bind["weight"] as? Double ?? 100.0
                    let weight = Float(weightRaw / 100.0)

                    // For VRM 0.x, we need to find the node that owns this mesh
                    // Since we don't have direct access to nodes here, we'll use meshIndex as a proxy
                    // The actual node lookup will happen in updateExpressions where we have access to allNodes
                    // For now, store meshIndex in the node field (will be converted later)
                    morphTargetBinds.append(Expression.MorphTargetBind(
                        node: meshIndex,  // Note: This is meshIndex, not nodeIndex for VRM 0.x
                        index: morphIndex,
                        weight: weight
                    ))
                }
            }

            let expression = Expression(
                name: groupName,
                isBinary: group["isBinary"] as? Bool ?? false,
                morphTargetBinds: morphTargetBinds,
                materialColorBinds: [],
                textureTransformBinds: [],
                overrideBlink: .none,
                overrideLookAt: .none,
                overrideMouth: .none
            )

            // Map VRM 0.x preset names to VRM 1.0 presets
            let vrm0ToVrm1PresetMap: [String: PresetExpression] = [
                "a": .aa, "i": .ih, "u": .ou, "e": .ee, "o": .oh,
                "blink": .blink, "blink_l": .blinkLeft, "blink_r": .blinkRight,
                "joy": .happy, "angry": .angry, "sorrow": .sad, "fun": .relaxed,
                "lookup": .lookUp, "lookdown": .lookDown, "lookleft": .lookLeft, "lookright": .lookRight,
                "neutral": .neutral
            ]

            if let preset = vrm0ToVrm1PresetMap[presetName] {
                presetExpressions[preset] = expression
            } else {
                // Store as custom expression
                customExpressions[groupName] = expression
            }
        }
    }
}
