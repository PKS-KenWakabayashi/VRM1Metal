import Foundation
import simd

/// VRM 1.0 Spring Bone Joint definition
public struct SpringBoneJoint {

    /// Index of the node this joint is attached to
    public let nodeIndex: Int

    /// Reference to the actual node
    public weak var node: VRM1Node?

    /// How strongly the bone returns to its original orientation
    /// Range: 0.0 - 1.0 (higher = stiffer)
    public var stiffness: Float

    /// Strength of gravity effect
    /// Range: 0.0 - 2.0
    public var gravityPower: Float

    /// Direction of gravity in model space
    public var gravityDir: SIMD3<Float>

    /// Air resistance (damping)
    /// Range: 0.0 - 1.0 (higher = more resistance)
    public var dragForce: Float

    /// Collision radius of this joint
    public var hitRadius: Float

    // MARK: - Initialization

    public init(
        nodeIndex: Int,
        node: VRM1Node? = nil,
        stiffness: Float = 1.0,
        gravityPower: Float = 0.0,
        gravityDir: SIMD3<Float> = SIMD3<Float>(0, -1, 0),
        dragForce: Float = 0.5,
        hitRadius: Float = 0.02
    ) {
        self.nodeIndex = nodeIndex
        self.node = node
        self.stiffness = stiffness
        self.gravityPower = gravityPower
        self.gravityDir = gravityDir
        self.dragForce = dragForce
        self.hitRadius = hitRadius
    }

    // MARK: - Parsing

    static func parse(from dict: [String: Any], nodes: [VRM1Node]) -> SpringBoneJoint? {
        guard let nodeIndex = dict["node"] as? Int,
              nodeIndex < nodes.count else {
            return nil
        }

        let stiffness = (dict["stiffness"] as? Double).map { Float($0) } ?? 1.0
        let gravityPower = (dict["gravityPower"] as? Double).map { Float($0) } ?? 0.0
        let dragForce = (dict["dragForce"] as? Double).map { Float($0) } ?? 0.5
        let hitRadius = (dict["hitRadius"] as? Double).map { Float($0) } ?? 0.02

        var gravityDir = SIMD3<Float>(0, -1, 0)
        if let dirArray = dict["gravityDir"] as? [Double], dirArray.count >= 3 {
            gravityDir = SIMD3<Float>(Float(dirArray[0]), Float(dirArray[1]), Float(dirArray[2]))
        }

        return SpringBoneJoint(
            nodeIndex: nodeIndex,
            node: nodes[nodeIndex],
            stiffness: stiffness,
            gravityPower: gravityPower,
            gravityDir: gravityDir,
            dragForce: dragForce,
            hitRadius: hitRadius
        )
    }
}

/// Spring bone chain (a sequence of connected joints)
public struct SpringBoneChain {
    /// Name of this chain
    public let name: String?

    /// Joints in this chain (ordered from root to tip)
    public var joints: [SpringBoneJoint]

    /// Collider groups that affect this chain
    public var colliderGroupIndices: [Int]

    /// Center node for this chain (optional, for transform space)
    public var center: VRM1Node?

    public init(
        name: String? = nil,
        joints: [SpringBoneJoint] = [],
        colliderGroupIndices: [Int] = [],
        center: VRM1Node? = nil
    ) {
        self.name = name
        self.joints = joints
        self.colliderGroupIndices = colliderGroupIndices
        self.center = center
    }
}
