import Foundation

public enum ChatRole: String, Sendable, Codable {
    case user
    case assistant
    /// App-generated status, e.g. "AI 教练尚未连接". Rendered differently from
    /// `assistant` and never counted as model output.
    case system
}

public enum ChatMessageKind: String, Sendable, Codable {
    case text
    /// Status notice produced by the app itself, not by any model.
    case statusNotice
    /// Clearly labelled sample content for development previews only.
    case developmentPreview
}

public enum ChatMessageStatus: String, Sendable, Codable {
    case draft, sending, sent, generating, failed, cancelled, delivered
}

/// A reference from a message back into the analysis, so a future model reply
/// can link to the exact metric and frame it is talking about.
public struct ChatReference: Sendable, Codable, Equatable {
    public var metricID: MetricID?
    public var side: BodySide?
    public var phase: SwingPhase?
    public var timestampSeconds: Double?

    public init(metricID: MetricID? = nil, side: BodySide? = nil,
                phase: SwingPhase? = nil, timestampSeconds: Double? = nil) {
        self.metricID = metricID
        self.side = side
        self.phase = phase
        self.timestampSeconds = timestampSeconds
    }
}

public struct ChatMessage: Sendable, Codable, Identifiable, Equatable {
    public let id: UUID
    public var role: ChatRole
    public var kind: ChatMessageKind
    public var content: String
    public var createdAt: Date
    public var status: ChatMessageStatus
    public var references: [ChatReference]
    /// The analysis version this message was written against. If the swing is
    /// re-analysed, older messages can be marked as referring to stale results.
    public var analysisVersion: Int?
    /// True for messages created while no chat service was configured. These are
    /// never uploaded if a real service is connected later.
    public var producedWhileUnconfigured: Bool

    public init(id: UUID = UUID(),
                role: ChatRole,
                kind: ChatMessageKind = .text,
                content: String,
                createdAt: Date = Date(),
                status: ChatMessageStatus = .sent,
                references: [ChatReference] = [],
                analysisVersion: Int? = nil,
                producedWhileUnconfigured: Bool = false) {
        self.id = id
        self.role = role
        self.kind = kind
        self.content = content
        self.createdAt = createdAt
        self.status = status
        self.references = references
        self.analysisVersion = analysisVersion
        self.producedWhileUnconfigured = producedWhileUnconfigured
    }

    public static let notConnectedNoticeZH =
        "AI 教练尚未连接，连接后可根据本次挥杆数据进行解读。"

    public static func notConnectedNotice(analysisVersion: Int?) -> ChatMessage {
        ChatMessage(role: .system,
                    kind: .statusNotice,
                    content: notConnectedNoticeZH,
                    status: .delivered,
                    analysisVersion: analysisVersion,
                    producedWhileUnconfigured: true)
    }
}

public struct Conversation: Sendable, Codable, Identifiable, Equatable {
    public let id: UUID
    public let swingID: UUID
    public var messages: [ChatMessage]
    public let createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), swingID: UUID, messages: [ChatMessage] = [],
                createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.swingID = swingID
        self.messages = messages
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Appends a user message. Retrying a failed send must reuse the existing
    /// message id rather than inserting a duplicate — see `markRetrying`.
    public mutating func append(_ message: ChatMessage) {
        messages.append(message)
        updatedAt = Date()
    }

    public mutating func markRetrying(messageID: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == messageID }) else { return }
        messages[index].status = .sending
        updatedAt = Date()
    }

    public mutating func updateStatus(messageID: UUID, to status: ChatMessageStatus) {
        guard let index = messages.firstIndex(where: { $0.id == messageID }) else { return }
        messages[index].status = status
        updatedAt = Date()
    }

    public static let suggestedQuestionsZH = [
        "帮我解读这次挥杆。",
        "我的引导臂在哪个阶段弯曲？",
        "这次和上次相比有什么变化？",
        "下一次练习应该关注什么？"
    ]
}
