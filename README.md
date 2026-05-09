# VRM1Metal

A Swift Package for loading and rendering [VRM 1.0](https://github.com/vrm-c/vrm-specification) avatars on Apple platforms using Metal directly — no SceneKit, no RealityKit.

- iOS 15+ / macOS 12+
- Pure Metal pipeline (MToon + lit)
- VRM 1.0 extensions: humanoid, expressions, look-at, first-person, spring bones, node constraints, meta
- glTF 2.0 binary (`.glb` / `.vrm`) parser
- FBX animation loader + clip-based animation player
- SwiftUI view (`VRM1View`) on iOS/tvOS

## Installation

Add the package to your project from Xcode (**File → Add Packages…**) using this repository's URL, or in `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/<owner>/VRM1Metal.git", from: "0.1.0")
],
targets: [
    .target(name: "MyApp", dependencies: ["VRM1Metal"])
]
```

## Quick start (SwiftUI, iOS)

```swift
import SwiftUI
import VRM1Metal

struct ContentView: View {
    var body: some View {
        VRM1ViewContainer(url: Bundle.main.url(forResource: "AliciaSolid", withExtension: "vrm")!)
            .ignoresSafeArea()
    }
}
```

`VRM1ViewContainer` handles asynchronous loading and frames the camera on the model's hips automatically.

## Manual loading + custom camera

```swift
import SwiftUI
import VRM1Metal

struct AvatarView: View {
    @State private var model: VRM1Model?
    @State private var expressions: [String: Float] = [:]
    @State private var cameraPosition = SIMD3<Float>(0, 1.4, 0.6)
    @State private var cameraTarget = SIMD3<Float>(0, 1.4, 0)

    let url: URL

    var body: some View {
        Group {
            if let model {
                VRM1View(
                    model: model,
                    expressionWeights: $expressions,
                    cameraPosition: $cameraPosition,
                    cameraTarget: $cameraTarget
                )
            } else {
                ProgressView()
            }
        }
        .task {
            model = try? await VRM1Loader().load(from: url)
        }
    }
}
```

## Driving expressions

```swift
expressions["happy"] = 1.0     // VRM 1.0 expression preset
expressions["aa"] = 0.7        // mouth shape preset
```

The view first looks up the name in the model's `VRMExpressions`. If no preset matches, it falls back to a direct morph-target name lookup across all meshes.

## Custom animation

Build an `AnimationPlayer` yourself (so you can swap clips at runtime) and pass it in:

```swift
let player = AnimationPlayer()

let fbxLoader = FBXAnimationLoader()
let fbxAnim = try fbxLoader.loadAnimation(from: animURL)
let clip = AnimationClip.fromFBX(fbxAnim)
clip.isLooping = true
player.play(clip)

VRM1View(model: model, externalAnimationPlayer: player)
```

If `externalAnimationPlayer` is `nil`, an internal player drives a procedural breathing idle clip.

## Procedural motion hook

Use `proceduralAnimationCallback` to apply per-frame motion (look-at, breathing, sway) on top of clip animation. It runs after the clip has been sampled but before world transforms are recomputed:

```swift
VRM1View(
    model: model,
    proceduralAnimationCallback: { dt, cameraPos in
        // adjust bone localTransforms here
    }
)
```

## What's inside

| Module | Purpose |
|--------|---------|
| `Core/VRM1Loader`, `VRM1Model` | High-level loading + scene graph |
| `GLTF/` | glTF 2.0 binary parser |
| `Rendering/MetalRenderer` | Per-frame Metal pipeline (lit + MToon + outline) |
| `Rendering/Shaders/` | `.metal` source for unlit/lit/MToon |
| `VRMExtensions/VRMC_vrm/` | Humanoid, Expressions, FirstPerson, LookAt, Meta |
| `VRMExtensions/VRMC_springBone/` | Spring bone simulator + colliders |
| `VRMExtensions/VRMC_node_constraint/` | Node constraint extension |
| `Core/AnimationPlayer`, `FBXAnimationLoader` | Clip-based animation + FBX import |
| `Integration/SwiftUI/VRM1View` | `UIViewRepresentable` MTKView host |

## Limitations

- macOS support is at the package/parsing level; the bundled SwiftUI view is iOS/tvOS only.
- Look-at, spring bones, and node constraints are parsed and modeled, but not all are wired into every per-frame update path yet. PRs welcome.
- VRM 0.x files are not supported. Use a converter (e.g. UniVRM) to upgrade to VRM 1.0.

## License

MIT — see [LICENSE](LICENSE).
