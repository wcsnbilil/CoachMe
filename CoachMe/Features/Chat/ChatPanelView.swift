import SwiftUI
import CoachMeCore

/// Multi-provider chat with local conversation history.
@MainActor
struct ChatPanelView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: ChatModel
    @State private var draft = ""
    @State private var showingSettings = false
    @State private var requestTask: Task<Void, Never>?
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
            .background(CoachStyle.background)
            .navigationTitle("你的 AI 教练")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("设置") { showingSettings = true }.disabled(model.isSending)
                }
                ToolbarItem(placement: .cancellationAction) { Button("返回视频") { dismiss() } }
            }
        }
        .sheet(isPresented: $showingSettings, onDismiss: { model.reloadConfiguration() }) { AISettingsView() }
        .onDisappear { requestTask?.cancel() }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private var header: some View {
        HStack(alignment:.center,spacing:12) {
            Image(systemName:"sparkles").font(.title3)
                .foregroundStyle(CoachStyle.accent)
                .frame(width:44,height:44).background(CoachStyle.surface,in:RoundedRectangle(cornerRadius:14))
            VStack(alignment:.leading,spacing:4) {
                Text(model.swing.title).font(.subheadline.weight(.medium)).lineLimit(1)
                Text("一起找到下一次练习的重点").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength:0)
            if !model.isConfigured {
                Button("连接教练") { showingSettings = true }.font(.caption.weight(.semibold))
            }
        }.padding(.horizontal,20).padding(.vertical,14)
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if model.conversation.messages.isEmpty {
                        VStack(alignment:.leading,spacing:18) {
                            Text("今天，先改进一点。")
                                .font(.system(.title2,design:.serif,weight:.medium))
                            Text("一起看看这次挥杆，找到值得保留的动作，和下一次可以练习的重点。")
                                .font(.subheadline).foregroundStyle(.secondary).lineSpacing(5)
                            Button {
                                if model.isConfigured {
                                    requestTask = Task { await model.send("请像面对面带课一样看看我的挥杆，告诉我最值得调整的一两点，以及下一次该怎么练。") }
                                } else { showingSettings = true }
                            } label: { Label("解读这次挥杆",systemImage:"sparkles") }
                                .buttonStyle(CoachPrimaryButton()).disabled(model.isSending)
                        }.coachCard().padding(.top,14)
                    }
                    if model.isSending {
                        HStack { ProgressView(); Text(model.preparationLabel); Button("停止") { requestTask?.cancel() } }
                    }
                    ForEach(model.conversation.messages) { message in
                        VStack(alignment: .leading, spacing: 4) {
                            MessageBubble(message: message).id(message.id)
                            if let version = message.analysisVersion, version != model.swing.analysisVersion {
                                Text("此消息基于较早的关键帧/分析版本").font(.caption2).foregroundStyle(.secondary)
                            }
                            if message.role == .user && (message.status == .failed || message.status == .cancelled) {
                                Button("重试这个问题") { requestTask = Task { await model.retry(message) } }
                                    .font(.caption).disabled(model.isSending || !model.isConfigured)
                            }
                        }
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
                    .background(CoachStyle.surface, in: Capsule())
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
                .textFieldStyle(.plain)
                .padding(.horizontal,16).padding(.vertical,14)
                .background(CoachStyle.surface,in:RoundedRectangle(cornerRadius:22))
                .focused($inputFocused)
                .accessibilityLabel("提问输入框")

            Button {
                guard model.isConfigured else { showingSettings = true; return }
                let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return }
                draft = ""
                requestTask = Task { await model.send(text) }
            } label: {
                Image(systemName: "arrow.up").font(.body.weight(.semibold))
                    .foregroundStyle(.white).frame(width:46,height:46)
                    .background(CoachStyle.forest,in:Circle())
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
                VStack(alignment:.leading,spacing:9) {
                    if message.role == .assistant {
                        Label("COACH",systemImage:"sparkles").font(.caption2.weight(.bold))
                            .tracking(1.5).foregroundStyle(CoachStyle.accent)
                    }
                    Text(.init(message.content)).font(.body).lineSpacing(5).textSelection(.enabled)
                }
                .padding(16)
                .foregroundStyle(message.role == .user ? Color.white : Color.primary)
                .background(message.role == .user ? CoachStyle.forest : CoachStyle.surface,
                            in:RoundedRectangle(cornerRadius:20))
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
    private(set) var preparationLabel = "教练正在看动作…"

    private var service: ChatService
    private let injectedService: Bool
    private(set) var connectionLabel = "AI 尚未配置"
    var isConfigured: Bool { service.isConfigured }
    private let store: LocalStore

    init(swing: SwingRecord,
         phase: SwingPhase?,
         timestamp: Double,
         context: SwingAnalysisContext,
         service: ChatService? = nil,
         store: LocalStore = .shared) {
        self.swing = swing
        self.phase = phase
        self.timestamp = timestamp
        self.context = context
        self.injectedService = service != nil
        self.service = service ?? AISettingsStore.service()
        self.store = store
        self.conversation = store.loadConversation(swingID: swing.id)
            ?? Conversation(swingID: swing.id)
        self.connectionLabel = self.service.isConfigured ? "已配置 · " + AISettingsStore.configuration.provider.name : "AI 尚未配置"
    }

    func reloadConfiguration() {
        guard !injectedService else { return }
        service = AISettingsStore.service()
        connectionLabel = service.isConfigured ? "已配置 · " + AISettingsStore.configuration.provider.name : "AI 尚未配置"
    }

    func retry(_ message: ChatMessage) async {
        guard message.role == .user else { return }
        await send(message.content, retryID: message.id)
    }

    func send(_ text: String, retryID: UUID? = nil) async {
        guard !isSending, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isSending = true
        defer { isSending = false }

        let message = ChatMessage(
            id: retryID ?? UUID(),
            role: .user,
            content: text,
            status: .sent,
            references: [ChatReference(phase: phase, timestampSeconds: timestamp)],
            analysisVersion: swing.analysisVersion,
            producedWhileUnconfigured: !service.isConfigured)
        if let retryID, let index = conversation.messages.firstIndex(where: { $0.id == retryID }) {
            conversation.messages[index] = message
        } else { conversation.append(message) }
        persist()

        var requestService = service
        if !injectedService && service.isConfigured {
            let configuration = AISettingsStore.configuration
            if configuration.includeKeyframeImages ?? true {
                preparationLabel = "正在准备挥杆分析…"
                do {
                    let images = try await AIKeyframeImages.load(swing: swing, videoURL: store.videoURL(for: swing))
                    try Task.checkCancellation()
                    requestService = LLMChatService(configuration: configuration, apiKey: AISettingsStore.key(configuration), images: images)
                    preparationLabel = "教练正在查看你的动作…"
                } catch {
                    conversation.updateStatus(messageID: message.id, to: Task.isCancelled ? .cancelled : .failed)
                    conversation.append(ChatMessage(role: .system, kind: .statusNotice,
                        content: Task.isCancelled ? "已停止生成。" : "暂时无法分析这段动作，请重试或重新选择挥杆片段。", status: .delivered))
                    persist()
                    return
                }
            } else { preparationLabel = "教练正在分析…" }
        }
        for await event in requestService.send(message: message,
                                        conversation: conversation,
                                        context: context,
                                        options: ChatRequestOptions(timeout: 120, maxRetries: 0, contextTokenLimit: 128_000)).mapErrorToEvents() {
            switch event {
            case .failed(let error):
                conversation.updateStatus(messageID: message.id, to: error == .cancelled ? .cancelled : .failed)
                // The only reply v1 can honestly produce: a status notice.
                let notice = error == .notConfigured
                    ? ChatMessage.notConnectedNotice(analysisVersion: swing.analysisVersion)
                    : ChatMessage(role: .system, kind: .statusNotice, content: error.messageZH,
                                  status: .delivered, producedWhileUnconfigured: !service.isConfigured)
                conversation.append(notice)
            case .finished(let reply):
                conversation.append(reply)
            case .started, .delta, .reference:
                break
            }
        }
        if Task.isCancelled {
            conversation.updateStatus(messageID: message.id, to: .cancelled)
            conversation.append(ChatMessage(role: .system, kind: .statusNotice, content: "已停止生成。", status: .delivered))
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
            let task = Task {
                do {
                    for try await event in self { continuation.yield(event) }
                } catch let error as ChatServiceError {
                    continuation.yield(.failed(error))
                } catch {
                    continuation.yield(.failed(.transport(error.localizedDescription)))
                }
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}
