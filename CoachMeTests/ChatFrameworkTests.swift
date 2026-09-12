import XCTest
import CoachMeCore
@testable import CoachMe

/// Spec §12.4 — the chat framework must be real and swappable before any model
/// exists behind it.
///
/// NOT YET EXECUTED — requires Xcode on macOS.
final class ChatFrameworkTests: XCTestCase {

    private func makeStore() -> LocalStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoachMeTests-\(UUID().uuidString)", isDirectory: true)
        return LocalStore(root: root)
    }

    private func makeSwing() -> SwingRecord {
        SwingRecord(title: "测试挥杆",
                    videoFilename: "test.mov",
                    clipStartSeconds: 0,
                    clipEndSeconds: 2,
                    handedness: .rightHanded,
                    club: .iron,
                    cameraView: .faceOn,
                    poseModelIdentifier: "pose_landmarker_lite")
    }

    private func makeContext(swing: SwingRecord) -> SwingAnalysisContext {
        SwingAnalysisContext(
            swingID: swing.id, analysisVersion: 1, handedness: .rightHanded,
            club: .iron, cameraView: .faceOn, markedPhases: [.address],
            selectedPhase: .address, selectedTimestampSeconds: 0.5, readings: [],
            quality: .init(framesAnalysed: 0, framesWithNoPerson: 0, framesWithMultiplePeople: 0,
                           metricsUnavailable: [],
                           statedLimitationsZH: SwingAnalysisContext.standingLimitationsZH),
            comparison: nil)
    }

    @MainActor
    func testUserMessageIsStoredAndRestored() async {
        let store = makeStore()
        let swing = makeSwing()
        let model = ChatModel(swing: swing, phase: .address, timestamp: 0.5,
                              context: makeContext(swing: swing), service: UnconfiguredChatService(), store: store)

        await model.send("我的引导臂在哪个阶段弯曲？")

        XCTAssertEqual(model.conversation.messages.filter { $0.role == .user }.count, 1)

        // A fresh model must restore the same history from disk.
        let reopened = ChatModel(swing: swing, phase: nil, timestamp: 0,
                                 context: makeContext(swing: swing), service: UnconfiguredChatService(), store: store)
        XCTAssertEqual(reopened.conversation.messages.count, model.conversation.messages.count)
        XCTAssertEqual(reopened.conversation.messages.first?.content,
                       "我的引导臂在哪个阶段弯曲？")
    }

    @MainActor
    func testUnconfiguredServiceRepliesWithStatusNoticeNotAnAnswer() async {
        let store = makeStore()
        let swing = makeSwing()
        let model = ChatModel(swing: swing, phase: nil, timestamp: 0,
                              context: makeContext(swing: swing), service: UnconfiguredChatService(), store: store)

        await model.send("帮我解读这次挥杆。")

        let replies = model.conversation.messages.filter { $0.role != .user }
        XCTAssertEqual(replies.count, 1)
        let reply = try! XCTUnwrap(replies.first)
        // It must be a status notice, not an assistant answer.
        XCTAssertEqual(reply.role, .system)
        XCTAssertEqual(reply.kind, .statusNotice)
        XCTAssertEqual(reply.content, ChatMessage.notConnectedNoticeZH)
        XCTAssertTrue(reply.producedWhileUnconfigured)
        XCTAssertFalse(model.conversation.messages.contains { $0.role == .assistant },
                       "v1 must never produce an assistant-authored reply")
    }

    func testUnconfiguredServiceReportsNotConfiguredAndDoesNoWork() async throws {
        let service = UnconfiguredChatService()
        XCTAssertFalse(service.isConfigured)

        let swing = makeSwing()
        var events: [ChatStreamEvent] = []
        let stream = service.send(message: ChatMessage(role: .user, content: "hi"),
                                  conversation: Conversation(swingID: swing.id),
                                  context: makeContext(swing: swing),
                                  options: ChatRequestOptions())
        for try await event in stream { events.append(event) }

        XCTAssertEqual(events, [.failed(.notConfigured)])
    }

    @MainActor
    func testRetryDoesNotDuplicateTheUserMessage() {
        var conversation = Conversation(swingID: UUID())
        let message = ChatMessage(role: .user, content: "重试测试", status: .failed)
        conversation.append(message)

        conversation.markRetrying(messageID: message.id)

        XCTAssertEqual(conversation.messages.count, 1)
        XCTAssertEqual(conversation.messages.first?.status, .sending)
    }

    func testContextCarriesLimitationsAndNeverInventsRanges() {
        let swing = makeSwing()
        let context = makeContext(swing: swing)
        XCTAssertFalse(context.quality.statedLimitationsZH.isEmpty)
        // No reading may carry a coach range that no coach authored.
        XCTAssertTrue(context.readings.allSatisfy { $0.coachRange == nil })
    }

    /// The UI must not need editing when a real service is dropped in.
    @MainActor
    func testServiceIsSwappableWithoutTouchingTheChatUI() async {
        struct StubService: ChatService {
            var isConfigured: Bool { true }
            func send(message: ChatMessage, conversation: Conversation,
                      context: SwingAnalysisContext,
                      options: ChatRequestOptions) -> AsyncThrowingStream<ChatStreamEvent, Error> {
                AsyncThrowingStream { continuation in
                    continuation.yield(.finished(ChatMessage(role: .assistant, content: "stub")))
                    continuation.finish()
                }
            }
        }

        let store = makeStore()
        let swing = makeSwing()
        let model = ChatModel(swing: swing, phase: nil, timestamp: 0,
                              context: makeContext(swing: swing),
                              service: StubService(), store: store)
        await model.send("问题")

        XCTAssertTrue(model.conversation.messages.contains { $0.role == .assistant && $0.content == "stub" })
    }
}
