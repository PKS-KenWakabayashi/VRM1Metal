#if os(iOS) || os(tvOS)
import SwiftUI
import MetalKit
import simd

/// SwiftUI wrapper for VRM 1.0 Metal rendering.
public struct VRM1View: UIViewRepresentable {

    // MARK: - Properties

    public let model: VRM1Model

    /// Expression weights keyed by expression name (0...1).
    @Binding public var expressionWeights: [String: Float]

    /// Optional bump value used to force `updateUIView` to fire when expression
    /// dictionary contents change without identity change.
    public var expressionTrigger: Float

    /// Look-at target in world space.
    @Binding public var lookAtTarget: SIMD3<Float>?

    @Binding public var cameraPosition: SIMD3<Float>
    @Binding public var cameraTarget: SIMD3<Float>

    public var clearColor: MTLClearColor
    public var showDebugInfo: Bool

    /// Optional externally owned animation player.
    /// If `nil`, an internal player driven by `AnimationClip.createIdleAnimation()` is used.
    public var externalAnimationPlayer: AnimationPlayer?

    /// Called once after the underlying VRM model has been registered with the renderer.
    public var onModelReady: ((VRM1Model) -> Void)?

    /// Optional per-frame callback invoked after FBX/clip animation has been applied
    /// but before world transforms are recomputed. Use this to layer procedural motion
    /// (breathing, look-at, sway, etc.) on top of baseline animation.
    /// Parameters: `(deltaTime, cameraPosition)`.
    public var proceduralAnimationCallback: ((Float, SIMD3<Float>) -> Void)?

    // MARK: - Initialization

