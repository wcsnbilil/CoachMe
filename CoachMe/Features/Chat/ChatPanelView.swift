import SwiftUI
import CoachMeCore

/// Chat surface for one swing.
///
/// Version 1 is backed by `UnconfiguredChatService`: the user can type and send,
/// the message is stored locally, and the app replies with a clearly-marked
/// status notice. No model is called and no coaching answer is fabricated.
@MainActor
struct ChatPanelView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: ChatModel
    @State private var draft = ""
    @FocusState private var inputFocused: Bool

    init(swing: SwingRecord, phase: SwingPhase?, timestamp: Double, context: SwingAnalysisContext) {
        _model = State(initialValue: ChatModel(swing: swing, phase: phase,
                                               timestamp: timestamp, context: context))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                Divider()
                messageList
                Divider()
                suggestions
                inputBar
            }
            .navigationTitle("AI 教练")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("返回视频") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.swing.title).font(.subheadline.bold())
            HStack(spacing: 6) {
                if let phase = model.phase {
                    Label(phase.nameZH, systemImage: "mappin.circle").font(.caption)
                } else {
                    Text("未选中关键帧").font(.caption)
                }
                Text("·").font(.caption)
                Text(String(format: "%.2f 秒", model.timestamp)).font(.caption.monospacedDigit())
            }
            .foregroundStyle(.secondary)

            // Connection state is stated with an icon and words, not colour alone.
            Label("AI 尚未连接", systemImage: "bolt.horizontal.circle")
                .font(.caption.bold())
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(.quaternary, in: Capsule())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if model.conversation.messages.isEmpty {
                        Text("你可以先问一个问题。当前版本不会生成回答，但你的提问会保存下来。")
                            .font(.footnote).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 24)
                    }
                    ForEach(model.conversation.messages) { message in
                        MessageBubble(message: message).id(message.id)
                    }
                }
                .padding()
            }
            .onChange(of: model.conversation.messages.count) { _, _ in
                if let last = model.conversation.messages.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private var suggestions: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Conversation.suggestedQuestionsZH, id: \.self) { question in
                    Button(question) {
                        // Fills the field so the user can edit before sending.
                        draft = question
                        inputFocused = true
                    }
                    .font(.caption)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.quaternary, in: Capsule())
                }
            }
            .padding(.horizontal)
        }
        .padding(.vertical, 8)
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("输入你的问题", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.roundedBorder)
                .focused($inputFocused)
                .accessibilityLabel("提问输入框")

            Button {
                let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return }
                draft = ""
                Task { await model.send(text) }
            } label: {
                Image(systemName: "arrow.up.circle.fill").font(.title2)
            }
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isSending)
            .accessibilityLabel("发送")
        }
        .padding()
    }
}

@MainActor
struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        VStack(alignment: alignment == .leading ? .leading : .trailing, spacing: 4) {
            switch message.kind {
            case .statusNotice:
                // Visually and structurally distinct from a model answer.
                Label(message.content, systemImage: "info.circle")
                    .font(.footnote)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(alignment: .topTrailing) {
                        Text("系统状态").font(.caption2).padding(4).foregroundStyle(.secondary)
                    }

            case .developmentPreview:
                VStack(alignment: .leading, spacing: 4) {
                    Label("开发预览示例（非真实分析）", systemImage: "hammer")
                        .font(.caption2.bold())
                    Text(message.content).font(.footnote)
                }
                .padding(10)
                .background(.yellow.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))

            case .text:
                Text(message.content)
                    .padding(10)
                    .background(message.role == .user ? AnyShapeStyle(Palette.leadArm.opacity(0.2))
                                                      : AnyShapeStyle(.quaternary),
                                in: RoundedRectangle(cornerRadius: 12))
            }

            if message.status == .failed {
                Label("发送失败", systemImage: "exclamationmark.circle").font(.caption2)
            }
        }
        .frame(maxWidth: .infinity, alignment: alignment)
        .accessibilityElement(children: .combine)
    }

    private var alignment: Alignment { message.role == .user ? .trailing : .leading }
}

@MainActor
@Observable
final class ChatModel {
    let swing: SwingRecord
    let phase: SwingPhase?
    let timestamp: Double
    let context: SwingAnalysisContext
    private(set) var conversation: Conversation
    private(set) var isSending = false

    private let service: ChatService
    private let store: LocalStore

    init(swing: SwingRecord,
         phase: SwingPhase?,
         timestamp: Double,
         context: SwingAnalysisContext,
         service: ChatService = UnconfiguredChatService(),
         store: LocalStore = .shared) {
        self.swing = swing
        self.phase = phase
        self.timestamp = timestamp
        self.context = context
        self.service = service
        self.store = store
        self.conversation = store.loadConversation(swingID: swing.id)
            ?? Conversation(swingID: swing.id)
    }

    func send(_ text: String) async {
        isSending = true
        defer { isSending = false }

        let message = ChatMessage(
            role: .user,
            content: text,
            status: .sent,
            references: [ChatReference(phase: phase, timestampSeconds: timestamp)],
            analysisVersion: swing.analysisVersion,
            producedWhileUnconfigured: !service.isConfigured)
        conversation.append(message)
        persist()

        for await event in service.send(message: message,
                                        conversation: conversation,
                                        context: context,
                                        options: ChatRequestOptions()).mapErrorToEvents() {
            switch event {
            case .failed(let error):
                // The only reply v1 can honestly produce: a status notice.
                let notice = error == .notConfigured
                    ? ChatMessage.notConnectedNotice(analysisVersion: swing.analysisVersion)
                    : ChatMessage(role: .system, kind: .statusNotice, content: error.messageZH,
                                  status: .delivered, producedWhileUnconfigured: true)
                conversation.append(notice)
            case .finished(let reply):
                conversation.append(reply)
            case .started, .delta, .reference:
                break
            }
        }
        persist()
    }

    private func persist() { try? store.saveConversation(conversation) }
}

private extension AsyncThrowingStream where Element == ChatStreamEvent, Failure == Error {
    /// Converts a thrown error into a terminal `.failed` event so callers handle
    /// one code path.
    func mapErrorToEvents() -> AsyncStream<ChatStreamEvent> {
        AsyncStream { continuation in
            Task {
                do {
                    for try await event in self { continuation.yield(event) }
                } catch let error as ChatServiceError {
                    continuation.yield(.failed(error))
                } catch {
                    continuation.yield(.failed(.transport(error.localizedDescription)))
                }
                continuation.finish()
            }
        }
    }
}
