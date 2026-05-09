import Foundation
import simd

/// VRM 1.0 Runtime - Coordinates per-frame updates in correct order
/// Update order per VRM spec: LookAt -> Expressions -> Constraints -> SpringBone
public final class VRMRuntime {

    // MARK: - Properties

    /// The VRM model being animated
    public let model: VRM1Model

    /// LookAt controller
    public let lookAtController: LookAtController

    /// Expression manager
    public let expressionManager: ExpressionManager

    /// Constraint solver
    public let constraintSolver: ConstraintSolver

    /// Spring bone simulator
    public let springBoneSimulator: SpringBoneSimulator

    /// Current look-at target in world space
    public var lookAtTarget: SIMD3<Float>?

    /// Whether the runtime is paused
    public var isPaused: Bool = false

    // MARK: - Initialization

    public init(model: VRM1Model) {
        self.model = model

        // Initialize look-at controller
        self.lookAtController = LookAtController(
            model: model,
            lookAtSettings: model.lookAt
        )

        // Initialize expression manager
        self.expressionManager = ExpressionManager(
            model: model,
            expressions: model.expressions
        )

        // Initialize constraint solver
        self.constraintSolver = ConstraintSolver.parse(
            from: model.document,
            nodes: model.allNodes
        )

        // Initialize spring bone simulator
        if let springBoneExt = model.document.extensions?["VRMC_springBone"]?.dictionary {
            self.springBoneSimulator = SpringBoneSimulator.parse(
                from: springBoneExt,
                nodes: model.allNodes
            )
        } else {
            self.springBoneSimulator = SpringBoneSimulator()
        }
    }

    // MARK: - Update

    /// Per-frame update - call this in your render loop
    /// - Parameter deltaTime: Time since last update in seconds
    public func update(deltaTime: Float) {
        guard !isPaused else { return }

        // VRM 1.0 specified update order:

        // 1. LookAt - updates eye bone rotations or expression weights
        lookAtController.update(target: lookAtTarget)

        // 2. Expressions - applies morph targets and material animations
        expressionManager.update()

        // 3. Update node transforms
        model.updateWorldTransforms()

        // 4. Constraints - applies node constraints
        constraintSolver.solve()

        // 5. Update transforms again after constraints
        model.updateWorldTransforms()

        // 6. SpringBone - physics simulation last
        springBoneSimulator.update(deltaTime: deltaTime)

        // 7. Final transform update
        model.updateWorldTransforms()
    }

    /// Reset all runtime systems to initial state
    public func reset() {
        expressionManager.resetAll()
        springBoneSimulator.reset()
    }
}

// MARK: - LookAt Controller

public final class LookAtController {

    private weak var model: VRM1Model?
    private let settings: VRMLookAt?
    private let humanoid: VRMHumanoid?

    public init(model: VRM1Model, lookAtSettings: VRMLookAt?) {
        self.model = model
        self.settings = lookAtSettings
        self.humanoid = model.humanoid
    }

    /// Update look-at based on target
    public func update(target: SIMD3<Float>?) {
        guard let target = target,
              let settings = settings,
              let head = humanoid?.head else {
            return
        }

        // Get head position
        let headPosition = (head.worldTransform * SIMD4<Float>(0, 0, 0, 1)).xyz +
                          settings.offsetFromHeadBone

        // Calculate angles
        let (yaw, pitch) = settings.calculateLookAt(
            target: target,
            headPosition: headPosition
        )

        switch settings.type {
        case .bone:
            // Apply rotation to eye bones
            let rotation = settings.getBoneRotation(yaw: yaw, pitch: pitch)

            humanoid?.leftEye?.setRotation(rotation)
            humanoid?.rightEye?.setRotation(rotation)

        case .expression:
            // Apply look-at expressions
            guard let model = model else { return }

            let weights = settings.getExpressionWeights(yaw: yaw, pitch: pitch)

            for (preset, weight) in weights {
                model.expressions?.get(preset.rawValue)
                // Expression weights would be set through ExpressionManager
            }
        }
    }
}

// MARK: - Expression Manager

public final class ExpressionManager {

    private weak var model: VRM1Model?
    private let expressionDefs: VRMExpressions?

    /// Current expression weights
    private var weights: [String: Float] = [:]

    /// Pending weight changes (applied on update)
    private var pendingWeights: [String: Float] = [:]

    public init(model: VRM1Model, expressions: VRMExpressions?) {
        self.model = model
        self.expressionDefs = expressions
    }

    /// Set the weight of an expression (0.0 - 1.0)
    public func setWeight(_ expressionName: String, weight: Float) {
        pendingWeights[expressionName] = clamp(weight, 0, 1)
    }

    /// Get the current weight of an expression
    public func getWeight(_ expressionName: String) -> Float {
        return weights[expressionName] ?? 0
    }

    /// Set multiple expression weights at once
    public func setWeights(_ newWeights: [String: Float]) {
        for (name, weight) in newWeights {
            pendingWeights[name] = clamp(weight, 0, 1)
        }
    }

    /// Reset all expressions to zero
    public func resetAll() {
        weights.removeAll()
        pendingWeights.removeAll()
    }

    /// Update - applies pending weights to the model
    public func update() {
        // Merge pending weights
        for (name, weight) in pendingWeights {
            weights[name] = weight
        }
        pendingWeights.removeAll()

        // Apply expressions to mesh morph targets
        applyMorphTargets()

        // Apply material animations
        applyMaterialAnimations()
    }

    private func applyMorphTargets() {
        guard let model = model, let expressionDefs = expressionDefs else { return }

        // Reset all morph weights first
        for mesh in model.meshes {
            model.resetMorphWeights(meshIndex: mesh.index)
        }

        // Apply each active expression
        for (expressionName, weight) in weights where weight > 0.001 {
            guard let expression = expressionDefs.get(expressionName) else { continue }

            for bind in expression.morphTargetBinds {
                // Find the mesh that contains this morph target
                for node in model.allNodes {
                    if node.index == bind.node, let mesh = node.mesh {
                        let meshIndex = mesh.index
                        if let currentMesh = model.getMesh(at: meshIndex),
                           bind.index < currentMesh.morphWeights.count {
                            let currentWeight = currentMesh.morphWeights[bind.index]
                            model.setMorphWeight(meshIndex: meshIndex, weightIndex: bind.index, value: currentWeight + bind.weight * weight)
                        }
                    }
                }
            }
        }
    }

    private func applyMaterialAnimations() {
        // Material color and texture transform animations
        // TODO: Implement material animation when MToon material system is integrated
    }

    /// Get all available expression names
    public var availableExpressions: [String] {
        return expressionDefs?.allExpressionNames ?? []
    }
}

// MARK: - Utility

private func clamp<T: Comparable>(_ value: T, _ lower: T, _ upper: T) -> T {
    return min(max(value, lower), upper)
}
