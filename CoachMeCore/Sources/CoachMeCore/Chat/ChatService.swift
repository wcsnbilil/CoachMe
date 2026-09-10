import Foundation

public enum ChatServiceError: Error, Sendable, Equatable {
    case notConfigured
    case cancelled
    case timedOut
    case contextTooLarge(tokenEstimate: Int, limit: Int)
    case transport(String)
    case server(status: Int, message: String)

    public var messageZH: String {
        switch self {
        case .notConfigured:        return ChatMessage.notConnectedNoticeZH
        case .cancelled:            return "已取消。"
        case .timedOut:             return "请求超时，请重试。"
        case .contextTooLarge:      return "本次分析数据过长，无法一次性发送。"
        case .transport(let detail): return "网络错误：\(detail)"
        case .server(_, let message): return "服务返回错误：\(message)"
        }
    }
}

/// One chunk of a streamed reply.
public enum ChatStreamEvent: Sendable, Equatable {
    case started(messageID: UUID)
    case delta(String)
    case reference(ChatReference)
    case finished(ChatMessage)
    case failed(ChatServiceError)
}

/// Knobs the UI can set without knowing which provider is behind the protocol.
public struct ChatRequestOptions: Sendable, Equatable {
    public var timeout: TimeInterval
    public var maxRetries: Int
    /// Upper bound on context size, enforced before any request is built.
    public var contextTokenLimit: Int

    public init(timeout: TimeInterval = 60, maxRetries: Int = 2, contextTokenLimit: Int = 32_000) {
        self.timeout = timeout
        self.maxRetries = maxRetries
        self.contextTokenLimit = contextTokenLimit
    }
}

/// The single seam between the chat UI and any future model backend.
///
/// Swapping in a real implementation must not require changes to the chat views,
/// the conversation store, or the context builder.
public protocol ChatService: Sendable {
    var isConfigured: Bool { get }

    /// Streams a reply. Implementations must honour task cancellation.
    func send(message: ChatMessage,
              conversation: Conversation,
              context: SwingAnalysisContext,
              options: ChatRequestOptions) -> AsyncThrowingStream<ChatStreamEvent, Error>
}

/// The version-1 implementation.
///
/// Performs no network access of any kind and returns no generated text. It
/// exists so the whole chat surface — history, state machine, persistence,
/// context building — is real and testable before a model is connected.
public struct UnconfiguredChatService: ChatService {
    public init() {}

    public var isConfigured: Bool { false }

    public func send(message: ChatMessage,
                     conversation: Conversation,
                     context: SwingAnalysisContext,
                     options: ChatRequestOptions) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            // No URLSession, no sockets, no file writes. The failure is immediate
            // and structured, so the UI shows a status notice rather than a
            // fabricated coaching answer.
            continuation.yield(.failed(.notConfigured))
            continuation.finish()
        }
    }
}
