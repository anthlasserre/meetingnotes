//
//  NotesGenerationProvider.swift
//  meetingnotes
//
//  Protocol for AI-powered note generation providers
//

import Foundation

/// Protocol that all note generation providers must implement
protocol NotesGenerationProvider {
    /// Generate meeting notes from meeting data with streaming support
    /// - Parameters:
    ///   - meeting: The meeting object containing transcript and metadata
    ///   - userBlurb: Information about the user for context
    ///   - systemPrompt: The system prompt template with placeholders
    ///   - templateId: Optional template ID to use for generating notes
    /// - Returns: AsyncStream of generation results (content chunks or errors)
    func generateNotesStream(
        meeting: Meeting,
        userBlurb: String,
        systemPrompt: String,
        templateId: UUID?
    ) -> AsyncStream<GenerationResult>

    /// Validate the API key for this provider
    /// - Parameter apiKey: The API key to validate
    /// - Returns: Result indicating success or failure with error details
    func validateAPIKey(_ apiKey: String) async -> Result<Void, Error>
}
