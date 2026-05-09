import Foundation

/// VRM 1.0 first-person view settings
public struct VRMFirstPerson {

    // MARK: - Types

    /// How a mesh should be rendered in first-person view
    public enum MeshAnnotationType: String {
        /// Render in both first-person and third-person
        case auto
        /// Render only in third-person
        case thirdPersonOnly
        /// Render only in first-person
        case firstPersonOnly
        /// Render in both (same as auto, explicit)
        case both
    }

    public struct MeshAnnotation {
        public let node: Int
        public let type: MeshAnnotationType
    }

    // MARK: - Properties

    /// Mesh annotations for first-person rendering
    public let meshAnnotations: [MeshAnnotation]

    // MARK: - Initialization

    init(from dict: [String: Any]) {
        var annotations: [MeshAnnotation] = []

        if let annotationsArray = dict["meshAnnotations"] as? [[String: Any]] {
            for annotationDict in annotationsArray {
                if let node = annotationDict["node"] as? Int {
                    let typeString = annotationDict["type"] as? String ?? "auto"
                    let type = MeshAnnotationType(rawValue: typeString) ?? .auto
                    annotations.append(MeshAnnotation(node: node, type: type))
                }
            }
        }

        self.meshAnnotations = annotations
    }

    // MARK: - Helpers

    /// Get the annotation type for a specific node
    public func getAnnotationType(for nodeIndex: Int) -> MeshAnnotationType {
        return meshAnnotations.first { $0.node == nodeIndex }?.type ?? .auto
    }

    /// Get all nodes that should be visible in first-person view
    public func getFirstPersonVisibleNodes() -> [Int] {
        return meshAnnotations
            .filter { $0.type == .firstPersonOnly || $0.type == .both || $0.type == .auto }
            .map { $0.node }
    }

    /// Get all nodes that should be visible in third-person view
    public func getThirdPersonVisibleNodes() -> [Int] {
        return meshAnnotations
            .filter { $0.type == .thirdPersonOnly || $0.type == .both || $0.type == .auto }
            .map { $0.node }
    }
}