    public init(
        model: VRM1Model,
        expressionWeights: Binding<[String: Float]> = .constant([:]),
        expressionTrigger: Float = 0,
        lookAtTarget: Binding<SIMD3<Float>?> = .constant(nil),
        cameraPosition: Binding<SIMD3<Float>> = .constant(SIMD3<Float>(0, 1.0, 1.0)),
        cameraTarget: Binding<SIMD3<Float>> = .constant(SIMD3<Float>(0, 1.0, 0)),
        clearColor: MTLClearColor = MTLClearColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1.0),
        showDebugInfo: Bool = false,
        externalAnimationPlayer: AnimationPlayer? = nil,
        onModelReady: ((VRM1Model) -> Void)? = nil,
        proceduralAnimationCallback: ((Float, SIMD3<Float>) -> Void)? = nil
    ) {
        self.model = model
        self._expressionWeights = expressionWeights
        self.expressionTrigger = expressionTrigger
        self._lookAtTarget = lookAtTarget
        self._cameraPosition = cameraPosition
        self._cameraTarget = cameraTarget
        self.clearColor = clearColor
        self.showDebugInfo = showDebugInfo
        self.externalAnimationPlayer = externalAnimationPlayer
        self.onModelReady = onModelReady
        self.proceduralAnimationCallback = proceduralAnimationCallback
    }

    // MARK: - UIViewRepresentable

    public func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    public func makeUIView(context: Context) -> MTKView {
        let mtkView = MTKView()

        guard let device = MTLCreateSystemDefaultDevice() else {
            return mtkView
        }

        mtkView.device = device
        mtkView.colorPixelFormat = .bgra8Unorm_srgb
        mtkView.depthStencilPixelFormat = .depth32Float
        mtkView.clearColor = clearColor
        mtkView.delegate = context.coordinator
        mtkView.enableSetNeedsDisplay = false
        mtkView.isPaused = false
        mtkView.preferredFramesPerSecond = 60
        mtkView.sampleCount = 4

        Coordinator.currentMTKView = mtkView

        do {
            let renderer = try MetalRenderer(device: device, sampleCount: 4)
            renderer.setModel(model)
            renderer.cameraPosition = cameraPosition
            renderer.cameraTarget = cameraTarget
            context.coordinator.renderer = renderer
        } catch {
            // Renderer creation failed
        }

        return mtkView
    }

    public func updateUIView(_ uiView: MTKView, context: Context) {
        if uiView.isPaused {
            return
        }

        // Refresh the coordinator's parent reference so it sees the latest bindings.
        context.coordinator.parent = self

        uiView.clearColor = clearColor

        context.coordinator.renderer?.cameraPosition = cameraPosition
        context.coordinator.renderer?.cameraTarget = cameraTarget

        context.coordinator.updateExpressions(expressionWeights)
        context.coordinator.updateLookAt(lookAtTarget)
    }

    public static func dismantleUIView(_ uiView: MTKView, coordinator: Coordinator) {
        coordinator.renderer = nil
    }

    // MARK: - Coordinator

    public class Coordinator: NSObject, MTKViewDelegate {
        var parent: VRM1View
        var renderer: MetalRenderer?
        var animationPlayer: AnimationPlayer?
        var animationInitialized = false
        var lastFrameTime: CFTimeInterval = 0

        private var initialDrawableSize: CGSize = .zero
        private var hasInitialSize: Bool = false

        /// Static reference so external code can pause the active MTKView synchronously
        /// (without going through SwiftUI re-evaluation).
        static weak var currentMTKView: MTKView?

        public static func pauseImmediately() {
            if Thread.isMainThread {
                currentMTKView?.isPaused = true
            } else {
                DispatchQueue.main.async {
                    currentMTKView?.isPaused = true
                }
            }
        }

        public static func resumeImmediately() {
            if Thread.isMainThread {
                currentMTKView?.isPaused = false
            } else {
                DispatchQueue.main.async {
                    currentMTKView?.isPaused = false
                }
            }
        }

        init(_ parent: VRM1View) {
            self.parent = parent
            super.init()
        }

        // MARK: - Setup

        func setupAnimation() {
            guard !animationInitialized else { return }
            animationInitialized = true

            guard parent.model.humanoid != nil else {
                parent.onModelReady?(parent.model)
                return
            }

            let nodeCount = parent.model.allNodes.count

            if let externalPlayer = parent.externalAnimationPlayer {
                externalPlayer.nodeForBone = { [weak self] boneName in
                    self?.parent.model.humanoid?.getBone(named: boneName)
                }
                externalPlayer.prepareBuffers(nodeCount: nodeCount)
                self.animationPlayer = externalPlayer
            } else {
                let player = AnimationPlayer()
                player.nodeForBone = { [weak self] boneName in
                    self?.parent.model.humanoid?.getBone(named: boneName)
                }
                player.prepareBuffers(nodeCount: nodeCount)

                let idleClip = AnimationClip.createIdleAnimation(breathingDuration: 4.0)
                player.play(idleClip)
                self.animationPlayer = player
            }

            parent.onModelReady?(parent.model)
        }

        // MARK: - Expression / look-at updates

        func updateExpressions(_ weights: [String: Float]) {
            for meshIndex in 0..<parent.model.meshes.count {
                parent.model.resetMorphWeights(meshIndex: meshIndex)
            }

            for (expressionName, weight) in weights {
                guard weight > 0.001 else { continue }

                if let expressions = parent.model.expressions,
                   let expression = expressions.get(expressionName) {
                    for bind in expression.morphTargetBinds {
                        let bindIndex = bind.node
                        let morphIndex = bind.index
                        let bindWeight = bind.weight

                        var targetMeshIndex: Int?

                        if bindIndex < parent.model.meshes.count {
                            targetMeshIndex = bindIndex
                        }

                        if targetMeshIndex == nil && bindIndex < parent.model.allNodes.count {
                            let node = parent.model.allNodes[bindIndex]
                            if let mesh = node.mesh {
                                targetMeshIndex = mesh.index
                            }
                        }

                        guard let meshIndex = targetMeshIndex else { continue }

                        let mesh = parent.model.meshes[meshIndex]
                        let finalWeight = weight * bindWeight
                        let currentWeight = mesh.morphWeights.count > morphIndex ? mesh.morphWeights[morphIndex] : 0
                        let newWeight = min(1.0, currentWeight + finalWeight)

                        parent.model.setMorphWeight(meshIndex: meshIndex, weightIndex: morphIndex, value: newWeight)
                    }
                    continue
                }

                // Fallback: morph target name lookup across all meshes.
                for (meshIndex, mesh) in parent.model.meshes.enumerated() {
                    if let targetNames = mesh.morphTargetNames,
                       let morphIndex = targetNames.firstIndex(of: expressionName) {
                        parent.model.setMorphWeight(meshIndex: meshIndex, weightIndex: morphIndex, value: weight)
                    }
                }
            }
        }

        func updateLookAt(_ target: SIMD3<Float>?) {
            // TODO: Wire to VRMLookAt once first-class look-at is hooked into the runtime.
        }

        // MARK: - MTKViewDelegate

        public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            // Save the first observed drawable size so keyboard appearance/dismiss
            // (which only changes height) doesn't trigger a renderer resize that
            // distorts the projection matrix.
            if !hasInitialSize {
                initialDrawableSize = size
                hasInitialSize = true
                renderer?.resize(to: size)
                return
            }

            if abs(size.width - initialDrawableSize.width) < 1.0
                && abs(size.height - initialDrawableSize.height) > 10.0 {
                return
            }

            initialDrawableSize = size
            renderer?.resize(to: size)
        }

        public func draw(in view: MTKView) {
            let currentTime = CACurrentMediaTime()

            if lastFrameTime == 0 {
                lastFrameTime = currentTime
            }

            var deltaTime = Float(currentTime - lastFrameTime)
            lastFrameTime = currentTime

            // Background-resume guard: if the gap is huge (or negative), advance one frame
            // instead of letting the animation jump forward.
            if deltaTime > 0.5 || deltaTime < 0 {
                deltaTime = 1.0 / 60.0
            }
            let clampedDelta = min(deltaTime, 0.1)

            setupAnimation()

            animationPlayer?.update(deltaTime: clampedDelta)

            if let callback = parent.proceduralAnimationCallback {
                let cameraPos = renderer?.cameraPosition ?? SIMD3<Float>(0, 1.4, 0.8)
                callback(clampedDelta, cameraPos)
            }

            renderer?.updateVisibility()

            if renderer?.isVisible ?? true {
                parent.model.updateWorldTransforms()
            }

            renderer?.render(in: view)
        }
    }
}

