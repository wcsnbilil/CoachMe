import Foundation
import CoachMeCore

/// Everything saved about one analysed swing.
///
/// The video itself lives beside this record in the app's Documents directory;
/// only its relative filename is stored, so the sandbox path changing between
/// installs does not orphan the record.
struct SwingRecord: Codable, Identifiable, Equatable {
    let id: UUID
    var title: String
    var createdAt: Date

    /// Filename relative to the videos directory.
    var videoFilename: String
    /// The portion the user chose to analyse.
    var clipStartSeconds: Double
    var clipEndSeconds: Double

    var handedness: Handedness
    var club: ClubType
    var cameraView: CameraView

    var keyframes: [Keyframe]
    var phaseDetectionNote: String?

    /// Bumped every time the swing is re-analysed. Chat messages record the
    /// version they were written against so stale references can be flagged.
    var analysisVersion: Int

    /// Provenance, so a number in an old report can always be traced back.
    var poseModelIdentifier: String
    var algorithmVersion: String
    var qualityPolicy: QualityPolicy

    init(id: UUID = UUID(),
         title: String,
         createdAt: Date = Date(),
         videoFilename: String,
         clipStartSeconds: Double,
         clipEndSeconds: Double,
         handedness: Handedness,
         club: ClubType,
         cameraView: CameraView,
         keyframes: [Keyframe] = [],
         analysisVersion: Int = 1,
         poseModelIdentifier: String,
         algorithmVersion: String = AppVersion.algorithm,
         qualityPolicy: QualityPolicy = .default) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.videoFilename = videoFilename
        self.clipStartSeconds = clipStartSeconds
        self.clipEndSeconds = clipEndSeconds
        self.handedness = handedness
        self.club = club
        self.cameraView = cameraView
        self.keyframes = keyframes
        self.analysisVersion = analysisVersion
        self.poseModelIdentifier = poseModelIdentifier
        self.algorithmVersion = algorithmVersion
        self.qualityPolicy = qualityPolicy
    }

    var durationSeconds: Double { max(0, clipEndSeconds - clipStartSeconds) }

    var addressKeyframe: Keyframe? { keyframes.keyframe(for: .address) }
}

enum AppVersion {
    /// Bump whenever a metric formula changes. Stored on every analysis so an
    /// old report is never silently reinterpreted under new maths.
    static let algorithm = "1.0.0"
}

/// The per-frame output of an analysis run, cached to disk so replay never
/// re-runs inference.
struct AnalysisCache: Codable {
    let swingID: UUID
    let analysisVersion: Int
    let algorithmVersion: String
    let poseModelIdentifier: String
    let createdAt: Date
    /// Raw landmarks exactly as the model produced them. Kept alongside any
    /// smoothed variant so the processing can be re-run or audited later.
    let frames: [PoseFrame]
    /// Smoothing parameters actually applied, or nil when none were.
    let smoothing: SmoothingParameters?

    /// `frames` with the recorded smoothing applied.
    ///
    /// A method rather than a computed property because it filters every frame:
    /// call it once and hold the result, do not touch it on a playback tick.
    /// `frames` itself stays raw, so a different filter can be tried later
    /// without re-running inference.
    func smoothedFrames() -> [PoseFrame] {
        guard let smoothing else { return frames }
        return PoseSequenceSmoother(parameters: smoothing).smooth(frames)
    }
}
