import Foundation
import simd

/// VRM 1.0 Spring Bone Physics Simulator using Verlet Integration
public final class SpringBoneSimulator {

    // MARK: - Joint State

    /// Runtime state for each joint
    public struct JointState {
        /// Current tail position in world space
        var currentTailPosition: SIMD3<Float>

        /// Previous tail position (for Verlet integration)
        var previousTailPosition: SIMD3<Float>

        /// Initial local rotation of the bone
        var initialLocalRotation: simd_quatf

        /// Bone axis in local space (direction from joint to child)
        var boneAxis: SIMD3<Float>

        /// Length of the bone
        var boneLength: Float

        /// World-space transform of the center (if any)
        var centerWorldMatrix: simd_float4x4
    }

    // MARK: - Properties

    /// Spring bone chains
    public var chains: [SpringBoneChain]

    /// Collider groups
    public var colliderGroups: [SpringBoneColliderGroup]

    /// Joint states for each chain
    private var chainStates: [[JointState]]

    /// Global gravity (default: Earth gravity scaled for VRM)
    public var gravity: SIMD3<Float> = SIMD3<Float>(0, -10.0, 0)

    /// External force (wind, etc.)
    public var externalForce: SIMD3<Float> = SIMD3<Float>(0, 0, 0)

    // MARK: - Initialization

    public init(chains: [SpringBoneChain] = [], colliderGroups: [SpringBoneColliderGroup] = []) {
        self.chains = chains
        self.colliderGroups = colliderGroups
        self.chainStates = []

        initializeStates()
    }

    /// Initialize joint states from current bone transforms
    public func initializeStates() {
        chainStates = []

        for chain in chains {
            var states: [JointState] = []

            for (jointIndex, joint) in chain.joints.enumerated() {
                guard let node = joint.node else { continue }

                // Get the next joint or create a virtual tail
                let nextNode: VRM1Node?
                if jointIndex + 1 < chain.joints.count {
                    nextNode = chain.joints[jointIndex + 1].node
                } else {
                    nextNode = node.children.first
                }

                // Calculate bone axis and length
                var boneAxis = SIMD3<Float>(0, 0, -1) // Default forward
                var boneLength: Float = 0.1 // Default length

                if let next = nextNode {
                    // Extract translation from local transform difference
                    let nextLocalPos = next.gltfNode.translation ?? [0, 0, 0]
                    boneAxis = normalize(SIMD3<Float>(nextLocalPos[0], nextLocalPos[1], nextLocalPos[2]))
                    boneLength = length(SIMD3<Float>(nextLocalPos[0], nextLocalPos[1], nextLocalPos[2]))

                    if boneLength < 0.001 {
                        boneLength = 0.1
                        boneAxis = SIMD3<Float>(0, 0, -1)
                    }
                }

                // Calculate initial tail position in world space
                let worldTailPosition = (node.worldTransform * SIMD4<Float>(boneAxis * boneLength, 1)).xyz

                // Get center transform
                let centerMatrix = chain.center?.worldTransform ?? matrix_identity_float4x4

                // Extract initial rotation
                let initialRotation = extractRotation(from: node.localTransform)

                let state = JointState(
                    currentTailPosition: worldTailPosition,
                    previousTailPosition: worldTailPosition,
                    initialLocalRotation: initialRotation,
                    boneAxis: boneAxis,
                    boneLength: boneLength,
                    centerWorldMatrix: centerMatrix
                )

                states.append(state)
            }

            chainStates.append(states)
        }
    }

    // MARK: - Simulation Update

    /// Update spring bone simulation
    /// - Parameter deltaTime: Time since last update in seconds
    public func update(deltaTime: Float) {
        // Clamp delta time to avoid instability
        let dt = min(deltaTime, 1.0 / 30.0)

        for (chainIndex, chain) in chains.enumerated() {
            guard chainIndex < chainStates.count else { continue }

            for (jointIndex, joint) in chain.joints.enumerated() {
                guard jointIndex < chainStates[chainIndex].count,
                      let node = joint.node else { continue }

                var state = chainStates[chainIndex][jointIndex]

                // Get parent world matrix
                let parentWorldMatrix = node.parent?.worldTransform ?? matrix_identity_float4x4

                // Calculate current head position (joint position in world space)
                let headPosition = (node.worldTransform * SIMD4<Float>(0, 0, 0, 1)).xyz

                // Calculate rest position (where tail would be without physics)
                let restTailLocal = state.boneAxis * state.boneLength
                let restTailWorld = (node.worldTransform * SIMD4<Float>(restTailLocal, 1)).xyz

                // Verlet integration
                let velocity = state.currentTailPosition - state.previousTailPosition
                state.previousTailPosition = state.currentTailPosition

                // Apply forces
                var newPosition = state.currentTailPosition

                // Velocity (with drag)
                let drag = 1.0 - joint.dragForce
                newPosition += velocity * drag

                // Stiffness (spring force toward rest position)
                let stiffnessForce = (restTailWorld - state.currentTailPosition) * joint.stiffness * dt
                newPosition += stiffnessForce

                // Gravity
                let gravityForce = normalize(joint.gravityDir) * joint.gravityPower * dt * dt
                newPosition += gravityForce

                // External force
                newPosition += externalForce * dt * dt

                // Constraint: maintain bone length
                let toTail = newPosition - headPosition
                let currentLength = length(toTail)
                if currentLength > 0.0001 {
                    newPosition = headPosition + (toTail / currentLength) * state.boneLength
                }

                // Collision detection
                let colliderGroupIndices = chain.colliderGroupIndices
                for groupIndex in colliderGroupIndices {
                    guard groupIndex < colliderGroups.count else { continue }
                    let group = colliderGroups[groupIndex]

                    for collider in group.colliders {
                        if let pushOut = collider.collide(point: newPosition, radius: joint.hitRadius) {
                            newPosition += pushOut

                            // Re-constrain bone length after collision
                            let toTailAfter = newPosition - headPosition
                            let lengthAfter = length(toTailAfter)
                            if lengthAfter > 0.0001 {
                                newPosition = headPosition + (toTailAfter / lengthAfter) * state.boneLength
                            }
                        }
                    }
                }

                state.currentTailPosition = newPosition

                // Update bone rotation to point at new tail position
                updateBoneRotation(node: node, state: state, parentWorldMatrix: parentWorldMatrix)

                chainStates[chainIndex][jointIndex] = state
            }
        }
    }

