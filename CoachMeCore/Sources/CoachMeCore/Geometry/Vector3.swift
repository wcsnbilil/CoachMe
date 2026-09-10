import Foundation

/// A minimal 3-component vector. Kept dependency-free (no simd) so this module
/// builds on any Swift platform and stays unit-testable off-device.
public struct Vector3: Equatable, Sendable, Codable {
    public var x: Double
    public var y: Double
    public var z: Double

    public init(_ x: Double, _ y: Double, _ z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }

    public static let zero = Vector3(0, 0, 0)

    public static func - (a: Vector3, b: Vector3) -> Vector3 { Vector3(a.x - b.x, a.y - b.y, a.z - b.z) }
    public static func + (a: Vector3, b: Vector3) -> Vector3 { Vector3(a.x + b.x, a.y + b.y, a.z + b.z) }
    public static func * (v: Vector3, s: Double) -> Vector3 { Vector3(v.x * s, v.y * s, v.z * s) }
    public static func / (v: Vector3, s: Double) -> Vector3 { Vector3(v.x / s, v.y / s, v.z / s) }

    public func dot(_ o: Vector3) -> Double { x * o.x + y * o.y + z * o.z }

    public func cross(_ o: Vector3) -> Vector3 {
        Vector3(y * o.z - z * o.y,
                z * o.x - x * o.z,
                x * o.y - y * o.x)
    }

    public var length: Double { (x * x + y * y + z * z).squareRoot() }

    /// Returns nil for a zero-length (degenerate) vector rather than producing NaN.
    public func normalized() -> Vector3? {
        let l = length
        guard l > Self.degenerateLengthThreshold else { return nil }
        return self / l
    }

    /// Midpoint helper, used for the shoulder-centre and hip-centre reference points.
    public static func midpoint(_ a: Vector3, _ b: Vector3) -> Vector3 {
        Vector3((a.x + b.x) / 2, (a.y + b.y) / 2, (a.z + b.z) / 2)
    }

    /// Component of `self` perpendicular to `axis`. Returns nil when `self` is
    /// (near) parallel to the axis, i.e. the projection carries no direction.
    public func projectedOntoPlane(normal axis: Vector3) -> Vector3? {
        guard let n = axis.normalized() else { return nil }
        let projected = self - n * self.dot(n)
        guard projected.length > Self.degenerateLengthThreshold else { return nil }
        return projected
    }

    /// Vectors shorter than this are treated as degenerate (coincident landmarks).
    /// Chosen well below any real inter-joint distance in either coordinate space:
    /// normalized image coords are 0...1, world landmarks are metre-scale.
    public static let degenerateLengthThreshold = 1e-6
}
