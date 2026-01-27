// NotesGenerator.swift
// Handles AI-powered note generation using provider pattern

import Foundation
import OpenAI

/// Result type for note generation streaming
enum GenerationResult {
    case content(String)
    case error(String)
}

/// Generates meeting notes using AI providers
class NotesGenerator {
    static let shared = NotesGenerator()

    private init() {}

    /// Generates meeting notes from meeting data using template-based system prompt with streaming
    /// - Parameters:
    ///   - meeting: The meeting object containing all necessary data
    ///   - userBlurb: Information about the user for context
    ///   - systemPrompt: The system prompt template with placeholders
    ///   - templateId: Optional template ID to use for generating notes
    /// - Returns: AsyncStream of partial generated notes
    func generateNotesStream(meeting: Meeting,
                            userBlurb: String,
                            systemPrompt: String,
                            templateId: UUID? = nil) -> AsyncStream<GenerationResult> {

        // Get selected provider and create notes generation provider
        let providerType = UserDefaultsManager.shared.selectedProvider
        let provider = AIProviderFactory.createNotesGenerationProvider(for: providerType)

        // Delegate to provider
        return provider.generateNotesStream(
            meeting: meeting,
            userBlurb: userBlurb,
            systemPrompt: systemPrompt,
            templateId: templateId
        )
    }

    /// Validates if API key is configured for the selected provider
    /// - Returns: True if API key exists, false otherwise
    func isConfigured() -> Bool {
        let providerType = UserDefaultsManager.shared.selectedProvider

        // For Claude, check both OpenAI (for transcription) and Claude keys
        if providerType == .claude {
            let openAIKey = KeychainHelper.shared.getAPIKey(for: .openai)
            let claudeKey = KeychainHelper.shared.getAPIKey(for: .claude)
            return !(openAIKey?.isEmpty ?? true) && !(claudeKey?.isEmpty ?? true)
        }

        // For other providers, check their specific key
        guard let key = KeychainHelper.shared.getAPIKey(for: providerType),
              !key.isEmpty else {
            return false
        }
        return true
    }
} 