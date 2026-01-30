//
//  OpenAITranscriptionProvider.swift
//  meetingnotes
//
//  OpenAI real-time transcription provider implementation
//

import Foundation
import Combine

/// OpenAI real-time transcription provider using WebSocket API
class OpenAITranscriptionProvider: TranscriptionProvider {
    @Published var transcriptChunks: [TranscriptChunk] = []
    @Published var errorMessage: String?

    var transcriptChunksPublisher: Published<[TranscriptChunk]>.Publisher { $transcriptChunks }
    var errorPublisher: Published<String?>.Publisher { $errorMessage }

    private var micSocketTask: URLSessionWebSocketTask?
    private var systemSocketTask: URLSessionWebSocketTask?
    private let realtimeURL = URL(string: "wss://api.openai.com/v1/realtime?intent=transcription")!
    private var sessionID = UUID()
    private var currentInterim: [AudioSource: String] = [.mic: "", .system: ""]
    private var pingTimers: [AudioSource: Timer] = [:]
    private var sessionRefreshTimers: [AudioSource: Timer] = [:]
    private var apiKey: String = ""
    private var language: Language = .english

    var isConnected: Bool {
        (micSocketTask?.state == .running) || (systemSocketTask?.state == .running)
    }

    func connect(apiKey: String, language: Language) async throws {
        self.apiKey = apiKey
        self.language = language
        sessionID = UUID()

        // Connect both microphone and system audio sources
        connectToOpenAIRealtime(source: .mic)
        connectToOpenAIRealtime(source: .system)
    }

    func disconnect() {
        // Invalidate timers
        pingTimers.values.forEach { $0.invalidate() }
        pingTimers.removeAll()
        sessionRefreshTimers.values.forEach { $0.invalidate() }
        sessionRefreshTimers.removeAll()

        // Close WebSocket connections
        micSocketTask?.cancel(with: .goingAway, reason: nil)
        systemSocketTask?.cancel(with: .goingAway, reason: nil)
        micSocketTask = nil
        systemSocketTask = nil

        // Clear interim state
        currentInterim = [.mic: "", .system: ""]
    }

    func sendAudioData(_ data: Data, source: AudioSource) {
        let task = source == .mic ? micSocketTask : systemSocketTask
        guard let socket = task, socket.state == .running else { return }

        socket.send(.data(data)) { error in
            if let error = error {
                print("❌ Failed to send audio data for \(source): \(error)")
            }
        }
    }

    // MARK: - Private Methods

    private func connectToOpenAIRealtime(source: AudioSource) {
        guard !apiKey.isEmpty else {
            errorMessage = ErrorMessage.noAPIKey
            return
        }

        let session = URLSession(configuration: .default)
        var request = URLRequest(url: realtimeURL)
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.addValue("realtime=v1", forHTTPHeaderField: "OpenAI-Beta")

        let task = session.webSocketTask(with: request)
        task.resume()

        // Set up ping timer to keep connection alive
        setupPingTimer(for: source, task: task)

        // Set up session refresh timer to prevent 30-minute expiry
        setupSessionRefreshTimer(for: source)

        // Send initial configuration
        sendConfiguration(to: task)

        // Store task
        switch source {
        case .mic:
            micSocketTask = task
        case .system:
            systemSocketTask = task
        }

        receiveMessage(for: source, sessionID: sessionID)
        print("🌐 Connected to OpenAI Realtime (\(source))")
    }

