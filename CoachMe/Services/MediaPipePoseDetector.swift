import Foundation
import CoreVideo
import MediaPipeTasksVision
import CoachMeCore

/// MediaPipe Pose Landmarker, running in `.video` mode.
///
/// NOT YET COMPILED OR RUN. The API names below follow the official iOS guide
/// (`PoseLandmarkerOptions`, `PoseLandmarker(options:)`,
/// `detect(videoFrame:timestampInMilliseconds:)`) but nothing here has been
/// built against the real SDK — there is no Mac on the development machine.
/// Expect to fix small signature mismatches on the first Xcode build.
final class MediaPipePoseDetector: PoseDetecting {

    /// Model file expected in the app bundle. Heavy is the default for analysis.
    enum ModelVariant: String {
        case lite = "pose_landmarker_lite"
        case full = "pose_landmarker_full"
        case heavy = "pose_landmarker_heavy"
    }

    private let variant: ModelVariant
    private let numPoses: Int
    private let minDetectionConfidence: Float
    private let minPresenceConfidence: Float
    private let minTrackingConfidence: Float

    private var landmarker: PoseLandmarker?
    /// MediaPipe's video mode requires strictly increasing timestamps.
    private var lastTimestamp: Int = -1

    init(variant: ModelVariant = .heavy,
         numPoses: Int = 2,               // detect a second person so we can REPORT it, not hide it
         minDetectionConfidence: Float = 0.5,
         minPresenceConfidence: Float = 0.5,
         minTrackingConfidence: Float = 0.5) {
        self.variant = variant
        self.numPoses = numPoses
        self.minDetectionConfidence = minDetectionConfidence
        self.minPresenceConfidence = minPresenceConfidence
        self.minTrackingConfidence = minTrackingConfidence
    }

    func prepare() throws {
        guard let path = Bundle.main.path(forResource: variant.rawValue, ofType: "task") else {
            throw PoseDetectorError.modelFileMissing(expectedName: "\(variant.rawValue).task")
        }

        let options = PoseLandmarkerOptions()
        options.baseOptions.modelAssetPath = path
        options.runningMode = .video
        options.numPoses = numPoses
        options.minPoseDetectionConfidence = minDetectionConfidence
        options.minPosePresenceConfidence = minPresenceConfidence
        options.minTrackingConfidence = minTrackingConfidence
        // Segmentation masks are not used; not requesting them saves work per frame.
        options.shouldOutputSegmentationMasks = false

        do {
            landmarker = try PoseLandmarker(options: options)
            lastTimestamp = -1
        } catch {
            throw PoseDetectorError.modelLoadFailed(underlying: error.localizedDescription)
        }
    }

    func reset() {
        lastTimestamp = -1
    }

    func detect(pixelBuffer: CVPixelBuffer, timestampMilliseconds: Int) throws -> PoseDetectionResult {
        guard let landmarker else {
            throw PoseDetectorError.modelLoadFailed(underlying: "detector 未初始化，请先调用 prepare()")
        }

        // Guard the monotonic-timestamp contract rather than letting the SDK throw.
        let timestamp = max(timestampMilliseconds, lastTimestamp + 1)
        lastTimestamp = timestamp

        let image: MPImage
        do {
            image = try MPImage(pixelBuffer: pixelBuffer)
        } catch {
            throw PoseDetectorError.detectionFailed(underlying: "无法包装图像：\(error.localizedDescription)")
        }

        let result: PoseLandmarkerResult
        do {
            result = try landmarker.detect(videoFrame: image, timestampInMilliseconds: timestamp)
        } catch {
            throw PoseDetectorError.detectionFailed(underlying: error.localizedDescription)
        }

        let personCount = result.landmarks.count
        guard let first = result.landmarks.first else {
            return PoseDetectionResult(imageLandmarks: [], worldLandmarks: nil, personCount: 0)
        }

        // Only the first pose is measured. When personCount > 1 the quality gate
        // in CoachMeCore refuses every metric for the frame, so we never silently
        // measure whichever body the tracker happened to pick.
        let imageLandmarks = first.map { point in
            CoachMeCore.Landmark(Double(point.x), Double(point.y), Double(point.z),
                     visibility: point.visibility?.doubleValue,
                     presence: point.presence?.doubleValue)
        }

        var worldLandmarks: [CoachMeCore.Landmark]?
        if let world = result.worldLandmarks.first {
            worldLandmarks = world.map { point in
                CoachMeCore.Landmark(Double(point.x), Double(point.y), Double(point.z),
                         visibility: point.visibility?.doubleValue,
                         presence: point.presence?.doubleValue)
            }
        }

        return PoseDetectionResult(imageLandmarks: imageLandmarks,
                                   worldLandmarks: worldLandmarks,
                                   personCount: personCount)
    }
}
