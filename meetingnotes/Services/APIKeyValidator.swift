// APIKeyValidator.swift
// Service to validate API keys for multiple AI providers

import Foundation

/// Service to validate API keys for multiple AI providers
class APIKeyValidator {
    static let shared = APIKeyValidator()
    
    private init() {}
    
    /// Validates an API key for a specific provider
    /// - Parameters:
    ///   - apiKey: The API key to validate
    ///   - provider: The AI provider type
    /// - Returns: Result indicating success or failure with error message
    func validateAPIKey(_ apiKey: String, for provider: AIProviderType) async -> Result<Void, APIKeyValidationError> {
        guard !apiKey.isEmpty else {
            return .failure(.emptyKey)
        }
        
        switch provider {
        case .openai:
            return await validateOpenAIKey(apiKey)
        case .gemini:
            return await validateGeminiKey(apiKey)
        case .claude:
            return await validateClaudeKey(apiKey)
        }
    }
    
    /// Validates the OpenAI API key by making a test request
    /// - Parameter apiKey: The API key to validate
    /// - Returns: Result indicating success or failure with error message
    private func validateOpenAIKey(_ apiKey: String) async -> Result<Void, APIKeyValidationError> {
        guard let url = URL(string: "https://api.openai.com/v1/models") else {
            return .failure(.invalidURL)
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                return .failure(.networkError("Invalid response"))
            }
            
            switch httpResponse.statusCode {
            case 200:
                // Key is valid - check if models are available
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let models = json["data"] as? [[String: Any]], !models.isEmpty {
                    return .success(())
                } else {
                    return .failure(.noModelsAvailable)
                }
            default:
                let errorMessage = ErrorHandler.shared.handleHTTPStatusCode(httpResponse.statusCode, provider: .openai)
                return .failure(.httpError(errorMessage))
            }
        } catch {
            let errorMessage = ErrorHandler.shared.handleError(error)
            return .failure(.networkError(errorMessage))
        }
    }
    
    /// Validates the Gemini API key by making a test request
    /// - Parameter apiKey: The API key to validate
    /// - Returns: Result indicating success or failure with error message
    private func validateGeminiKey(_ apiKey: String) async -> Result<Void, APIKeyValidationError> {
        // Gemini uses query parameter for API key
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1/models?key=\(apiKey)") else {
            return .failure(.invalidURL)
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                return .failure(.networkError("Invalid response"))
            }
            
            switch httpResponse.statusCode {
            case 200:
                // Key is valid - check if models are available
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let models = json["models"] as? [[String: Any]], !models.isEmpty {
                    return .success(())
                } else {
                    return .failure(.noModelsAvailable)
                }
            default:
                let errorMessage = ErrorHandler.shared.handleHTTPStatusCode(httpResponse.statusCode, provider: .gemini)
                return .failure(.httpError(errorMessage))
            }
        } catch {
            let errorMessage = ErrorHandler.shared.handleError(error)
            return .failure(.networkError(errorMessage))
        }
    }
    
    /// Validates the Claude API key by making a test request
    /// - Parameter apiKey: The API key to validate
    /// - Returns: Result indicating success or failure with error message
    private func validateClaudeKey(_ apiKey: String) async -> Result<Void, APIKeyValidationError> {
        // Claude uses messages endpoint - we'll make a minimal request to validate
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else {
            return .failure(.invalidURL)
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        
        // Minimal request body for validation
        let requestBody: [String: Any] = [
            "model": "claude-3-5-sonnet-20241022",
            "max_tokens": 1,
            "messages": [["role": "user", "content": "test"]]
        ]
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
            
            let (_, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                return .failure(.networkError("Invalid response"))
            }
            
            switch httpResponse.statusCode {
            case 200, 400: // 400 might be returned for invalid request but with valid auth
                // If we get 400, check if it's an auth error or just a bad request
                if httpResponse.statusCode == 400 {
                    // For validation purposes, 400 with valid auth headers means key is likely valid
                    return .success(())
                }
                return .success(())
            case 401:
                let errorMessage = ErrorHandler.shared.handleHTTPStatusCode(401, provider: .claude)
                return .failure(.httpError(errorMessage))
            default:
                let errorMessage = ErrorHandler.shared.handleHTTPStatusCode(httpResponse.statusCode, provider: .claude)
                return .failure(.httpError(errorMessage))
            }
        } catch {
            let errorMessage = ErrorHandler.shared.handleError(error)
            return .failure(.networkError(errorMessage))
        }
    }
    
    /// Validates the currently stored API key for the selected provider
    /// - Returns: Result indicating success or failure with error message
    func validateCurrentAPIKey() async -> Result<Void, APIKeyValidationError> {
        let provider = UserDefaultsManager.shared.selectedProvider
        
        // For Claude, we need to check both OpenAI (for transcription) and Claude keys
        if provider == .claude {
            let openAIKey = KeychainHelper.shared.getAPIKey(for: .openai)
            let claudeKey = KeychainHelper.shared.getAPIKey(for: .claude)
            
            guard let openAIKey = openAIKey, !openAIKey.isEmpty else {
                return .failure(.emptyKey)
            }
            guard let claudeKey = claudeKey, !claudeKey.isEmpty else {
                return .failure(.emptyKey)
            }
            
            // Validate both keys
            let openAIResult = await validateOpenAIKey(openAIKey)
            if case .failure = openAIResult {
                return openAIResult
            }
            
            return await validateClaudeKey(claudeKey)
        }
        
        // For other providers, validate their specific key
        guard let apiKey = KeychainHelper.shared.getAPIKey(for: provider) else {
            return .failure(.emptyKey)
        }
        
        return await validateAPIKey(apiKey, for: provider)
    }
    
    /// Legacy method for backward compatibility - validates OpenAI key
    /// - Parameter apiKey: The API key to validate
    /// - Returns: Result indicating success or failure with error message
    func validateAPIKey(_ apiKey: String) async -> Result<Void, APIKeyValidationError> {
        return await validateAPIKey(apiKey, for: .openai)
    }
}

/// Errors that can occur during API key validation
enum APIKeyValidationError: Error, LocalizedError {
    case emptyKey
    case invalidURL
    case noModelsAvailable
    case networkError(String)
    case httpError(String)
    
    var errorDescription: String? {
        switch self {
        case .emptyKey:
            return ErrorMessage.noAPIKey
        case .invalidURL:
            return ErrorMessage.invalidURL
        case .noModelsAvailable:
            return ErrorMessage.noModelsAvailable
        case .networkError(let message):
            return message
        case .httpError(let message):
            return message
        }
    }
}