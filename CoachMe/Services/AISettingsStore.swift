import Foundation
import Security
import AICoach

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
    /// The chat service for the saved configuration and its key.
    static func service(images: [LLMFrameImage] = []) -> LLMChatService {
        let config = configuration
        return service(configuration: config, apiKey: key(config), images: images)
    }
    /// A service for a configuration that may not be saved yet, such as the one being tested in settings.
    static func service(configuration: LLMConfiguration, apiKey: String, images: [LLMFrameImage] = []) -> LLMChatService {
        LLMChatService(configuration: configuration, apiKey: apiKey, images: images)
    }
}
