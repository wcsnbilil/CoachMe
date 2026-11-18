import Foundation

/// What was actually done to the landmarks, recorded so a report can state it.
///
/// Smoothing changes the numbers a coach reads. It is therefore never implicit:
/// the parameters travel with the cached analysis, and `none` is a real option.
public struct SmoothingParameters: Sendable, Codable, Equatable {
    public var minCutoff: Double
    public var beta: Double
    public var derivativeCutoff: Double
    /// Landmarks below this visibility are passed through untouched and are not
    /// fed into the filter. A landmark the model could not see must not be
    /// invented by carrying a stale position forward.
    public var minVisibility: Double

    public init(minCutoff: Double, beta: Double, derivativeCutoff: Double = 1.0, minVisibility: Double) {
        self.minCutoff = minCutoff
        self.beta = beta
        self.derivativeCutoff = derivativeCutoff
        self.minVisibility = minVisibility
    }

    /// For footage shot at normal speed.
    ///
    /// Tuned by sweeping against real 24 fps driver footage, scoring three things
    /// at once: frame-to-frame jitter across the top-of-backswing plateau, how far
    /// the peak moved, and how much of the downswing's real frame-to-frame change
    /// survived. 5 Hz cut plateau jitter from 3.64° to 1.58° while keeping 85% of
    /// the downswing's rate of change. Below 3 Hz the filter eats the downswing
    /// itself — at 1 Hz the smoothed curve ran 46° behind the raw one through
    /// impact. Above 8 Hz the noise comes back.
    ///
    /// The optimum is shallow, and 1.58° is still large next to the differences a
    /// coach wants to read. See `docs/LIMITATIONS.md` §6.
    public static let realTime = SmoothingParameters(minCutoff: 5.0, beta: 2.0, minVisibility: 0.5)

    /// For footage already slowed down — a phone's slow-motion mode, or a clip
    /// exported at reduced speed.
    ///
    /// Tuned the same way against super-slow-motion broadcast footage where one
    /// swing spans about 18 seconds. Jitter across the top plateau fell from
    /// 2.09° to 0.41°, an 80% reduction, and the peak stayed at the same frame
    /// across every nearby parameter choice — which it does **not** do on
    /// real-time footage.
    ///
    /// `minCutoff` is roughly eight times lower than `realTime`, matching the
    /// slow-motion factor: stretching time lowers every frequency in the signal
    /// by the same ratio, so the cutoff has to come down with it. This is why one
    /// fixed default cannot serve both, and why the choice is asked for at import
    /// rather than guessed: nothing in the file says how much it was slowed by.
    public static let slowMotion = SmoothingParameters(minCutoff: 0.6, beta: 4.0, minVisibility: 0.5)

    /// Real-time is the default because it is the safer error: applying it to
    /// slow-motion footage merely under-smooths, while the reverse smears the
    /// downswing badly.
    public static let `default` = SmoothingParameters.realTime

    public var describedZH: String {
        "One Euro 滤波：minCutoff \(minCutoff) Hz，beta \(beta)，可见度门槛 \(minVisibility)"
    }
}

/// Applies One Euro smoothing across a decoded sequence, per landmark per axis.
///
/// Image-space and world-space landmarks are filtered independently, using the
/// source presentation timestamps so variable frame rates stay correct.
///
/// Three things this deliberately does not do:
/// - It does not touch `visibility` or `presence`. Those are the model's own
///   scores; smoothing positions does not make the model more certain.
/// - It does not fill in landmarks the model failed to see. A sample below the
///   visibility gate is passed through and the filter state is left frozen, so a
///   stale position is never presented as an observation.
/// - It does not change `detectedPersonCount` or any quality finding.
public struct PoseSequenceSmoother: Sendable {

    public let parameters: SmoothingParameters

    public init(parameters: SmoothingParameters = .default) {
        self.parameters = parameters
    }

    public func smooth(_ frames: [PoseFrame]) -> [PoseFrame] {
        guard frames.count > 1 else { return frames }

        let filter = OneEuroFilter(minCutoff: parameters.minCutoff,
                                   beta: parameters.beta,
                                   derivativeCutoff: parameters.derivativeCutoff)

        let jointCount = PoseJoint.allCases.count
        var imageState = Array(repeating: Array(repeating: OneEuroFilter.State(), count: 3),
                               count: jointCount)
        var worldState = imageState

        return frames.map { frame in
            let t = frame.timestampSeconds

            func run(_ landmarks: [Landmark], _ state: inout [[OneEuroFilter.State]]) -> [Landmark] {
                landmarks.enumerated().map { index, landmark in
                    guard index < state.count else { return landmark }
                    // Gate on the image-space visibility: the world landmarks
                    // share indices but carry no score of their own.
                    let visibility = frame.imageLandmark(PoseJoint(rawValue: index) ?? .nose)?.visibility
                        ?? landmark.visibility ?? 1.0
                    guard visibility >= parameters.minVisibility else { return landmark }

                    let p = landmark.position
                    let x = filter.filter(p.x, timestamp: t, state: &state[index][0])
                    let y = filter.filter(p.y, timestamp: t, state: &state[index][1])
                    let z = filter.filter(p.z, timestamp: t, state: &state[index][2])
                    return Landmark(position: Vector3(x, y, z),
                                    visibility: landmark.visibility,
                                    presence: landmark.presence)
                }
            }

            return PoseFrame(timestampSeconds: t,
                             imageLandmarks: run(frame.imageLandmarks, &imageState),
                             worldLandmarks: frame.worldLandmarks.map { run($0, &worldState) },
                             detectedPersonCount: frame.detectedPersonCount)
        }
    }
}
