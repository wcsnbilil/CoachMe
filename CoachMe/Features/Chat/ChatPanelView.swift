import SwiftUI
import CoachMeCore

/// Multi-provider chat with local conversation history.
@MainActor
struct ChatPanelView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SwingLibrary.self) private var library
    @State private var model: ChatModel
    @State private var draft = ""
    @State private var showingSettings = false
    @State private var requestTask: Task<Void, Never>?
    @FocusState private var inputFocused: Bool
    private let initialQuestion: String?
    private let onJump: ((Double) -> Void)?

    static let quickQuestions = ["这次挥杆优先看哪里？", "解释这个角度", "下一次怎么练？"]

    init(swing: SwingRecord, phase: SwingPhase?, timestamp: Double, context: SwingAnalysisContext,
         onJump: ((Double) -> Void)? = nil, initialQuestion: String? = nil) {
        _model = State(initialValue: ChatModel(swing: swing, phase: phase,
                                               timestamp: timestamp, context: context))
        self.onJump = onJump
        self.initialQuestion = initialQuestion
        _draft = State(initialValue: initialQuestion ?? "")
    }

    private var providerName: String { AISettingsStore.configuration.provider.name }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                    .padding(.horizontal, 18)
                    .padding(.top, 6)
                    .padding(.bottom, 10)
                messageList
                composer
            }
            .background(CoachStyle.background)
            .navigationTitle("AI 教练")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(CoachStyle.background, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "chevron.left")
                            Text("返回视频")
                        }
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("设置") { showingSettings = true }.disabled(model.isSending)
                }
            }
        }
        .sheet(isPresented: $showingSettings, onDismiss: { model.reloadConfiguration() }) { AISettingsView() }
        .onDisappear { requestTask?.cancel() }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                VideoFrameImage(url: library.videoURL(for: model.swing), time: model.timestamp)
                    .frame(width: 40, height: 50)
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.swing.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(discussing)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(CoachStyle.textSecondary)
                }
                Spacer(minLength: 0)
                StatusTag(status: model.isConfigured ? .confirmed : .unmarked,
                          text: model.isConfigured ? providerName : "未配置")
            }
            .padding(8)
            .padding(.trailing, 4)
            .background(CoachStyle.surface, in: RoundedRectangle(cornerRadius: 16))
            FootnoteLine(symbol: "lock", text: notice).padding(.horizontal, 4)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var discussing: String {
        guard let phase = model.phase else { return "讨论整次挥杆" }
        return "讨论中：\(phase.nameZH) · " + String(format: "%.2f 秒", model.timestamp - model.swing.clipStartSeconds)
    }

    /// Says exactly what stays on the phone and what goes to the chosen service.
    private var notice: String {
        guard model.isConfigured else { return "角度分析在本机完成。尚未配置 AI 服务，不会发送任何数据。" }
        return "提问时，本次挥杆资料会发送给 \(providerName)。可在设置中查看和调整发送内容。"
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if model.conversation.messages.isEmpty {
                        if model.isConfigured { welcomeCard } else { unconfiguredCard }
                    }
                    ForEach(model.conversation.messages) { message in
                        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 6) {
                            MessageBubble(message: message, providerName: providerName,
                                          videoURL: library.videoURL(for: model.swing),
                                          clipStart: model.swing.clipStartSeconds, onJump: onJump)
                            if let version = message.analysisVersion, version != model.swing.analysisVersion {
                                Text("此消息基于较早的关键帧/分析版本")
                                    .font(.caption2)
                                    .foregroundStyle(CoachStyle.textTertiary)
                            }
                            if message.role == .user && (message.status == .failed || message.status == .cancelled) {
                                Button("重试这个问题") { requestTask = Task { await model.retry(message) } }
                                    .font(.footnote.weight(.semibold))
                                    .frame(minHeight: 32)
                                    .disabled(model.isSending || !model.isConfigured)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
                        .id(message.id)
                    }
                    if model.isSending { typingRow.id("typing") }
                    Color.clear.frame(height: 1).id("conversation-bottom")
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
            }
            .scrollDismissesKeyboard(.interactively)
            .defaultScrollAnchor(.bottom)
            .onChange(of: model.conversation.messages.count) { _, _ in
                withAnimation { proxy.scrollTo("conversation-bottom", anchor: .bottom) }
            }
            .onChange(of: model.isSending) { _, _ in
                withAnimation { proxy.scrollTo("conversation-bottom", anchor: .bottom) }
            }
            .onChange(of: inputFocused) { _, focused in
                if focused { withAnimation { proxy.scrollTo("conversation-bottom", anchor: .bottom) } }
            }
        }
    }

    private var welcomeCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("今天，先改进一点。").font(.system(.title2, design: .serif, weight: .semibold))
            Text("一起看看这次挥杆，找到值得保留的动作，和下一次可以练习的重点。")
                .font(.subheadline)
                .foregroundStyle(CoachStyle.textSecondary)
                .lineSpacing(4)
            Button { ask("请像面对面带课一样看看我的挥杆，告诉我最值得调整的一两点，以及下一次该怎么练。") } label: {
                Label("解读这次挥杆", systemImage: "sparkles")
            }
            .buttonStyle(CoachPrimaryButton(height: 48))
            .disabled(model.isSending)
        }
        .coachCard(padding: 20)
        .padding(.top, 8)
    }

    private var unconfiguredCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "sparkles")
                .font(.title3)
                .foregroundStyle(CoachStyle.forest)
                .frame(width: 44, height: 44)
                .background(CoachStyle.confirmedFill, in: RoundedRectangle(cornerRadius: 14))
            Text("AI 教练尚未配置").font(.system(.title2, design: .serif, weight: .semibold))
            Text("视频、骨架和角度都在本机分析，不受影响。配置 AI 服务后，提问时才会把本次挥杆资料发送给你选择的服务商。")
                .font(.subheadline)
                .foregroundStyle(CoachStyle.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("配置 AI 服务") { showingSettings = true }
                .buttonStyle(CoachPrimaryButton(height: 50))
            Text("支持 OpenAI、Claude、Gemini、DeepSeek 及兼容接口，需要你自己的 API Key。")
                .font(.caption)
                .foregroundStyle(CoachStyle.textTertiary)
        }
        .coachCard(padding: 20)
        .padding(.top, 8)
    }

    private var typingRow: some View {
        HStack(spacing: 12) {
            TypingDots()
            Text(model.preparationLabel).font(.subheadline).foregroundStyle(CoachStyle.textSecondary)
            Button("停止") { requestTask?.cancel() }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(CoachStyle.text)
                .padding(.horizontal, 10)
                .frame(minHeight: 32)
                .background(CoachStyle.fill, in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(12)
        .background(CoachStyle.surface,
                    in: UnevenRoundedRectangle(topLeadingRadius: 6, bottomLeadingRadius: 20,
                                               bottomTrailingRadius: 20, topTrailingRadius: 20))
    }

    private var composer: some View {
        VStack(spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Self.quickQuestions, id: \.self) { question in
                        Button(question) { ask(question) }
                            .font(.subheadline)
                            .foregroundStyle(CoachStyle.text)
                            .padding(.horizontal, 12)
                            .frame(minHeight: 36)
                            .background(CoachStyle.surface, in: Capsule())
                            .overlay(Capsule().strokeBorder(CoachStyle.line, lineWidth: 1))
                    }
                }
                .padding(.horizontal, 18)
            }
            .opacity(model.isConfigured ? 1 : 0.45)
            .disabled(model.isSending)

            HStack(alignment: .bottom, spacing: 8) {
                TextField(model.isConfigured ? "问问这次挥杆…" : "配置 AI 服务后可提问", text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 13)
                    .background(CoachStyle.surface, in: RoundedRectangle(cornerRadius: 24))
                    .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(CoachStyle.line, lineWidth: 1))
                    .focused($inputFocused)
                    .disabled(!model.isConfigured)
                    .accessibilityLabel("提问输入框")
                Button { sendDraft() } label: {
                    Image(systemName: "arrow.up")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 48, height: 48)
                        .background(CoachStyle.forest.opacity(canSend ? 1 : 0.35), in: Circle())
                }
                .disabled(!canSend)
                .accessibilityLabel("发送")
            }
            .padding(.horizontal, 18)
        }
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(CoachStyle.background.overlay(alignment: .top) {
            Rectangle().fill(CoachStyle.line).frame(height: 1)
        })
    }

    private var canSend: Bool {
        model.isConfigured && !model.isSending && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func sendDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        ask(text)
    }

    private func ask(_ question: String) {
        guard model.isConfigured else { showingSettings = true; return }
        guard !model.isSending else { return }
        let resolved = question == "解释这个角度" ? (initialQuestion ?? question) : question
        requestTask = Task { await model.send(resolved) }
    }
}

