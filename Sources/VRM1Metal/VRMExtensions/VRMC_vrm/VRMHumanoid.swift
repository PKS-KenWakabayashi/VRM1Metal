import Foundation

/// VRM 1.0 humanoid bone mapping
public final class VRMHumanoid {

    // MARK: - Bone Definitions

    /// All humanoid bone types defined in VRM 1.0
    public enum HumanBone: String, CaseIterable {
        // Torso (Required)
        case hips
        case spine

        // Torso (Optional)
        case chest
        case upperChest

        // Head (Required)
        case head

        // Head (Optional)
        case neck
        case jaw

        // Eyes (Optional)
        case leftEye
        case rightEye

        // Arms (Required)
        case leftUpperArm
        case leftLowerArm
        case leftHand
        case rightUpperArm
        case rightLowerArm
        case rightHand

        // Arms (Optional)
        case leftShoulder
        case rightShoulder

        // Legs (Required)
        case leftUpperLeg
        case leftLowerLeg
        case leftFoot
        case rightUpperLeg
        case rightLowerLeg
        case rightFoot

        // Legs (Optional)
        case leftToes
        case rightToes

        // Fingers (Optional)
        case leftThumbMetacarpal
        case leftThumbProximal
        case leftThumbDistal
        case leftIndexProximal
        case leftIndexIntermediate
        case leftIndexDistal
        case leftMiddleProximal
        case leftMiddleIntermediate
        case leftMiddleDistal
        case leftRingProximal
        case leftRingIntermediate
        case leftRingDistal
        case leftLittleProximal
        case leftLittleIntermediate
        case leftLittleDistal

        case rightThumbMetacarpal
        case rightThumbProximal
        case rightThumbDistal
        case rightIndexProximal
        case rightIndexIntermediate
        case rightIndexDistal
        case rightMiddleProximal
        case rightMiddleIntermediate
        case rightMiddleDistal
        case rightRingProximal
        case rightRingIntermediate
        case rightRingDistal
        case rightLittleProximal
        case rightLittleIntermediate
        case rightLittleDistal

        /// Whether this bone is required
        public var isRequired: Bool {
            switch self {
            case .hips, .spine, .head,
                 .leftUpperArm, .leftLowerArm, .leftHand,
                 .rightUpperArm, .rightLowerArm, .rightHand,
                 .leftUpperLeg, .leftLowerLeg, .leftFoot,
                 .rightUpperLeg, .rightLowerLeg, .rightFoot:
                return true
            default:
                return false
            }
        }
    }

    // MARK: - Properties

    /// Mapping from bone type to scene node
    private var boneNodeMap: [HumanBone: VRM1Node] = [:]

    /// All nodes referenced by this humanoid
    public let allNodes: [VRM1Node]

    // MARK: - Initialization

    init(from dict: [String: Any], nodes: [VRM1Node]) {
        self.allNodes = nodes

        guard let humanBones = dict["humanBones"] as? [String: Any] else {
            return
        }

        for bone in HumanBone.allCases {
            if let boneDict = humanBones[bone.rawValue] as? [String: Any],
               let nodeIndex = boneDict["node"] as? Int,
               nodeIndex < nodes.count {
                boneNodeMap[bone] = nodes[nodeIndex]
            }
        }
    }

    // MARK: - Accessors

    /// Get the node for a specific bone
    public func getBone(_ bone: HumanBone) -> VRM1Node? {
        return boneNodeMap[bone]
    }

    /// Get the node for a bone by string name
    public func getBone(named name: String) -> VRM1Node? {
        guard let bone = HumanBone(rawValue: name) else { return nil }
        return boneNodeMap[bone]
    }

    /// Set the node for a specific bone
    public func setBone(_ bone: HumanBone, node: VRM1Node?) {
        boneNodeMap[bone] = node
    }

    /// Check if all required bones are present
    public var hasAllRequiredBones: Bool {
        for bone in HumanBone.allCases where bone.isRequired {
            if boneNodeMap[bone] == nil {
                return false
            }
        }
        return true
    }

    /// Get all assigned bones
    public var assignedBones: [HumanBone: VRM1Node] {
        return boneNodeMap
    }

    // MARK: - Convenience Accessors

    public var hips: VRM1Node? { getBone(.hips) }
    public var spine: VRM1Node? { getBone(.spine) }
    public var chest: VRM1Node? { getBone(.chest) }
    public var upperChest: VRM1Node? { getBone(.upperChest) }
    public var neck: VRM1Node? { getBone(.neck) }
    public var head: VRM1Node? { getBone(.head) }

    public var leftShoulder: VRM1Node? { getBone(.leftShoulder) }
    public var leftUpperArm: VRM1Node? { getBone(.leftUpperArm) }
    public var leftLowerArm: VRM1Node? { getBone(.leftLowerArm) }
    public var leftHand: VRM1Node? { getBone(.leftHand) }

    public var rightShoulder: VRM1Node? { getBone(.rightShoulder) }
    public var rightUpperArm: VRM1Node? { getBone(.rightUpperArm) }
    public var rightLowerArm: VRM1Node? { getBone(.rightLowerArm) }
    public var rightHand: VRM1Node? { getBone(.rightHand) }

    public var leftUpperLeg: VRM1Node? { getBone(.leftUpperLeg) }
    public var leftLowerLeg: VRM1Node? { getBone(.leftLowerLeg) }
    public var leftFoot: VRM1Node? { getBone(.leftFoot) }
    public var leftToes: VRM1Node? { getBone(.leftToes) }

    public var rightUpperLeg: VRM1Node? { getBone(.rightUpperLeg) }
    public var rightLowerLeg: VRM1Node? { getBone(.rightLowerLeg) }
    public var rightFoot: VRM1Node? { getBone(.rightFoot) }
    public var rightToes: VRM1Node? { getBone(.rightToes) }

    public var leftEye: VRM1Node? { getBone(.leftEye) }
    public var rightEye: VRM1Node? { getBone(.rightEye) }
    public var jaw: VRM1Node? { getBone(.jaw) }
}
