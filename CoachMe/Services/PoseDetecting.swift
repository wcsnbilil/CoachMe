import Foundation
import CoreVideo
import CoachMeCore

/// One detection result, already converted into CoachMeCore's model.
public struct PoseDetectionResult {
    public let imageLandmarks: [Landmark]
    public let worldLandmarks: [Landmark]?
    public let personCount: Int
}

public enum PoseDetectorError: LocalizedError {
    case modelFileMissing(expectedName: String)
    case modelLoadFailed(underlying: String)
    case detectionFailed(underlying: String)

    public var errorDescription: String? {
        switch self {
        case .modelFileMissing(let name):
            return "缺少姿态模型文件 \(name)。请按 docs/MAC_SETUP.md 下载模型并加入 App Bundle。"
        case .modelLoadFailed(let detail):
            return "姿态模型加载失败：\(detail)"
        case .detectionFailed(let detail):
            return "姿态识别失败：\(detail)"
        }
    }
}

/// The seam between the app and the pose SDK.
///
/// Everything above this protocol speaks only in CoachMeCore types, so swapping
/// MediaPipe for another detector (or for a recorded fixture in tests) touches
/// nothing else.
public protocol PoseDetecting: AnyObject {
    /// Prepares the model. Throws rather than silently degrading, so the UI can
    /// show "模型文件缺失" instead of producing empty analyses.
    func prepare() throws

    /// Detects on one decoded frame.
    /// - Parameter timestampMilliseconds: must come from the sample buffer's
    ///   presentation time, and must increase monotonically — MediaPipe's video
    ///   mode rejects out-of-order timestamps.
    func detect(pixelBuffer: CVPixelBuffer, timestampMilliseconds: Int) throws -> PoseDetectionResult

    func reset()
}