/// Three dots stepping in turn while the coach is answering.
struct TypingDots: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.2)) { context in
            let step = Int(context.date.timeIntervalSinceReferenceDate * 5) % 3
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { index in
                    Circle().fill(CoachStyle.accent).frame(width: 6, height: 6).opacity(index == step ? 1 : 0.3)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

@MainActor
struct MessageBubble: View {
    let message: ChatMessage
    var providerName = ""
    var videoURL: URL?
    var clipStart: Double = 0
    var onJump: ((Double) -> Void)?

    var body: some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
            switch message.kind {
            case .statusNotice:
                // Visually and structurally distinct from a model answer.
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Image(systemName: "info.circle")
                        Spacer()
                        Text("系统状态").font(.caption2).foregroundStyle(CoachStyle.textTertiary)
                    }
                    .font(.footnote.weight(.semibold))
                    Text(message.content)
                        .font(.footnote)
                        .foregroundStyle(CoachStyle.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(CoachStyle.neutralFill, in: RoundedRectangle(cornerRadius: 16))

            case .developmentPreview:
                VStack(alignment: .leading, spacing: 4) {
                    Label("开发预览示例（非真实分析）", systemImage: "hammer").font(.caption2.bold())
                    Text(message.content).font(.footnote)
                }
                .padding(10)
                .background(CoachStyle.pendingFill, in: RoundedRectangle(cornerRadius: 10))

            case .text:
                if message.role == .user {
                    Text(message.content)
                        .font(.body)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 15)
                        .padding(.vertical, 11)
                        .background(CoachStyle.forest,
                                    in: UnevenRoundedRectangle(topLeadingRadius: 20, bottomLeadingRadius: 20,
                                                               bottomTrailingRadius: 6, topTrailingRadius: 20))
                        .frame(maxWidth: 300, alignment: .trailing)
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("AI 教练", systemImage: "sparkle")
                            .font(.caption2.weight(.bold))
                            .kerning(1)
                            .foregroundStyle(CoachStyle.accent)
                        Text(.init(message.content))
                            .font(.body)
                            .lineSpacing(5)
                            .foregroundStyle(CoachStyle.text)
                            .textSelection(.enabled)
                        ForEach(Array(references.enumerated()), id: \.offset) { _, reference in
                            referenceCard(reference)
                        }
                        Text("由 \(providerName.isEmpty ? "AI 服务" : providerName) 根据本次分析数据生成 · 可能有误，请结合画面判断")
                            .font(.caption2)
                            .foregroundStyle(CoachStyle.textTertiary)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(CoachStyle.surface,
                                in: UnevenRoundedRectangle(topLeadingRadius: 6, bottomLeadingRadius: 20,
                                                           bottomTrailingRadius: 20, topTrailingRadius: 20))
                }
            }

            if message.status == .failed {
                Label("未收到回答", systemImage: "exclamationmark.circle")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(CoachStyle.alert)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// References that point at a frame, one card per distinct time.
    private var references: [ChatReference] {
        var seen = Set<Double>()
        return message.references.filter { reference in
            guard let time = reference.timestampSeconds, !seen.contains(time) else { return false }
            seen.insert(time)
            return true
        }
    }

    private func referenceCard(_ reference: ChatReference) -> some View {
        let time = reference.timestampSeconds ?? clipStart
        return Button { onJump?(time) } label: {
            HStack(spacing: 12) {
                Group {
                    if let videoURL { VideoFrameImage(url: videoURL, time: time) } else { CoachStyle.stage }
                }
                .frame(width: 52, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(alignment: .bottomLeading) {
                    Text(String(format: "%.2fs", time - clipStart))
                        .font(.system(size: 10, weight: .bold).monospacedDigit())
                        .foregroundStyle(Color(hex: 0x10170F))
                        .padding(.horizontal, 3)
                        .background(CoachStyle.limeOnDark, in: RoundedRectangle(cornerRadius: 4))
                        .padding(4)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(reference.phase?.nameZH ?? "引用画面")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(CoachStyle.text)
                    if let metric = reference.metricID {
                        Text(MetricCatalog.definition(for: metric).nameZH)
                            .font(.caption)
                            .foregroundStyle(CoachStyle.textSecondary)
                    }
                    if onJump != nil {
                        HStack(spacing: 2) {
                            Text("回到此帧")
                            Image(systemName: "chevron.right").font(.caption2.weight(.bold))
                        }
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(CoachStyle.accent)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .background(CoachStyle.background, in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .disabled(onJump == nil)
    }
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
