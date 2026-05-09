import Foundation
import simd

/// VRM 1.0 Spring Bone Collider shapes
public enum ColliderShape {
    /// Sphere collider
    case sphere(center: SIMD3<Float>, radius: Float)

    /// Capsule collider
    case capsule(head: SIMD3<Float>, tail: SIMD3<Float>, radius: Float)
}

/// VRM 1.0 Spring Bone Collider
public struct SpringBoneCollider {

    /// Index of the node this collider is attached to
    public let nodeIndex: Int

    /// Reference to the actual node
    public weak var node: VRM1Node?

    /// Shape of the collider
    public var shape: ColliderShape

    // MARK: - Initialization

    public init(nodeIndex: Int, node: VRM1Node? = nil, shape: ColliderShape) {
        self.nodeIndex = nodeIndex
        self.node = node
        self.shape = shape
    }

    // MARK: - Collision Detection

    /// Test collision with a point and return the push-out vector if colliding
    /// - Parameters:
    ///   - point: Point to test in world space
    ///   - radius: Radius of the point (e.g., joint hit radius)
    /// - Returns: Push-out vector if colliding, nil otherwise
    public func collide(point: SIMD3<Float>, radius: Float) -> SIMD3<Float>? {
        guard let node = node else { return nil }

        switch shape {
        case .sphere(let center, let sphereRadius):
            // Transform center to world space
            let worldCenter = (node.worldTransform * SIMD4<Float>(center, 1)).xyz

            let diff = point - worldCenter
            let distance = length(diff)
            let minDist = sphereRadius + radius

            if distance < minDist && distance > 0.0001 {
                // Push out along the difference vector
                let pushDir = diff / distance
                return pushDir * (minDist - distance)
            }

        case .capsule(let head, let tail, let capsuleRadius):
            // Transform head and tail to world space
            let worldHead = (node.worldTransform * SIMD4<Float>(head, 1)).xyz
            let worldTail = (node.worldTransform * SIMD4<Float>(tail, 1)).xyz

            // Find closest point on capsule axis
            let axis = worldTail - worldHead
            let axisLengthSq = dot(axis, axis)

            var closestPoint: SIMD3<Float>
            if axisLengthSq < 0.0001 {
                // Degenerate capsule (sphere)
                closestPoint = worldHead
            } else {
                let tValue = dot(point - worldHead, axis) / axisLengthSq
                let t = min(max(tValue, Float(0)), Float(1))
                closestPoint = worldHead + axis * t
            }

            let diff = point - closestPoint
            let distance = length(diff)
            let minDist = capsuleRadius + radius

            if distance < minDist && distance > 0.0001 {
                let pushDir = diff / distance
                return pushDir * (minDist - distance)
            }
        }

        return nil
    }

    // MARK: - Parsing

    static func parse(from dict: [String: Any], nodes: [VRM1Node]) -> SpringBoneCollider? {
        guard let nodeIndex = dict["node"] as? Int,
              nodeIndex < nodes.count,
              let shapeDict = dict["shape"] as? [String: Any] else {
            return nil
        }

        let shape: ColliderShape

        if let sphereDict = shapeDict["sphere"] as? [String: Any] {
            // Sphere collider
            var center = SIMD3<Float>(0, 0, 0)
            if let offsetArray = sphereDict["offset"] as? [Double], offsetArray.count >= 3 {
                center = SIMD3<Float>(Float(offsetArray[0]), Float(offsetArray[1]), Float(offsetArray[2]))
            }
            let radius = (sphereDict["radius"] as? Double).map { Float($0) } ?? 0.1

            shape = .sphere(center: center, radius: radius)

        } else if let capsuleDict = shapeDict["capsule"] as? [String: Any] {
            // Capsule collider
            var head = SIMD3<Float>(0, 0, 0)
            var tail = SIMD3<Float>(0, 0, 0)

            if let offsetArray = capsuleDict["offset"] as? [Double], offsetArray.count >= 3 {
                head = SIMD3<Float>(Float(offsetArray[0]), Float(offsetArray[1]), Float(offsetArray[2]))
            }
            if let tailArray = capsuleDict["tail"] as? [Double], tailArray.count >= 3 {
                tail = SIMD3<Float>(Float(tailArray[0]), Float(tailArray[1]), Float(tailArray[2]))
            }
            let radius = (capsuleDict["radius"] as? Double).map { Float($0) } ?? 0.1

            shape = .capsule(head: head, tail: tail, radius: radius)

        } else {
            return nil
        }

        return SpringBoneCollider(
            nodeIndex: nodeIndex,
            node: nodes[nodeIndex],
            shape: shape
        )
    }
}

/// Group of colliders
public struct SpringBoneColliderGroup {
    public let name: String?
    public var colliders: [SpringBoneCollider]

    public init(name: String? = nil, colliders: [SpringBoneCollider] = []) {
        self.name = name
        self.colliders = colliders
    }
}

// MARK: - SIMD4 Extension

extension SIMD4 where Scalar == Float {
    var xyz: SIMD3<Float> {
        SIMD3<Float>(x, y, z)
    }
}