    // MARK: - Rotation Update

    private func updateBoneRotation(node: VRM1Node, state: JointState, parentWorldMatrix: simd_float4x4) {
        // Calculate the direction the bone should point in parent space
        let headWorld = (node.worldTransform * SIMD4<Float>(0, 0, 0, 1)).xyz
        let tailWorld = state.currentTailPosition

        let worldDirection = normalize(tailWorld - headWorld)

        // Convert to parent local space
        let parentInverse = parentWorldMatrix.inverse
        let localDirection = (parentInverse * SIMD4<Float>(worldDirection, 0)).xyz

        // Calculate rotation to align bone axis with new direction
        let originalAxis = state.boneAxis
        let rotationAxis = cross(originalAxis, localDirection)
        let rotationAxisLength = length(rotationAxis)

        if rotationAxisLength > 0.0001 {
            let normalizedAxis = rotationAxis / rotationAxisLength
            let dotProduct = dot(originalAxis, localDirection)
            let clampedDot = min(max(dotProduct, Float(-1)), Float(1))
            let angle = acos(clampedDot)

            let deltaRotation = simd_quatf(angle: angle, axis: normalizedAxis)
            let newRotation = deltaRotation * state.initialLocalRotation

            node.setRotation(newRotation)
        }
    }

    // MARK: - Helpers

    private func extractRotation(from matrix: simd_float4x4) -> simd_quatf {
        // Extract rotation from a 4x4 matrix (assumes no skew)
        let col0 = normalize(SIMD3<Float>(matrix.columns.0.x, matrix.columns.0.y, matrix.columns.0.z))
        let col1 = normalize(SIMD3<Float>(matrix.columns.1.x, matrix.columns.1.y, matrix.columns.1.z))
        let col2 = normalize(SIMD3<Float>(matrix.columns.2.x, matrix.columns.2.y, matrix.columns.2.z))

        let rotationMatrix = simd_float3x3(col0, col1, col2)
        return simd_quatf(rotationMatrix)
    }

    /// Reset all joint states to their initial positions
    public func reset() {
        initializeStates()
    }
}

// MARK: - Parsing from VRMC_springBone extension

public extension SpringBoneSimulator {

    /// Create a SpringBoneSimulator from VRMC_springBone extension data
    static func parse(from extensionDict: [String: Any], nodes: [VRM1Node]) -> SpringBoneSimulator {
        var colliderGroups: [SpringBoneColliderGroup] = []
        var chains: [SpringBoneChain] = []

        // Parse colliders
        if let collidersArray = extensionDict["colliders"] as? [[String: Any]] {
            var colliders: [SpringBoneCollider] = []
            for colliderDict in collidersArray {
                if let collider = SpringBoneCollider.parse(from: colliderDict, nodes: nodes) {
                    colliders.append(collider)
                }
            }

            // Parse collider groups
            if let groupsArray = extensionDict["colliderGroups"] as? [[String: Any]] {
                for groupDict in groupsArray {
                    let name = groupDict["name"] as? String
                    let colliderIndices = groupDict["colliders"] as? [Int] ?? []

                    let groupColliders = colliderIndices.compactMap { index -> SpringBoneCollider? in
                        guard index < colliders.count else { return nil }
                        return colliders[index]
                    }

                    colliderGroups.append(SpringBoneColliderGroup(name: name, colliders: groupColliders))
                }
            }
        }

        // Parse springs (chains)
        if let springsArray = extensionDict["springs"] as? [[String: Any]] {
            for springDict in springsArray {
                let name = springDict["name"] as? String
                let colliderGroupIndices = springDict["colliderGroups"] as? [Int] ?? []

                var center: VRM1Node?
                if let centerIndex = springDict["center"] as? Int, centerIndex < nodes.count {
                    center = nodes[centerIndex]
                }

                var joints: [SpringBoneJoint] = []
                if let jointsArray = springDict["joints"] as? [[String: Any]] {
                    for jointDict in jointsArray {
                        if let joint = SpringBoneJoint.parse(from: jointDict, nodes: nodes) {
                            joints.append(joint)
                        }
                    }
                }

                chains.append(SpringBoneChain(
                    name: name,
                    joints: joints,
                    colliderGroupIndices: colliderGroupIndices,
                    center: center
                ))
            }
        }

        return SpringBoneSimulator(chains: chains, colliderGroups: colliderGroups)
    }
}
