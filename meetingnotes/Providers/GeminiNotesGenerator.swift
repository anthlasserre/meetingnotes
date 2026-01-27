//
//  GeminiNotesGenerator.swift
//  meetingnotes
//
//  Gemini notes generation provider implementation
//

import Foundation

/// Gemini notes generation provider using Gemini API
class GeminiNotesGenerator: NotesGenerationProvider {
    func generateNotesStream(
        meeting: Meeting,
        userBlurb: String,
        systemPrompt: String,
        templateId: UUID?
    ) -> AsyncStream<GenerationResult> {
        return AsyncStream<GenerationResult> { continuation in
            Task {
                do {
                    guard let apiKey = KeychainHelper.shared.getAPIKey(for: .gemini), !apiKey.isEmpty else {
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
                    
                    print("📝 Generating notes with Gemini...")
                    print("System prompt length: \(systemContent.count) characters")

                    // Call Gemini API with streaming
                    let stream = try await callGeminiAPIStream(apiKey: apiKey, systemPrompt: systemContent)
                    
                    for try await chunk in stream {
                        continuation.yield(.content(chunk))
                    }

                    continuation.finish()
                } catch {
                    let errorMessage = ErrorHandler.shared.handleError(error)
                    print("❌ Error in Gemini streaming generation: \(error)")
                    continuation.yield(.error(errorMessage))
                    continuation.finish()
                }
            }
        }
    }

    func validateAPIKey(_ apiKey: String) async -> Result<Void, Error> {
        let result = await APIKeyValidator.shared.validateAPIKey(apiKey, for: .gemini)
        return result.mapError { $0 as Error }
    }
    
    // MARK: - Private Methods
    
    private func callGeminiAPIStream(apiKey: String, systemPrompt: String) async throws -> AsyncThrowingStream<String, Error> {
        // Add alt=sse parameter for Server-Sent Events streaming
        let urlString = "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash-exp:streamGenerateContent?key=\(apiKey)&alt=sse"
        guard let url = URL(string: urlString) else {
            throw NSError(domain: "GeminiProvider", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"])
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        // Build request body
        let requestBody: [String: Any] = [
            "contents": [
                [
                    "parts": [
                        [
                            "text": systemPrompt
                        ]
                    ]
                ]
            ],
            "generationConfig": [
                "temperature": 0.7,
                "topK": 40,
                "topP": 0.95,
                "maxOutputTokens": 8192
            ]
        ]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        
        // Use URLSession's bytes stream for Server-Sent Events
        return AsyncThrowingStream<String, Error> { continuation in
            Task {
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    
                    guard let httpResponse = response as? HTTPURLResponse else {
                        throw NSError(domain: "GeminiProvider", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
                    }
                    
                    guard (200...299).contains(httpResponse.statusCode) else {
                        let errorMessage = ErrorHandler.shared.handleHTTPStatusCode(httpResponse.statusCode, provider: .gemini)
                        throw NSError(domain: "GeminiProvider", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: errorMessage])
                    }
                    
                    // Parse Server-Sent Events (SSE) format
                    // Gemini returns lines prefixed with "data: " followed by JSON
                    var buffer = Data()
                    var lineBuffer = ""
                    
                    print("📡 Starting to receive Gemini stream...")
                    
                    for try await byte in bytes {
                        buffer.append(byte)
                        
                        // Look for newline-delimited chunks
                        if byte == 0x0A { // Newline character
                            guard let line = String(data: buffer, encoding: .utf8) else {
                                buffer.removeAll()
                                continue
                            }
                            
                            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
                            buffer.removeAll()
                            
                            guard !trimmedLine.isEmpty else { continue }
                            
                            // Skip non-data lines (like "event:" or empty lines)
                            guard trimmedLine.hasPrefix("data: ") else {
                                if trimmedLine == "[DONE]" {
                                    print("✅ Received [DONE] marker")
                                    break
                                }
                                continue
                            }
                            
                            // Extract JSON after "data: " prefix
                            let jsonString = String(trimmedLine.dropFirst(6)) // Remove "data: "
                            guard !jsonString.isEmpty else { continue }
                            
                            // Parse JSON chunk
                            guard let jsonData = jsonString.data(using: .utf8),
                                  let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                                print("⚠️ Failed to parse JSON chunk: \(jsonString.prefix(100))")
                                continue
                            }
                            
                            // Check for errors first
                            if let error = json["error"] as? [String: Any],
                               let message = error["message"] as? String {
                                print("❌ Gemini API error: \(message)")
                                throw NSError(domain: "GeminiProvider", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
                            }
                            
                            // Extract text from response
                            if let candidates = json["candidates"] as? [[String: Any]],
                               let firstCandidate = candidates.first,
                               let content = firstCandidate["content"] as? [String: Any],
                               let parts = content["parts"] as? [[String: Any]],
                               let firstPart = parts.first,
                               let text = firstPart["text"] as? String,
                               !text.isEmpty {
                                print("📝 Received text chunk: \(text.prefix(50))...")
                                continuation.yield(text)
                            } else {
                                // Log if we got a response but no text (might be finish reason or metadata)
                                if let candidates = json["candidates"] as? [[String: Any]],
                                   let firstCandidate = candidates.first,
                                   let finishReason = firstCandidate["finishReason"] as? String {
                                    print("ℹ️ Received finish reason: \(finishReason)")
                                } else {
                                    print("⚠️ Received chunk but no text found: \(json.keys.joined(separator: ", "))")
                                }
                            }
                        }
                    }
                    
                    // Process any remaining buffer
                    if !buffer.isEmpty {
                        let line = String(data: buffer, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        if line.hasPrefix("data: ") {
                            let jsonString = String(line.dropFirst(6))
                            if let jsonData = jsonString.data(using: .utf8),
                               let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                               let candidates = json["candidates"] as? [[String: Any]],
                               let firstCandidate = candidates.first,
                               let content = firstCandidate["content"] as? [String: Any],
                               let parts = content["parts"] as? [[String: Any]],
                               let firstPart = parts.first,
                               let text = firstPart["text"] as? String,
                               !text.isEmpty {
                                print("📝 Received final text chunk: \(text.prefix(50))...")
                                continuation.yield(text)
                            }
                        }
                    }
                    
                    print("✅ Finished receiving Gemini stream")
                    
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
