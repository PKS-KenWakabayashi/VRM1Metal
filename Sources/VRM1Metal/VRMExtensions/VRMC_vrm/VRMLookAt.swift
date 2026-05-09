import Foundation
import simd

/// VRM 1.0 look-at (eye gaze) settings
public struct VRMLookAt {

    // MARK: - Types

    public enum LookAtType: String {
        case bone
        case expression
    }

    public struct RangeMap {
        public let inputMaxValue: Float
        public let outputScale: Float

        init(from dict: [String: Any]?) {
            self.inputMaxValue = (dict?["inputMaxValue"] as? Double).map { Float($0) } ?? 90.0
            self.outputScale = (dict?["outputScale"] as? Double).map { Float($0) } ?? 1.0
        }

        /// Apply the range map to an input value
        public func apply(_ input: Float) -> Float {
            if inputMaxValue <= 0 { return 0 }
            let normalized = min(abs(input), inputMaxValue) / inputMaxValue
            return normalized * outputScale * (input < 0 ? -1 : 1)
        }
    }

    // MARK: - Properties

    /// Type of look-at: bone or expression
    public let type: LookAtType

    /// Offset from head bone to eye position
    public let offsetFromHeadBone: SIMD3<Float>

    /// Range map for horizontal inner rotation (looking toward nose)
    public let rangeMapHorizontalInner: RangeMap

    /// Range map for horizontal outer rotation (looking away from nose)
    public let rangeMapHorizontalOuter: RangeMap

    /// Range map for vertical down rotation
    public let rangeMapVerticalDown: RangeMap

    /// Range map for vertical up rotation
    public let rangeMapVerticalUp: RangeMap

    // MARK: - Initialization

    init(from dict: [String: Any]) {
        self.type = LookAtType(rawValue: dict["type"] as? String ?? "bone") ?? .bone

        if let offset = dict["offsetFromHeadBone"] as? [Double], offset.count >= 3 {
            self.offsetFromHeadBone = SIMD3<Float>(
                Float(offset[0]),
                Float(offset[1]),
                Float(offset[2])
            )
        } else {
            self.offsetFromHeadBone = SIMD3<Float>(0, 0.06, 0) // Default eye height offset
        }

        self.rangeMapHorizontalInner = RangeMap(from: dict["rangeMapHorizontalInner"] as? [String: Any])
        self.rangeMapHorizontalOuter = RangeMap(from: dict["rangeMapHorizontalOuter"] as? [String: Any])
        self.rangeMapVerticalDown = RangeMap(from: dict["rangeMapVerticalDown"] as? [String: Any])
        self.rangeMapVerticalUp = RangeMap(from: dict["rangeMapVerticalUp"] as? [String: Any])
    }

    // MARK: - Look-at Calculation

    /// Calculate eye rotations/expression weights for looking at a target
    /// - Parameters:
    ///   - target: Target position in world space
    ///   - headPosition: Current head bone world position
    ///   - headForward: Current head forward direction
    /// - Returns: Tuple of (yaw, pitch) angles in degrees
    public func calculateLookAt(
        target: SIMD3<Float>,
        headPosition: SIMD3<Float>,
        headForward: SIMD3<Float> = SIMD3<Float>(0, 0, -1)
    ) -> (yaw: Float, pitch: Float) {
        let eyePosition = headPosition + offsetFromHeadBone
        let direction = normalize(target - eyePosition)

        // Calculate yaw (horizontal rotation)
        let flatDirection = normalize(SIMD3<Float>(direction.x, 0, direction.z))
        let yaw = atan2(flatDirection.x, -flatDirection.z) * (180.0 / .pi)

        // Calculate pitch (vertical rotation)
        let pitch = asin(direction.y) * (180.0 / .pi)

        return (yaw, pitch)
    }

    /// Get expression weights for look-at (when type is .expression)
    /// - Parameters:
    ///   - yaw: Horizontal angle in degrees (positive = right)
    ///   - pitch: Vertical angle in degrees (positive = up)
    /// - Returns: Dictionary of expression weights
    public func getExpressionWeights(yaw: Float, pitch: Float) -> [VRMExpressions.PresetExpression: Float] {
        var weights: [VRMExpressions.PresetExpression: Float] = [:]

        // Horizontal
        if yaw > 0 {
            weights[.lookRight] = rangeMapHorizontalOuter.apply(yaw)
        } else {
            weights[.lookLeft] = rangeMapHorizontalOuter.apply(-yaw)
        }

        // Vertical
        if pitch > 0 {
            weights[.lookUp] = rangeMapVerticalUp.apply(pitch)
        } else {
            weights[.lookDown] = rangeMapVerticalDown.apply(-pitch)
        }

        return weights
    }

    /// Get bone rotations for look-at (when type is .bone)
    /// - Parameters:
    ///   - yaw: Horizontal angle in degrees
    ///   - pitch: Vertical angle in degrees
    /// - Returns: Quaternion rotation for eye bones
    public func getBoneRotation(yaw: Float, pitch: Float) -> simd_quatf {
        let yawRad = yaw * (.pi / 180.0)
        let pitchRad = pitch * (.pi / 180.0)

        let yawQuat = simd_quatf(angle: yawRad, axis: SIMD3<Float>(0, 1, 0))
        let pitchQuat = simd_quatf(angle: pitchRad, axis: SIMD3<Float>(1, 0, 0))

        return yawQuat * pitchQuat
    }
}
