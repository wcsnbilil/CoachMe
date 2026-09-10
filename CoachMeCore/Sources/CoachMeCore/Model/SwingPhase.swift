import Foundation

/// The swing positions a coach can mark.
///
/// Version 1 does **not** detect these automatically. Auto-phase-detection has
/// not been validated against labelled swings, and a wrong phase label would
/// silently corrupt every rule that is scoped to a phase. The coach marks them.
public enum SwingPhase: String, Sendable, Codable, CaseIterable, Identifiable {
    case address        // 准备姿势
    case midBackswing   // 上杆中段
    case top            // 上杆顶点
    case midDownswing   // 下杆中段
    case impact         // 击球
    case finish         // 收杆

    public var id: String { rawValue }

    public var nameZH: String {
        switch self {
        case .address:      return "准备姿势"
        case .midBackswing: return "上杆中段"
        case .top:          return "上杆顶点"
        case .midDownswing: return "下杆中段"
        case .impact:       return "击球"
        case .finish:       return "收杆"
        }
    }

    /// Canonical order, used to align two swings before comparing them.
    public var order: Int { Self.allCases.firstIndex(of: self)! }
}

/// A coach-placed marker tying a phase to an exact frame time.
public struct Keyframe: Sendable, Codable, Identifiable, Equatable {
    public let id: UUID
    public var phase: SwingPhase
    /// Original video presentation timestamp, in seconds.
    public var timestampSeconds: Double
    public var markedByCoach: Bool
    public var note: String

    public init(id: UUID = UUID(),
                phase: SwingPhase,
                timestampSeconds: Double,
                markedByCoach: Bool = true,
                note: String = "") {
        self.id = id
        self.phase = phase
        self.timestampSeconds = timestampSeconds
        self.markedByCoach = markedByCoach
        self.note = note
    }
}

public extension Array where Element == Keyframe {
    func keyframe(for phase: SwingPhase) -> Keyframe? {
        first { $0.phase == phase }
    }

    /// Phases present in this swing, in swing order.
    var orderedPhases: [SwingPhase] {
        map(\.phase).sorted { $0.order < $1.order }
    }

    /// Phases that both swings have, so a comparison aligns on the action rather
    /// than on seconds elapsed since the clip started.
    func commonPhases(with other: [Keyframe]) -> [SwingPhase] {
        let mine = Set(map(\.phase)), theirs = Set(other.map(\.phase))
        return mine.intersection(theirs).sorted { $0.order < $1.order }
    }
}