    private func setupPingTimer(for source: AudioSource, task: URLSessionWebSocketTask) {
        pingTimers[source]?.invalidate()
        let pingTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            guard let self = self, task.state == .running else { return }
            task.sendPing { error in
                if let error = error {
                    print("❌ Ping failed for \(source): \(error)")
                } else {
                    print("🏓 Ping sent for \(source)")
                }
            }
        }
        pingTimers[source] = pingTimer
    }

    private func setupSessionRefreshTimer(for source: AudioSource) {
        sessionRefreshTimers[source]?.invalidate()
        let sessionRefreshTimer = Timer.scheduledTimer(withTimeInterval: 28 * 60.0, repeats: false) { [weak self] _ in
            guard let self = self, self.isConnected else { return }
            print("📝 Proactively refreshing session for \(source) to prevent expiry...")
            self.connectToOpenAIRealtime(source: source)
        }
        sessionRefreshTimers[source] = sessionRefreshTimer
    }

    private func sendConfiguration(to task: URLSessionWebSocketTask) {
        let config: [String: Any] = [
            "type": "transcription_session.update",
            "session": [
                "input_audio_format": "pcm16",
                "input_audio_transcription": [
                    "model": "gpt-4o-mini-transcribe",
                    "language": language.rawValue
                ],
                "turn_detection": [
                    "type": "server_vad",
                    "threshold": 0.5,
                    "prefix_padding_ms": 300,
                    "silence_duration_ms": 200
                ]
            ]
        ]

        do {
            let jsonData = try JSONSerialization.data(withJSONObject: config)
            if let jsonStr = String(data: jsonData, encoding: .utf8) {
                task.send(.string(jsonStr)) { error in
                    if let error = error, (error as? URLError)?.code != .cancelled {
                        print("❌ Configuration failed: \(error)")
                        self.errorMessage = "\(ErrorMessage.configurationFailed): \(error.localizedDescription)"
                    }
                }
            }
        } catch {
            print("❌ Configuration failed: \(error)")
            errorMessage = "\(ErrorMessage.configurationFailed): \(error.localizedDescription)"
        }
    }

    private func receiveMessage(for source: AudioSource, sessionID: UUID) {
        let task: URLSessionWebSocketTask? = (source == .mic) ? micSocketTask : systemSocketTask
        task?.receive { [weak self] result in
            guard let self = self, self.sessionID == sessionID else { return }

            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self.parseRealtimeEvent(text, source: source)
                case .data:
                    break
                @unknown default:
                    break
                }
                // Continue loop for this session
                self.receiveMessage(for: source, sessionID: sessionID)

            case .failure(let error):
                guard self.isConnected else { return } // Intentional disconnect
                print("❌ Receive error (\(source)): \(error)")

                if ErrorHandler.shared.shouldRetry(error) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                        guard let self = self, self.sessionID == sessionID else { return }
                        self.connectToOpenAIRealtime(source: source)
                    }
                } else {
                    self.errorMessage = ErrorHandler.shared.handleError(error)
                }
            }
        }
    }

    private func parseRealtimeEvent(_ text: String, source: AudioSource) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        // Handle errors
        if let errorDict = json["error"] as? [String: Any] {
            handleAPIError(errorDict, source: source)
            return
        }

        guard let type = json["type"] as? String else { return }

        switch type {
        case "conversation.item.input_audio_transcription.delta":
            if let delta = json["delta"] as? String {
                currentInterim[source, default: ""] += delta

                // Remove previous interim chunk from the same source
                transcriptChunks.removeAll { !$0.isFinal && $0.source == source }

                // Append updated interim chunk
                let chunk = TranscriptChunk(
                    timestamp: Date(),
                    source: source,
                    text: currentInterim[source] ?? "",
                    isFinal: false
                )
                transcriptChunks.append(chunk)
            }

        case "conversation.item.input_audio_transcription.completed":
            if let transcript = json["transcript"] as? String {
                // Remove any interim chunks for this source
                transcriptChunks.removeAll { !$0.isFinal && $0.source == source }

                // Append final chunk
                let chunk = TranscriptChunk(
                    timestamp: Date(),
                    source: source,
                    text: transcript,
                    isFinal: true
                )
                transcriptChunks.append(chunk)

                // Clear interim state
                currentInterim[source] = ""
            }

        default:
            break
        }
    }

    private func handleAPIError(_ errorDict: [String: Any], source: AudioSource) {
        let errorType = errorDict["type"] as? String ?? "unknown_error"
        let errorCode = errorDict["code"] as? String ?? ""
        let errorMsg = errorDict["message"] as? String ?? "Unknown error occurred"

        print("❌ OpenAI Realtime API Error (\(source)) - Type: \(errorType), Code: \(errorCode), Message: \(errorMsg)")

        let userFriendlyMessage: String
        switch errorCode {
        case "insufficient_quota", "quota_exceeded":
            userFriendlyMessage = ErrorMessage.insufficientFunds
        case "invalid_api_key", "authentication_failed":
            userFriendlyMessage = ErrorMessage.invalidAPIKey
        case "rate_limit_exceeded":
            userFriendlyMessage = ErrorMessage.rateLimited
        case "server_error":
            userFriendlyMessage = ErrorMessage.apiServerError
        case "access_denied", "forbidden":
            userFriendlyMessage = ErrorMessage.accessForbidden
        case "session_expired":
            handleSessionExpiry(source: source)
            return
        default:
            if errorMsg.lowercased().contains("session expired") {
                handleSessionExpiry(source: source)
                return
            }
            userFriendlyMessage = "Transcription error: \(errorMsg)"
        }

        errorMessage = userFriendlyMessage
    }

    private func handleSessionExpiry(source: AudioSource) {
        print("📝 Session expired for \(source), attempting to restart connection...")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self = self else { return }
            self.connectToOpenAIRealtime(source: source)
        }
    }
}
