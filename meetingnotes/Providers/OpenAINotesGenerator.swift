//
//  OpenAINotesGenerator.swift
//  meetingnotes
//
//  OpenAI notes generation provider implementation
//

import Foundation
import OpenAI

/// OpenAI notes generation provider using GPT-4
class OpenAINotesGenerator: NotesGenerationProvider {
    func generateNotesStream(
        meeting: Meeting,
        userBlurb: String,
        systemPrompt: String,
        templateId: UUID?
    ) -> AsyncStream<GenerationResult> {
        return AsyncStream<GenerationResult>(GenerationResult.self) { continuation in
            Task {
                do {
                    guard let apiKey = KeychainHelper.shared.getAPIKey(for: .openai), !apiKey.isEmpty else {
                        continuation.yield(.error(ErrorMessage.noAPIKey))
                        continuation.finish()
                        return
                    }

                    // Validate API key before proceeding
                    let validationResult = await validateAPIKey(apiKey)
                    switch validationResult {
                    case .failure(let error):
                        continuation.yield(.error(error.localizedDescription))
                        continuation.finish()
                        return
                    case .success():
                        break
                    }

                    let openAI = OpenAI(apiToken: apiKey)

                    // Create date formatter for meeting date
                    let dateFormatter = DateFormatter()
                    dateFormatter.dateStyle = .full
                    dateFormatter.timeStyle = .short

                    // Load template content
                    var templateContent = ""
                    if let templateId = templateId {
                        let templates = LocalStorageManager.shared.loadTemplates()
                        if let template = templates.first(where: { $0.id == templateId }) {
                            templateContent = template.formattedContent
                        }
                    }

                    // If no template content, use default
                    if templateContent.isEmpty {
                        continuation.yield(.error(ErrorMessage.noTemplate))
                        continuation.finish()
                        return
                    }

                    // Check if transcript is empty
                    if meeting.formattedTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        continuation.yield(.error(ErrorMessage.noTranscript))
                        continuation.finish()
                        return
                    }

                    // Prepare template variables
                    let templateVariables: [String: String] = [
                        "meeting_title": meeting.title.isEmpty ? "Untitled Meeting" : meeting.title,
                        "meeting_date": dateFormatter.string(from: meeting.date),
                        "transcript": meeting.formattedTranscript,
                        "user_blurb": userBlurb,
                        "user_notes": meeting.userNotes,
                        "template_content": templateContent
                    ]

                    // Process the system prompt template
                    let systemContent = Settings.processTemplate(systemPrompt, with: templateVariables)
                    let systemMessage = ChatQuery.ChatCompletionMessageParam(role: .system, content: systemContent)!

                    print(systemContent)

                    let query = ChatQuery(messages: [systemMessage], model: .gpt4_1)

                    let stream: AsyncThrowingStream<ChatStreamResult, Error> = openAI.chatsStream(query: query)

                    for try await result in stream {
                        if let content = result.choices.first?.delta.content {
                            continuation.yield(.content(content))
                        }
                    }

                    continuation.finish()
                } catch {
                    let errorMessage = ErrorHandler.shared.handleError(error)
                    print("Error in streaming generation: \(error)")
                    continuation.yield(.error(errorMessage))
                    continuation.finish()
                }
            }
        }
    }

    func validateAPIKey(_ apiKey: String) async -> Result<Void, Error> {
        let result = await APIKeyValidator.shared.validateAPIKey(apiKey, for: .openai)
        return result.mapError { $0 as Error }
    }
}
