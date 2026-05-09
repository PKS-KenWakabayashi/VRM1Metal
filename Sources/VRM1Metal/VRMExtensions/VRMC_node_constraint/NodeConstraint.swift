import Foundation
import simd

/// VRM 1.0 Node Constraint types
public enum NodeConstraintType {
    case roll(RollConstraint)
    case aim(AimConstraint)
    case rotation(RotationConstraint)
}

/// Base protocol for all constraints
public protocol ConstraintProtocol {
    /// Source node that drives the constraint
    var sourceNode: VRM1Node? { get }

    /// Weight of the constraint (0-1)
    var weight: Float { get set }

    /// Apply the constraint to the destination node
    func apply(to destinationNode: VRM1Node)
}

// MARK: - Roll Constraint

/// Transfers rotation around a single axis from source to destination
public struct RollConstraint: ConstraintProtocol {
    public weak var sourceNode: VRM1Node?
    public var weight: Float

    /// Roll axis in local space
    public var rollAxis: RollAxis

    public enum RollAxis: String {
        case x = "X"
        case y = "Y"
        case z = "Z"

        var vector: SIMD3<Float> {
            switch self {
            case .x: return SIMD3<Float>(1, 0, 0)
            case .y: return SIMD3<Float>(0, 1, 0)
            case .z: return SIMD3<Float>(0, 0, 1)
            }
        }
    }

    public init(sourceNode: VRM1Node?, rollAxis: RollAxis, weight: Float = 1.0) {
        self.sourceNode = sourceNode
        self.rollAxis = rollAxis
        self.weight = weight
    }

    public func apply(to destinationNode: VRM1Node) {
        guard let source = sourceNode, weight > 0 else { return }

        // Get source rotation
        let sourceRotation = extractRotation(from: source.localTransform)

        // Extract roll angle around the specified axis
        let rollAngle = extractRollAngle(from: sourceRotation, axis: rollAxis.vector)

        // Apply weighted roll to destination
        let weightedAngle = rollAngle * weight
        let rollRotation = simd_quatf(angle: weightedAngle, axis: rollAxis.vector)

        // Get destination's initial rotation and apply roll
        let destInitialRotation = extractRotation(from: destinationNode.gltfNode.localTransform())
        let newRotation = rollRotation * destInitialRotation

        destinationNode.setRotation(newRotation)
    }

    private func extractRollAngle(from rotation: simd_quatf, axis: SIMD3<Float>) -> Float {
        // Project the rotation onto the axis to get the roll angle
        let rotatedAxis = rotation.act(axis)
        let projectedRotation = simd_quatf(from: axis, to: rotatedAxis)

        // Extract angle (this is a simplification)
        return 2.0 * atan2(length(projectedRotation.imag), projectedRotation.real)
    }
}

// MARK: - Aim Constraint

/// Rotates destination to aim at source position
public struct AimConstraint: ConstraintProtocol {
    public weak var sourceNode: VRM1Node?
    public var weight: Float

    /// Axis of the destination that should point at source
    public var aimAxis: AimAxis

    public enum AimAxis: String {
        case positiveX = "PositiveX"
        case negativeX = "NegativeX"
        case positiveY = "PositiveY"
        case negativeY = "NegativeY"
        case positiveZ = "PositiveZ"
        case negativeZ = "NegativeZ"

        var vector: SIMD3<Float> {
            switch self {
            case .positiveX: return SIMD3<Float>(1, 0, 0)
            case .negativeX: return SIMD3<Float>(-1, 0, 0)
            case .positiveY: return SIMD3<Float>(0, 1, 0)
            case .negativeY: return SIMD3<Float>(0, -1, 0)
            case .positiveZ: return SIMD3<Float>(0, 0, 1)
            case .negativeZ: return SIMD3<Float>(0, 0, -1)
            }
        }
    }

    public init(sourceNode: VRM1Node?, aimAxis: AimAxis, weight: Float = 1.0) {
        self.sourceNode = sourceNode
        self.aimAxis = aimAxis
        self.weight = weight
    }

    public func apply(to destinationNode: VRM1Node) {
        guard let source = sourceNode, weight > 0 else { return }

        // Get positions in world space
        let destWorldPos = (destinationNode.worldTransform * SIMD4<Float>(0, 0, 0, 1)).xyz
        let sourceWorldPos = (source.worldTransform * SIMD4<Float>(0, 0, 0, 1)).xyz

        // Calculate direction to source
        let directionToSource = sourceWorldPos - destWorldPos
        let distance = length(directionToSource)

        guard distance > 0.0001 else { return }

        let normalizedDirection = directionToSource / distance

        // Convert to destination's parent space
        let parentInverse = destinationNode.parent?.worldTransform.inverse ?? matrix_identity_float4x4
        let localDirection = normalize((parentInverse * SIMD4<Float>(normalizedDirection, 0)).xyz)

        // Calculate rotation to align aim axis with target direction
        let aimVector = aimAxis.vector
        let rotation = simd_quatf(from: aimVector, to: localDirection)

        // Get initial rotation and apply aim with weight
        let initialRotation = extractRotation(from: destinationNode.gltfNode.localTransform())

        // Interpolate rotation based on weight
        let blendedRotation = simd_slerp(initialRotation, rotation * initialRotation, weight)

        destinationNode.setRotation(blendedRotation)
    }
}

// MARK: - Rotation Constraint

