import Foundation

/// One Euro filter — a low-pass whose cutoff rises with the signal's own speed.
///
/// Chosen over a fixed window (moving average or median) because a golf swing
/// spans two very different regimes in one clip: the club is nearly still at
/// address and at the top, then travels through impact in about eight frames at
/// 24 fps. A window wide enough to calm the slow parts smears the fast ones, and
/// the smearing lands exactly on the frames a coach cares most about.
///
/// Reference: Casiez, Roussel & Vogel, "1€ Filter: A Simple Speed-based
/// Low-pass Filter for Noisy Input in Interactive Systems", CHI 2012.
///
/// Deliberately not a Kalman filter: Kalman needs a motion model and process /
/// measurement covariances that this project has no data to justify. Inventing
/// those numbers would be the same sin as inventing a reference range.
public struct OneEuroFilter: Sendable {

    /// Cutoff in Hz at zero speed. Lower = smoother but laggier when still.
    public let minCutoff: Double
    /// How much the cutoff opens up as speed rises. Higher = less lag when fast.
    public let beta: Double
    /// Cutoff in Hz for the speed estimate itself.
    public let derivativeCutoff: Double

    public init(minCutoff: Double, beta: Double, derivativeCutoff: Double = 1.0) {
        self.minCutoff = minCutoff
        self.beta = beta
        self.derivativeCutoff = derivativeCutoff
    }

    /// Per-signal filter state. Value semantics so a caller can hold one per
    /// landmark per axis without any shared mutable state.
    public struct State: Sendable {
        var lastValue: Double?
        var lastDerivative: Double = 0
        var lastTimestamp: Double?

        public init() {}
    }

    private static func alpha(cutoff: Double, dt: Double) -> Double {
        let tau = 1.0 / (2.0 * .pi * cutoff)
        return 1.0 / (1.0 + tau / dt)
    }

    /// Filters one sample. `state` carries forward; `timestamp` is in seconds and
    /// must not go backwards.
    ///
    /// The first sample, and any sample arriving at a non-positive time step, is
    /// passed through untouched — there is no speed estimate to act on yet, and
    /// guessing one would fabricate motion.
    public func filter(_ value: Double, timestamp: Double, state: inout State) -> Double {
        guard let previous = state.lastValue, let lastTime = state.lastTimestamp else {
            state.lastValue = value
            state.lastTimestamp = timestamp
            state.lastDerivative = 0
            return value
        }

        let dt = timestamp - lastTime
        guard dt > 0 else {
            state.lastValue = value
            return value
        }

        let derivative = (value - previous) / dt
        let smoothedDerivative = Self.alpha(cutoff: derivativeCutoff, dt: dt) * derivative
            + (1 - Self.alpha(cutoff: derivativeCutoff, dt: dt)) * state.lastDerivative

        let cutoff = minCutoff + beta * abs(smoothedDerivative)
        let a = Self.alpha(cutoff: cutoff, dt: dt)
        let filtered = a * value + (1 - a) * previous

        state.lastValue = filtered
        state.lastDerivative = smoothedDerivative
        state.lastTimestamp = timestamp
        return filtered
    }
}
