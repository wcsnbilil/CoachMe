import Foundation

/// Swing positions detected automatically or marked by the coach.
public enum SwingPhase: String, Sendable, Codable, CaseIterable, Identifiable {
    case address        // 准备姿势
    case takeaway       // 上杆下段（杆身接近水平）
    case midBackswing   // 上杆中段
    case top            // 上杆顶点
    case midDownswing   // 下杆中段
    case impact         // 击球
    case finish         // 收杆

    public var id: String { rawValue }

    public var nameZH: String {
        switch self {
        case .address:      return "准备姿势"
        case .takeaway:     return "上杆下段"
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

/// A marker tying a phase to an exact frame time, with automatic/manual provenance.
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
