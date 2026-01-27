//
//  AIProviderFactory.swift
//  meetingnotes
//
//  Factory for creating AI provider instances
//

import Foundation

/// Factory class for creating provider instances
class AIProviderFactory {
    /// Create a transcription provider for the specified type
    /// - Parameter type: The AI provider type
    /// - Returns: A transcription provider instance
    static func createTranscriptionProvider(for type: AIProviderType) -> TranscriptionProvider {
        switch type {
        case .openai:
            return OpenAITranscriptionProvider()
        case .gemini:
            return GeminiTranscriptionProvider()
        case .claude:
            // Claude doesn't support transcription, use OpenAI as fallback
            return OpenAITranscriptionProvider()
        }
    }

    /// Create a note generation provider for the specified type
    /// - Parameter type: The AI provider type
    /// - Returns: A note generation provider instance
    static func createNotesGenerationProvider(for type: AIProviderType) -> NotesGenerationProvider {
        switch type {
        case .openai:
            return OpenAINotesGenerator()
        case .gemini:
            return GeminiNotesGenerator()
        case .claude:
            return ClaudeNotesGenerator()
        }
    }
}
