import SwiftUI
import Security
import CoachMeCore

@MainActor
enum AISettingsStore {
    static var configuration: LLMConfiguration {
        guard let data = UserDefaults.standard.data(forKey: "llm.configuration"),
              let config = try? JSONDecoder().decode(LLMConfiguration.self, from: data) else { return .init() }
        return config
    }
    static func key(_ config: LLMConfiguration) -> String {
        var query = keyQuery(config)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
    private static func keyQuery(_ config: LLMConfiguration) -> [String:Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.coachme.llm",
         kSecAttrAccount as String: config.provider.rawValue + "|" + config.baseURL]
    }
    static func save(_ config: LLMConfiguration, key: String) throws {
        _ = try config.endpoint()
        let query = keyQuery(config)
        let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw ChatServiceError.notConfigured }
        let changes: [String:Any] = [kSecValueData as String: Data(value.utf8),
                                    kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, changes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(changes) { _,new in new } as CFDictionary,nil)
        }
        guard status == errSecSuccess else { throw ChatServiceError.transport("无法保存 API Key 到钥匙串。") }
        UserDefaults.standard.set(try JSONEncoder().encode(config), forKey: "llm.configuration")
    }
    static func remove(_ config: LLMConfiguration) throws {
        let status = SecItemDelete(keyQuery(config) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ChatServiceError.transport("无法删除 API Key。")
        }
    }
    static func service() -> LLMChatService {
        let config = configuration
        return LLMChatService(configuration: config, apiKey: key(config))
    }
}