// MARK: - Convenience initializers

public extension VRM1View {

    /// Camera framed on the face.
    static func portrait(
        model: VRM1Model,
        expressionWeights: Binding<[String: Float]> = .constant([:]),
        expressionTrigger: Float = 0
    ) -> VRM1View {
        VRM1View(
            model: model,
            expressionWeights: expressionWeights,
            expressionTrigger: expressionTrigger,
            cameraPosition: .constant(SIMD3<Float>(0, 1.4, 0.5)),
            cameraTarget: .constant(SIMD3<Float>(0, 1.4, 0))
        )
    }

    /// Camera framed on the full body.
    static func fullBody(
        model: VRM1Model,
        expressionWeights: Binding<[String: Float]> = .constant([:]),
        expressionTrigger: Float = 0
    ) -> VRM1View {
        VRM1View(
            model: model,
            expressionWeights: expressionWeights,
            expressionTrigger: expressionTrigger,
            cameraPosition: .constant(SIMD3<Float>(0, 1.0, 1.0)),
            cameraTarget: .constant(SIMD3<Float>(0, 1.0, 0))
        )
    }
}

// MARK: - VRM1ViewContainer

/// SwiftUI container that handles asynchronous loading of a VRM file from a URL.
public struct VRM1ViewContainer: View {
    @State private var model: VRM1Model?
    @State private var error: Error?
    @State private var isLoading = true

    @State private var expressionWeights: [String: Float] = [:]
    @State private var cameraPosition: SIMD3<Float> = SIMD3<Float>(0, 1.0, 1.0)
    @State private var cameraTarget: SIMD3<Float> = SIMD3<Float>(0, 1.0, 0)

    let url: URL

    public init(url: URL) {
        self.url = url
    }

    public var body: some View {
        ZStack {
            if isLoading {
                ProgressView("Loading VRM...")
            } else if let error = error {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                    Text("Failed to load VRM")
                        .font(.headline)
                    Text(error.localizedDescription)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } else if let model = model {
                VRM1View(
                    model: model,
                    expressionWeights: $expressionWeights,
                    cameraPosition: $cameraPosition,
                    cameraTarget: $cameraTarget
                )
            }
        }
        .task {
            await loadModel()
        }
    }

    @MainActor
    private func loadModel() async {
        isLoading = true

        do {
            let loader = VRM1Loader()
            let loadedModel = try await loader.load(from: url)

            // Position the camera so the model fits the frame regardless of where
            // the rig sits in world space.
            loadedModel.updateWorldTransforms()

            if let hips = loadedModel.humanoid?.hips {
                let hipsWorldPos = hips.worldTransform.columns.3
                let hipsPos = SIMD3<Float>(hipsWorldPos.x, hipsWorldPos.y, hipsWorldPos.z)
                self.cameraTarget = hipsPos
                self.cameraPosition = hipsPos + SIMD3<Float>(0, 0.5, 1.0)
            } else {
                self.cameraTarget = SIMD3<Float>(0, 1.0, 0)
                self.cameraPosition = SIMD3<Float>(0, 1.0, 1.0)
            }

            self.model = loadedModel
        } catch {
            self.error = error
        }

        isLoading = false
    }
}
#endif // os(iOS) || os(tvOS)