/// Directly transfers rotation from source to destination
public struct RotationConstraint: ConstraintProtocol {
    public weak var sourceNode: VRM1Node?
    public var weight: Float

    public init(sourceNode: VRM1Node?, weight: Float = 1.0) {
        self.sourceNode = sourceNode
        self.weight = weight
    }

    public func apply(to destinationNode: VRM1Node) {
        guard let source = sourceNode, weight > 0 else { return }

        // Get source local rotation
        let sourceRotation = extractRotation(from: source.localTransform)

        // Get destination initial rotation
        let destInitialRotation = extractRotation(from: destinationNode.gltfNode.localTransform())

        // Calculate delta rotation (source's rotation relative to its initial)
        let sourceInitialRotation = extractRotation(from: source.gltfNode.localTransform())
        let deltaRotation = sourceRotation * sourceInitialRotation.inverse

        // Apply weighted delta to destination
        let weightedDelta = simd_slerp(simd_quatf(ix: 0, iy: 0, iz: 0, r: 1), deltaRotation, weight)
        let newRotation = weightedDelta * destInitialRotation

        destinationNode.setRotation(newRotation)
    }
}

// MARK: - Node Constraint Container

/// Container for a constraint attached to a destination node
public struct NodeConstraint {
    public let destinationNode: VRM1Node
    public var constraint: NodeConstraintType

    public init(destinationNode: VRM1Node, constraint: NodeConstraintType) {
        self.destinationNode = destinationNode
        self.constraint = constraint
    }

    /// Apply this constraint
    public func apply() {
        switch constraint {
        case .roll(let rollConstraint):
            rollConstraint.apply(to: destinationNode)
        case .aim(let aimConstraint):
            aimConstraint.apply(to: destinationNode)
        case .rotation(let rotationConstraint):
            rotationConstraint.apply(to: destinationNode)
        }
    }
}

// MARK: - Constraint Solver

/// Manages and solves all node constraints in the correct order
public final class ConstraintSolver {

    /// All constraints in solve order
    public var constraints: [NodeConstraint] = []

    public init() {}

    /// Solve all constraints
    public func solve() {
        for constraint in constraints {
            constraint.apply()
        }
    }

    /// Add a constraint
    public func addConstraint(_ constraint: NodeConstraint) {
        constraints.append(constraint)
    }

    /// Remove all constraints
    public func clear() {
        constraints.removeAll()
    }
}

// MARK: - Parsing

public extension ConstraintSolver {

    /// Parse constraints from VRMC_node_constraint extension on nodes
    static func parse(from document: GLTFDocument, nodes: [VRM1Node]) -> ConstraintSolver {
        let solver = ConstraintSolver()

        guard let gltfNodes = document.nodes else { return solver }

        for (nodeIndex, gltfNode) in gltfNodes.enumerated() {
            guard let extensions = gltfNode.extensions,
                  let constraintExt = extensions["VRMC_node_constraint"]?.dictionary,
                  let constraintDict = constraintExt["constraint"] as? [String: Any],
                  nodeIndex < nodes.count else {
                continue
            }

            let destinationNode = nodes[nodeIndex]

            // Parse source node
            guard let sourceIndex = constraintDict["source"] as? Int,
                  sourceIndex < nodes.count else {
                continue
            }
            let sourceNode = nodes[sourceIndex]

            // Parse weight
            let weight = (constraintDict["weight"] as? Double).map { Float($0) } ?? 1.0

            // Determine constraint type
            if let rollDict = constraintDict["roll"] as? [String: Any] {
                let axisStr = rollDict["rollAxis"] as? String ?? "X"
                let axis = RollConstraint.RollAxis(rawValue: axisStr) ?? .x

                let rollConstraint = RollConstraint(sourceNode: sourceNode, rollAxis: axis, weight: weight)
                solver.addConstraint(NodeConstraint(
                    destinationNode: destinationNode,
                    constraint: .roll(rollConstraint)
                ))

            } else if let aimDict = constraintDict["aim"] as? [String: Any] {
                let axisStr = aimDict["aimAxis"] as? String ?? "PositiveZ"
                let axis = AimConstraint.AimAxis(rawValue: axisStr) ?? .positiveZ

                let aimConstraint = AimConstraint(sourceNode: sourceNode, aimAxis: axis, weight: weight)
                solver.addConstraint(NodeConstraint(
                    destinationNode: destinationNode,
                    constraint: .aim(aimConstraint)
                ))

            } else if constraintDict["rotation"] != nil {
                let rotationConstraint = RotationConstraint(sourceNode: sourceNode, weight: weight)
                solver.addConstraint(NodeConstraint(
                    destinationNode: destinationNode,
                    constraint: .rotation(rotationConstraint)
                ))
            }
        }

        return solver
    }
}

// MARK: - Helper Functions

private func extractRotation(from matrix: simd_float4x4) -> simd_quatf {
    let col0 = normalize(SIMD3<Float>(matrix.columns.0.x, matrix.columns.0.y, matrix.columns.0.z))
    let col1 = normalize(SIMD3<Float>(matrix.columns.1.x, matrix.columns.1.y, matrix.columns.1.z))
    let col2 = normalize(SIMD3<Float>(matrix.columns.2.x, matrix.columns.2.y, matrix.columns.2.z))

    let rotationMatrix = simd_float3x3(col0, col1, col2)
    return simd_quatf(rotationMatrix)
}