@MainActor
struct AISettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var configuration = AISettingsStore.configuration
    @State private var key = ""
    @State private var status = ""
    @State private var statusIsError = false
    @State private var testing = false
    @State private var revealKey = false
    @State private var showingAdvanced = false

    private var sendsImages: Bool { configuration.includeKeyframeImages ?? true }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel("服务商")
                    FlowLayout(spacing: 8) {
                        ForEach(LLMProvider.allCases, id: \.self) { provider in
                            ChoiceChip(title: provider.name, selected: configuration.provider == provider) {
                                configuration.provider = provider
                            }
                        }
                    }

                    SectionLabel("连接").padding(.top, 14)
                    connection

                    Button {
                        testing = true
                        Task { await testConnection() }
                    } label: {
                        HStack(spacing: 8) {
                            if testing { ProgressView().controlSize(.small) }
                            Text("测试连接")
                        }
                    }
                    .buttonStyle(CoachSecondaryButton(height: 48))
                    .disabled(testing)
                    .padding(.top, 6)

                    if !status.isEmpty {
                        Label(status, systemImage: statusIsError ? "exclamationmark.triangle" : "checkmark.circle.fill")
                            .font(.footnote)
                            .foregroundStyle(statusIsError ? CoachStyle.alert : CoachStyle.confirmed)
                            .textSelection(.enabled)
                            .padding(.horizontal, 4)
                    }

                    SectionLabel("数据会去哪里").padding(.top, 14)
                    dataFlow

                    advanced.padding(.top, 14)

                    Button("删除此服务的 API Key", role: .destructive) {
                        do {
                            try AISettingsStore.remove(configuration)
                            key = ""
                            status = "API Key 已删除。"
                            statusIsError = false
                        } catch { status = describe(error); statusIsError = true }
                    }
                    .buttonStyle(CoachSecondaryButton(height: 50, tint: CoachStyle.alert))
                    .disabled(testing)
                    .padding(.top, 14)
                }
                .padding(.horizontal, 18)
                .padding(.top, 4)
                .padding(.bottom, 32)
            }
            .background(CoachStyle.background)
            .navigationTitle("AI 教练服务")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(CoachStyle.background, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        do {
                            try AISettingsStore.save(configuration, key: key)
                            dismiss()
                        } catch { status = describe(error); statusIsError = true }
                    }
                    .fontWeight(.semibold)
                    .disabled(testing)
                }
            }
            .onAppear { key = AISettingsStore.key(configuration) }
            .onChange(of: configuration.provider) { _, provider in
                configuration.baseURL = provider.baseURL
                configuration.model = provider == .deepSeek ? "deepseek-flash" : ""
                key = ""; status = ""; revealKey = false
            }
            .onChange(of: configuration.baseURL) { _, _ in key = ""; status = "" }
        }
    }

    private var connection: some View {
        VStack(spacing: 0) {
            if configuration.provider == .compatible {
                field("接口地址（必填）") {
                    TextField("https://your-endpoint.example/v1", text: $configuration.baseURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                }
                GroupDivider()
            }
            field("模型") {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("按服务商控制台填写模型 ID", text: $configuration.model)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                    if configuration.provider == .deepSeek {
                        HStack(spacing: 6) {
                            ChoiceChip(title: "Flash 快速", selected: configuration.model == "deepseek-flash", showsCheck: false) {
                                configuration.model = "deepseek-flash"
                            }
                            ChoiceChip(title: "Pro", selected: configuration.model == "deepseek-v4-pro", showsCheck: false) {
                                configuration.model = "deepseek-v4-pro"
                            }
                        }
                    }
                }
            }
            GroupDivider()
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("API Key").font(.footnote).foregroundStyle(CoachStyle.textTertiary)
                    Group {
                        if revealKey {
                            TextField("粘贴你的 API Key", text: $key)
                        } else {
                            SecureField("粘贴你的 API Key", text: $key)
                        }
                    }
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
                }
                Button { revealKey.toggle() } label: {
                    Image(systemName: revealKey ? "eye.slash" : "eye")
                        .foregroundStyle(CoachStyle.textSecondary)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(revealKey ? "隐藏 API Key" : "显示 API Key")
            }
            .padding(.leading, 16)
            .padding(.trailing, 8)
            .padding(.top, 10)
            Text("仅保存在本机钥匙串，不会同步或上传到 CoachMe。")
                .font(.caption)
                .foregroundStyle(CoachStyle.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            GroupDivider()
            VStack(alignment: .leading, spacing: 4) {
                Toggle("附带关键帧截图", isOn: Binding(get: { sendsImages },
                                                   set: { configuration.includeKeyframeImages = $0 }))
                    .tint(CoachStyle.accent)
                Text(sendsImages
                     ? "提问时附带最多 30 张原视频截图，不上传完整视频。需选择支持图像输入的模型。"
                     : "只发送角度数据与文字，AI 教练看不到画面。")
                    .font(.caption)
                    .foregroundStyle(CoachStyle.textTertiary)
            }
            .padding(16)
        }
        .coachGroup()
    }

    private var dataFlow: some View {
        VStack(spacing: 0) {
            flowRow(symbol: "iphone", tint: CoachStyle.forest, fill: CoachStyle.confirmedFill,
                    title: "只在本机",
                    text: "完整视频、姿态识别、关键帧识别、角度计算与规则对照。")
            GroupDivider(inset: 0)
            flowRow(symbol: "icloud.and.arrow.up", tint: CoachStyle.textSecondary, fill: CoachStyle.neutralFill,
                    title: "提问时发送给 " + (configuration.provider == .compatible ? "你填写的接口" : configuration.provider.name),
                    text: "本次角度数据、关键帧复核状态、适用的规则范围、提问与最近对话\(sendsImages ? "，以及最多 30 张关键帧截图" : "")；不上传完整视频。测试连接只发送一句测试消息，可能产生少量 API 费用。")
        }
        .padding(.horizontal, 16)
        .coachGroup()
    }

    private func flowRow(symbol: String, tint: Color, fill: Color, title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.subheadline)
                .foregroundStyle(tint)
                .frame(width: 32, height: 32)
                .background(fill, in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(text)
                    .font(.footnote)
                    .foregroundStyle(CoachStyle.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
    }

    private var advanced: some View {
        VStack(spacing: 0) {
            Button { withAnimation(.snappy) { showingAdvanced.toggle() } } label: {
                HStack {
                    Text("高级设置").foregroundStyle(CoachStyle.text)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(CoachStyle.textTertiary)
                        .rotationEffect(.degrees(showingAdvanced ? 90 : 0))
                }
                .padding(.horizontal, 16)
                .frame(minHeight: 52)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if showingAdvanced {
                if configuration.provider != .compatible {
                    GroupDivider()
                    field("API 基础地址") {
                        TextField("API 基础地址", text: $configuration.baseURL)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.callout.monospaced())
                    }
                }
                if configuration.provider == .deepSeek {
                    GroupDivider()
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("深入分析（较慢）", isOn: Binding(get: { configuration.deepSeekThinking ?? false },
                                                           set: { configuration.deepSeekThinking = $0 }))
                            .tint(CoachStyle.accent)
                        Text("默认 Flash 快速解读；深入分析会增加等待时间与用量。")
                            .font(.caption)
                            .foregroundStyle(CoachStyle.textTertiary)
                    }
                    .padding(16)
                }
                GroupDivider()
                HStack {
                    Text("请求超时")
                    Spacer()
                    Text("120 秒").foregroundStyle(CoachStyle.textSecondary)
                }
                .padding(.horizontal, 16)
                .frame(minHeight: 50)
            }
        }
        .coachGroup()
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.footnote).foregroundStyle(CoachStyle.textTertiary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func describe(_ error: Error) -> String { (error as? ChatServiceError)?.messageZH ?? "操作失败，请检查配置。" }

    private func testConnection() async {
        defer { testing = false }
        let service = LLMChatService(configuration: configuration, apiKey: key)
        let context = SwingAnalysisContext(swingID: UUID(), analysisVersion: 0, handedness: .rightHanded,
            club: .unknown, cameraView: .unknown, markedPhases: [], selectedPhase: nil,
            selectedTimestampSeconds: nil, readings: [],
            quality: .init(framesAnalysed: 0, framesWithNoPerson: 0, framesWithMultiplePeople: 0,
                           metricsUnavailable: [], statedLimitationsZH: []), comparison: nil)
        do {
            var received = false
            for try await event in service.send(message: ChatMessage(role: .user, content: "这是接口连接测试，请只回复 OK。"),
                conversation: Conversation(swingID: context.swingID), context: context, options: ChatRequestOptions()) {
                if case .finished = event { received = true }
            }
            status = received ? "连接成功，模型已返回回答。请点击保存。" : "未收到模型回答。"
            statusIsError = !received
        } catch { status = describe(error); statusIsError = true }
    }
}
