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
    @State private var testing = false
    var body: some View {
        NavigationStack {
            Form {
                Section("模型服务") {
                    Picker("服务商", selection: $configuration.provider) {
                        ForEach(LLMProvider.allCases, id: \.self) { Text($0.name).tag($0) }
                    }
                    TextField("API 基础地址", text: $configuration.baseURL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    TextField("模型 ID（按服务商控制台填写）", text: $configuration.model)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    if configuration.provider == .deepSeek {
                        HStack {
                            Button("Flash 快速模型") { configuration.model = "deepseek-flash" }
                            Button("Pro 模型") { configuration.model = "deepseek-v4-pro" }
                        }.font(.caption)
                        Toggle("深入分析（较慢）", isOn: Binding(get: { configuration.deepSeekThinking ?? false },
                            set: { configuration.deepSeekThinking = $0 }))
                        Text("默认 Flash + 快速解读；深入分析会增加等待时间与用量。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    SecureField("API Key", text: $key)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Section {
                    Button("保存并返回") {
                        do { try AISettingsStore.save(configuration, key: key); status = "配置已保存，可返回 AI 教练提问。"; dismiss() }
                        catch { status = describe(error) }
                    }.disabled(testing)
                    Button {
                        testing = true
                        Task { await testConnection() }
                    } label: {
                        HStack { Text("测试连接"); if testing { ProgressView() } }
                    }.disabled(testing)
                    Button("删除此接口的 API Key", role: .destructive) {
                        do { try AISettingsStore.remove(configuration); key = ""; status = "API Key 已删除。" }
                        catch { status = describe(error) }
                    }.disabled(testing)
                    if !status.isEmpty { Text(status).font(.footnote).textSelection(.enabled) }
                } footer: {
                    Text("密钥仅存于本机钥匙串。发送问题时会将当前挥杆分析数据及最近聊天记录发送到上方地址，由该服务商处理；不上传视频。测试连接只发送一句测试消息，可能产生少量 API 费用。")
                }
            }
            .navigationTitle("AI 接口设置")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .onAppear { key = AISettingsStore.key(configuration) }
            .onChange(of: configuration.provider) { _, provider in
                configuration.baseURL = provider.baseURL
                configuration.model = provider == .deepSeek ? "deepseek-flash" : ""
                key = ""; status = ""
            }
            .onChange(of: configuration.baseURL) { _, _ in key = ""; status = "" }
        }
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
            status = received ? "连接成功，模型已返回回答。请点击保存配置。" : "未收到模型回答。"
        } catch { status = describe(error) }
    }
}
