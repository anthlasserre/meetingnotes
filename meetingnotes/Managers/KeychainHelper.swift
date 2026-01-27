// KeychainHelper.swift
// Secure storage helper for API keys and sensitive data

import Foundation
import Security

/// Manages secure storage of sensitive data using the macOS Keychain
class KeychainHelper {
    static let shared = KeychainHelper()
    
    private let serviceName = "owen.meetingnotes"
    
    private init() {}
    
    /// Gets the API key directly from keychain (legacy OpenAI key)
    /// - Returns: The API key string if found, nil otherwise
    func getAPIKey() -> String? {
        return get(forKey: "openAIKey")
    }

    /// Saves the API key to keychain (legacy OpenAI key)
    /// - Parameter apiKey: The API key to save
    /// - Returns: True if the save was successful, false otherwise
    func saveAPIKey(_ apiKey: String) -> Bool {
        return save(apiKey, forKey: "openAIKey")
    }

    // MARK: - Multi-Provider API Key Management

    /// Gets the API key for a specific provider
    /// - Parameter provider: The AI provider type
    /// - Returns: The API key string if found, nil otherwise
    func getAPIKey(for provider: AIProviderType) -> String? {
        let key = keychainKey(for: provider)
        return get(forKey: key)
    }

    /// Saves the API key for a specific provider
    /// - Parameters:
    ///   - apiKey: The API key to save
    ///   - provider: The AI provider type
    /// - Returns: True if the save was successful, false otherwise
    func saveAPIKey(_ apiKey: String, for provider: AIProviderType) -> Bool {
        let key = keychainKey(for: provider)
        return save(apiKey, forKey: key)
    }

    /// Deletes the API key for a specific provider
    /// - Parameter provider: The AI provider type
    /// - Returns: True if the deletion was successful, false otherwise
    func deleteAPIKey(for provider: AIProviderType) -> Bool {
        let key = keychainKey(for: provider)
        return delete(forKey: key)
    }

    /// Gets all providers that have API keys configured
    /// - Returns: Array of provider types with stored keys
    func getAllConfiguredProviders() -> [AIProviderType] {
        return AIProviderType.allCases.filter { provider in
            getAPIKey(for: provider) != nil
        }
    }

    /// Generates the keychain key for a provider
    /// - Parameter provider: The AI provider type
    /// - Returns: The keychain key string
    private func keychainKey(for provider: AIProviderType) -> String {
        return "provider.\(provider.rawValue.lowercased()).apiKey"
    }
    
    /// Saves a string value to the keychain
    /// - Parameters:
    ///   - value: The string value to save
    ///   - key: The key to save the value under
    /// - Returns: True if the save was successful, false otherwise
    func save(_ value: String, forKey key: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrService as String: serviceName
        ]
        
        // Delete any existing item
        SecItemDelete(query as CFDictionary)
        
        // Add the new item
        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }
    
    /// Retrieves a string value from the keychain
    /// - Parameter key: The key to retrieve the value for
    /// - Returns: The string value if found, nil otherwise
    func get(forKey key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: serviceName,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true
        ]
        
        var item: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    
    /// Deletes a value from the keychain
    /// - Parameter key: The key to delete
    /// - Returns: True if the deletion was successful, false otherwise
    func delete(forKey key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: serviceName
        ]
        
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess
    }
} 