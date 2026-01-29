//
//  GeminiTranscriptionProvider.swift
//  meetingnotes
//
//  Gemini real-time transcription provider implementation
//

import Foundation
import Combine
import AVFoundation

/// Gemini real-time transcription provider using Live API WebSocket
class GeminiTranscriptionProvider: TranscriptionProvider {
    @Published var transcriptChunks: [TranscriptChunk] = []
    @Published var errorMessage: String?

    var transcriptChunksPublisher: Published<[TranscriptChunk]>.Publisher { $transcriptChunks }
    var errorPublisher: Published<String?>.Publisher { $errorMessage }

    private var micSocketTask: URLSessionWebSocketTask?
    private var systemSocketTask: URLSessionWebSocketTask?
    private let liveAPIURL = URL(string: "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent")!
    private var sessionID = UUID()
    private var currentInterim: [AudioSource: String] = [.mic: "", .system: ""]
    private var pingTimers: [AudioSource: Timer] = [:]
    private var apiKey: String = ""
    private var isSetupComplete: [AudioSource: Bool] = [.mic: false, .system: false]
    private lazy var webSocketSession: URLSession = URLSession(configuration: .default)
    private var transcriptionBuffer: [AudioSource: String] = [.mic: "", .system: ""]
    private var flushTimers: [AudioSource: Timer] = [:]

    // Audio resampling from 24kHz (from AudioManager) to 16kHz (Gemini requirement)
    private var micResampler: AVAudioConverter?
    private var systemResampler: AVAudioConverter?
    private let targetSampleRate: Double = 16000.0
    private let sourceSampleRate: Double = 24000.0

    var isConnected: Bool {
        (micSocketTask?.state == .running) || (systemSocketTask?.state == .running)
    }

    func connect(apiKey: String) async throws {
        self.apiKey = apiKey
        sessionID = UUID()
        
        // Setup audio resamplers for 24kHz -> 16kHz conversion
        setupResamplers()

        // Connect both microphone and system audio sources
        try await connectToGeminiLive(source: .mic)
        try await connectToGeminiLive(source: .system)
    }

    func disconnect() {
        // Invalidate timers
        pingTimers.values.forEach { $0.invalidate() }
        pingTimers.removeAll()

        // Close WebSocket connections
        micSocketTask?.cancel(with: .goingAway, reason: nil)
        systemSocketTask?.cancel(with: .goingAway, reason: nil)
        micSocketTask = nil
        systemSocketTask = nil

        // Flush any remaining transcription before disconnecting
        flushTranscriptionBuffer(for: .mic)
        flushTranscriptionBuffer(for: .system)
        flushTimers.values.forEach { $0.invalidate() }
        flushTimers.removeAll()
        transcriptionBuffer = [.mic: "", .system: ""]

        // Clear interim state
        currentInterim = [.mic: "", .system: ""]
        
        // Clear resamplers
        micResampler = nil
        systemResampler = nil
        
        // Reset setup completion flags
        isSetupComplete = [.mic: false, .system: false]
    }

    func sendAudioData(_ data: Data, source: AudioSource) {
        let task = source == .mic ? micSocketTask : systemSocketTask
        guard let socket = task else {
            print("⚠️ No socket task for \(source), skipping audio send")
            return
        }
        
        // Check connection state - only send if connected and setup is complete
        guard socket.state == .running else {
            print("⚠️ Socket not running for \(source) (state: \(socket.state.rawValue)), skipping audio send")
            return
        }
        
        guard isSetupComplete[source] == true else {
            print("⚠️ Setup not complete for \(source), skipping audio send")
            return
        }
        
        // Resample from 24kHz to 16kHz if needed
        let resampledData = resampleAudioData(data, source: source)
        
        // Encode audio data as base64
        let base64Audio = resampledData.base64EncodedString()
        
        // Create realtimeInput message
        let message: [String: Any] = [
            "realtimeInput": [
                "mediaChunks": [
                    [
                        "mimeType": "audio/pcm;rate=16000",
                        "data": base64Audio
                    ]
                ]
            ]
        ]
        
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: message)
            if let jsonStr = String(data: jsonData, encoding: .utf8) {
                // Double-check state before sending
                guard socket.state == .running else { return }
                
                socket.send(.string(jsonStr)) { [weak self] error in
                    if let error = error {
                        // Check if it's a connection error
                        if let urlError = error as? URLError {
                            if urlError.code == .notConnectedToInternet || 
                               urlError.code == .networkConnectionLost ||
                               urlError.localizedDescription.contains("not connected") {
                                print("⚠️ Socket disconnected for \(source), will reconnect if needed")
                                // Don't set error message here - let the receive loop handle reconnection
                                return
                            }
                        }
                        print("❌ Failed to send audio data for \(source): \(error)")
                    }
                }
            }
        } catch {
            print("❌ Failed to serialize audio message for \(source): \(error)")
        }
    }

    // MARK: - Private Methods

    private func setupResamplers() {
        // Create source format (24kHz, mono, int16)
        guard let sourceFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                               sampleRate: sourceSampleRate,
                                               channels: 1,
                                               interleaved: false),
              let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                              sampleRate: targetSampleRate,
                                              channels: 1,
                                              interleaved: false) else {
            print("❌ Failed to create audio formats for resampling")
            return
        }
        
        micResampler = AVAudioConverter(from: sourceFormat, to: targetFormat)
        systemResampler = AVAudioConverter(from: sourceFormat, to: targetFormat)
    }
    
    private func resampleAudioData(_ data: Data, source: AudioSource) -> Data {
        guard let resampler = source == .mic ? micResampler : systemResampler else {
            // If resampler not available, try simple downsampling
            return simpleDownsample(data)
        }
        
        // Convert Data to AVAudioPCMBuffer
        let frameCount = data.count / 2 // 16-bit = 2 bytes per sample
        guard frameCount > 0,
              let sourceBuffer = AVAudioPCMBuffer(pcmFormat: resampler.inputFormat, frameCapacity: AVAudioFrameCount(frameCount)) else {
            return simpleDownsample(data)
        }
        
        sourceBuffer.frameLength = AVAudioFrameCount(frameCount)
        
        // Copy data into buffer
        guard let channelData = sourceBuffer.int16ChannelData?[0] else {
            return simpleDownsample(data)
        }
        
        data.withUnsafeBytes { bytes in
            guard let int16Pointer = bytes.bindMemory(to: Int16.self).baseAddress else { return }
            channelData.assign(from: int16Pointer, count: frameCount)
        }
        
        // Calculate output frame capacity (24kHz -> 16kHz = 2/3 ratio)
        let ratio = targetSampleRate / sourceSampleRate
        let outputFrameCapacity = AVAudioFrameCount(Double(frameCount) * ratio + 1) // +1 for rounding
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: resampler.outputFormat, frameCapacity: outputFrameCapacity) else {
            return simpleDownsample(data)
        }
        
        // Perform resampling
        var error: NSError?
        let status = resampler.convert(to: outputBuffer, error: &error) { _, outStatus in
            outStatus.pointee = .haveData
            return sourceBuffer
        }
        
        guard status == .haveData, error == nil,
              let outputChannelData = outputBuffer.int16ChannelData?[0] else {
            print("⚠️ Resampling failed, using simple downsampling")
            return simpleDownsample(data)
        }
        
        // Convert back to Data
        let outputFrameCount = Int(outputBuffer.frameLength)
        return Data(bytes: outputChannelData, count: outputFrameCount * 2)
    }
    
    /// Simple downsampling fallback: take every 3rd sample (24kHz -> 16kHz = 2/3 ratio)
    private func simpleDownsample(_ data: Data) -> Data {
        let frameCount = data.count / 2
        let ratio = 2.0 / 3.0 // 16kHz / 24kHz
        let outputFrameCount = Int(Double(frameCount) * ratio)
        
        guard outputFrameCount > 0 else { return data }
        
        var outputData = Data(capacity: outputFrameCount * 2)
        data.withUnsafeBytes { inputBytes in
            guard let inputPointer = inputBytes.bindMemory(to: Int16.self).baseAddress else { return }
            
            for i in 0..<outputFrameCount {
                let sourceIndex = Int(Double(i) / ratio)
                if sourceIndex < frameCount {
                    let sample = inputPointer[sourceIndex]
                    withUnsafeBytes(of: sample) { sampleBytes in
                        outputData.append(contentsOf: sampleBytes)
                    }
                }
            }
        }
        
        return outputData
    }

    private func connectToGeminiLive(source: AudioSource) async throws {
        guard !apiKey.isEmpty else {
            DispatchQueue.main.async {
                self.errorMessage = ErrorMessage.noAPIKey
            }
            throw NSError(domain: "GeminiProvider", code: 1, userInfo: [NSLocalizedDescriptionKey: ErrorMessage.noAPIKey])
        }

        // Clean up old connection for this source before creating new one
        let oldTask = source == .mic ? micSocketTask : systemSocketTask
        oldTask?.cancel(with: .goingAway, reason: nil)
        
        // Reset setup completion flag
        isSetupComplete[source] = false

        // Build WebSocket URL with API key
        guard var urlComponents = URLComponents(url: liveAPIURL, resolvingAgainstBaseURL: false) else {
            throw NSError(domain: "GeminiProvider", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid WebSocket URL"])
        }
        
        urlComponents.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        guard let url = urlComponents.url else {
            throw NSError(domain: "GeminiProvider", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to build WebSocket URL"])
        }
        
        // Log the URL (without the API key for security)
        let safeURL = url.absoluteString.replacingOccurrences(of: apiKey, with: "***")
        print("🔗 Connecting to Gemini Live API for \(source): \(safeURL)")

        var request = URLRequest(url: url)
        request.timeoutInterval = 30.0
        let task = webSocketSession.webSocketTask(with: request)
        
        // Store task immediately so it's available for other operations
        switch source {
        case .mic:
            micSocketTask = task
        case .system:
            systemSocketTask = task
        }
        
        // Monitor connection state changes
        observeConnectionState(for: task, source: source)
        
        task.resume()
        
        // Wait for connection to establish (check state)
        var attempts = 0
        while task.state != .running && attempts < 20 {
            try await Task.sleep(nanoseconds: 50_000_000) // 0.05 seconds
            attempts += 1
        }
        
        guard task.state == .running else {
            print("❌ Failed to establish WebSocket connection for \(source), state: \(task.state.rawValue)")
            throw NSError(domain: "GeminiProvider", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to establish WebSocket connection"])
        }

        // Start receiving messages first (before sending setup)
        receiveMessage(for: source, sessionID: sessionID)
        
        // Set up ping timer to keep connection alive
        setupPingTimer(for: source, task: task)

        // Send initial setup configuration
        sendSetupConfiguration(to: task, source: source)

        print("🌐 Connected to Gemini Live API (\(source)), state: \(task.state.rawValue)")
    }

    private func observeConnectionState(for task: URLSessionWebSocketTask, source: AudioSource) {
        // Monitor task state changes
        print("🔍 WebSocket task created for \(source), initial state: \(task.state.rawValue)")
    }
    
    private func setupPingTimer(for source: AudioSource, task: URLSessionWebSocketTask) {
        pingTimers[source]?.invalidate()
        let pingTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            // Get the current task (it might have been replaced)
            let currentTask = source == .mic ? self.micSocketTask : self.systemSocketTask
            guard let socket = currentTask, socket.state == .running else { return }
            
            socket.sendPing { error in
                if let error = error {
                    print("❌ Ping failed for \(source): \(error)")
                    // If ping fails, the receive loop will detect the disconnection
                } else {
                    print("🏓 Ping sent for \(source)")
                }
            }
        }
        pingTimers[source] = pingTimer
    }

    private func sendSetupConfiguration(to task: URLSessionWebSocketTask, source: AudioSource) {
        // Check state before sending
        guard task.state == .running else {
            print("❌ Cannot send setup for \(source) - task state is \(task.state.rawValue), not running")
            return
        }
        
        // Gemini Live API setup message format
        // Based on documentation, the setup should be simpler
        let setup: [String: Any] = [
            "setup": [
                "model": "models/gemini-2.5-flash-native-audio-preview-12-2025",
                "generationConfig": [
                    "responseModalities": ["AUDIO"]
                ],
                "inputAudioTranscription": [:]  // Empty dict enables transcription with defaults
            ]
        ]

        do {
            let jsonData = try JSONSerialization.data(withJSONObject: setup, options: [])
            if let jsonStr = String(data: jsonData, encoding: .utf8) {
                print("📤 Sending setup configuration for \(source): \(jsonStr)")
                task.send(.string(jsonStr)) { [weak self] error in
                    guard let self = self else { return }
                    if let error = error {
                        if (error as? URLError)?.code == .cancelled {
                            print("⚠️ Setup send cancelled for \(source) (connection may have closed)")
                        } else {
                            print("❌ Setup configuration send failed for \(source): \(error)")
                            // Check if connection is still open
                            if task.state != .running {
                                print("❌ Connection closed after setup send attempt, state: \(task.state.rawValue)")
                            }
                            DispatchQueue.main.async {
                                self.errorMessage = "\(ErrorMessage.configurationFailed): \(error.localizedDescription)"
                            }
                        }
                    } else {
                        print("✅ Setup configuration sent successfully for \(source)")
                        // Check state after send
                        print("🔍 Task state after setup send for \(source): \(task.state.rawValue)")
                        // Mark setup as complete after successful send
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            // Double-check state before marking complete
                            if task.state == .running {
                                self.isSetupComplete[source] = true
                                print("✅ Setup marked complete for \(source)")
                            } else {
                                print("⚠️ Cannot mark setup complete - task state is \(task.state.rawValue)")
                            }
                        }
                    }
                }
            }
        } catch {
            print("❌ Setup configuration serialization failed for \(source): \(error)")
            DispatchQueue.main.async {
                self.errorMessage = "\(ErrorMessage.configurationFailed): \(error.localizedDescription)"
            }
        }
    }

    private func receiveMessage(for source: AudioSource, sessionID: UUID) {
        let task: URLSessionWebSocketTask? = (source == .mic) ? micSocketTask : systemSocketTask
        guard let task = task else {
            print("⚠️ No task available for \(source) in receiveMessage")
            return
        }
        
        // Check state before receiving
        if task.state != .running {
            print("⚠️ Task state is not running for \(source): \(task.state.rawValue)")
            // Try to reconnect if not intentionally disconnected
            if isConnected {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                    guard let self = self, self.sessionID == sessionID else { return }
                    Task {
                        do {
                            try await self.connectToGeminiLive(source: source)
                        } catch {
                            print("❌ Reconnection failed for \(source): \(error)")
                        }
                    }
                }
            }
            return
        }
        
        task.receive { [weak self] result in
            guard let self = self, self.sessionID == sessionID else { return }

            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    print("📬 Received string message for \(source), length: \(text.count)")
                    self.parseGeminiMessage(text, source: source)
                case .data(let data):
                    print("📬 Received data message for \(source), length: \(data.count)")
                    // Try to parse as JSON if possible
                    if let text = String(data: data, encoding: .utf8) {
                        self.parseGeminiMessage(text, source: source)
                    }
                @unknown default:
                    print("📬 Received unknown message type for \(source)")
                    break
                }
                // Continue loop for this session
                self.receiveMessage(for: source, sessionID: sessionID)

            case .failure(let error):
                guard self.isConnected else { return } // Intentional disconnect
                
                // Check if it's a connection error
                let errorDescription = error.localizedDescription.lowercased()
                let isConnectionError = errorDescription.contains("not connected") ||
                                       errorDescription.contains("socket") ||
                                       errorDescription.contains("connection")
                
                if isConnectionError {
                    print("⚠️ Connection lost for \(source), attempting to reconnect...")
                    // Attempt to reconnect after a short delay
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                        guard let self = self, self.sessionID == sessionID, self.isConnected else { return }
                        Task {
                            do {
                                try await self.connectToGeminiLive(source: source)
                            } catch {
                                DispatchQueue.main.async {
                                    self.errorMessage = ErrorHandler.shared.handleError(error)
                                }
                            }
                        }
                    }
                } else if ErrorHandler.shared.shouldRetry(error) {
                    print("❌ Receive error (\(source)): \(error) - will retry")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                        guard let self = self, self.sessionID == sessionID else { return }
                        Task {
                            do {
                                try await self.connectToGeminiLive(source: source)
                            } catch {
                                DispatchQueue.main.async {
                                    self.errorMessage = ErrorHandler.shared.handleError(error)
                                }
                            }
                        }
                    }
                } else {
                    print("❌ Receive error (\(source)): \(error)")
                    DispatchQueue.main.async {
                        self.errorMessage = ErrorHandler.shared.handleError(error)
                    }
                }
            }
        }
    }

    private func parseGeminiMessage(_ text: String, source: AudioSource) {
        // Log raw message for debugging (first 500 chars)
        let preview = text.count > 500 ? String(text.prefix(500)) + "..." : text
        print("📥 Raw Gemini message for \(source): \(preview)")
        
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            print("⚠️ Failed to parse Gemini message as JSON: \(text.prefix(200))")
            return
        }

        // Handle errors
        if let errorDict = json["error"] as? [String: Any] {
            handleAPIError(errorDict, source: source)
            return
        }
        
        // If we receive any message without an error, setup is likely complete
        // Mark setup as complete on first successful message
        if !isSetupComplete[source]! {
            isSetupComplete[source] = true
            print("✅ Setup complete for \(source) - received first message")
        }
        
        // Check for specific setup response/acknowledgment
        if json["setupComplete"] != nil || json["session"] != nil {
            print("📋 Received setup acknowledgment for \(source)")
        }
        
        // Log message type for debugging
        let messageKeys = Array(json.keys)
        if !messageKeys.isEmpty {
            print("📨 Received message for \(source) with keys: \(messageKeys.joined(separator: ", "))")
        }
        
        // Try to find transcription in various possible locations
        var foundTranscription = false

        // Parse serverContent for transcription
        // Gemini Live API returns transcription in serverContent.inputTranscription
        if let serverContent = json["serverContent"] as? [String: Any] {
            // Accumulate transcription fragments into buffer
            if let inputTranscription = serverContent["inputTranscription"] as? [String: Any],
               let text = inputTranscription["text"] as? String, !text.isEmpty {
                foundTranscription = true
                transcriptionBuffer[source, default: ""] += text
                print("📝 Buffered transcription fragment (\(source)): \"\(text)\" → buffer: \"\(transcriptionBuffer[source, default: ""])\"")

                // Update interim display
                DispatchQueue.main.async {
                    self.transcriptChunks.removeAll { !$0.isFinal && $0.source == source }
                    let chunk = TranscriptChunk(
                        timestamp: Date(),
                        source: source,
                        text: self.transcriptionBuffer[source, default: ""],
                        isFinal: false
                    )
                    self.transcriptChunks.append(chunk)
                }

                // Reset debounce timer - flush after 1.5s of silence
                flushTimers[source]?.invalidate()
                flushTimers[source] = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
                    self?.flushTranscriptionBuffer(for: source)
                }
            }

            // turnComplete signals end of a speech segment - flush immediately
            if let turnComplete = serverContent["turnComplete"] as? Bool, turnComplete {
                print("🔄 Turn complete for \(source)")
                flushTranscriptionBuffer(for: source)
            }
        }
        
        // Also check for message format (alternative response format)
        if let message = json["message"] as? [String: Any] {
            // Check for content array
            if let content = message["content"] as? [[String: Any]] {
                for contentItem in content {
                    // Check for text content
                    if let text = contentItem["text"] as? String, !text.isEmpty {
                        DispatchQueue.main.async {
                            // Remove any interim chunks for this source
                            self.transcriptChunks.removeAll { !$0.isFinal && $0.source == source }
                            
                            // Append final chunk
                            let chunk = TranscriptChunk(
                                timestamp: Date(),
                                source: source,
                                text: text,
                                isFinal: true
                            )
                            self.transcriptChunks.append(chunk)
                            
                            // Clear interim state
                            self.currentInterim[source] = ""
                        }
                        print("📝 Transcription from message (\(source)): \(text)")
                    }
                }
            }
            
            // Check for serverContent within message
            if let serverContent = message["serverContent"] as? [String: Any],
               let inputTranscription = serverContent["inputTranscription"] as? [String: Any],
               let text = inputTranscription["text"] as? String, !text.isEmpty {
                DispatchQueue.main.async {
                    // Remove any interim chunks for this source
                    self.transcriptChunks.removeAll { !$0.isFinal && $0.source == source }
                    
                    // Append final chunk
                    let chunk = TranscriptChunk(
                        timestamp: Date(),
                        source: source,
                        text: text,
                        isFinal: true
                    )
                    self.transcriptChunks.append(chunk)
                    
                    // Clear interim state
                    self.currentInterim[source] = ""
                }
                print("📝 Transcription from message.serverContent (\(source)): \(text)")
            }
        }
        
        // Log other message types for debugging (if not already logged above)
        if let type = json["type"] as? String, !json.keys.contains(where: { $0 == "serverContent" || $0 == "setupComplete" || $0 == "session" }) {
            print("📋 Gemini message type (\(source)): \(type)")
        }
        
        // If we didn't find transcription, log the full structure for debugging
        if !foundTranscription {
            print("⚠️ No transcription found in message for \(source). Full JSON structure:")
            if let jsonData = try? JSONSerialization.data(withJSONObject: json, options: .prettyPrinted),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                print(jsonString)
            }
        }
    }

    private func flushTranscriptionBuffer(for source: AudioSource) {
        flushTimers[source]?.invalidate()
        flushTimers[source] = nil

        let bufferedText = transcriptionBuffer[source, default: ""]
        guard !bufferedText.isEmpty else { return }

        print("📝 Flushing transcription buffer (\(source)): \"\(bufferedText)\"")
        transcriptionBuffer[source] = ""

        DispatchQueue.main.async {
            // Remove interim chunk for this source
            self.transcriptChunks.removeAll { !$0.isFinal && $0.source == source }

            // Append as final chunk
            let chunk = TranscriptChunk(
                timestamp: Date(),
                source: source,
                text: bufferedText,
                isFinal: true
            )
            self.transcriptChunks.append(chunk)
            self.currentInterim[source] = ""
            print("✅ Committed transcript chunk for \(source), total: \(self.transcriptChunks.count)")
        }
    }

    private func handleAPIError(_ errorDict: [String: Any], source: AudioSource) {
        let errorCode = errorDict["code"] as? Int ?? 0
        let errorMessage = errorDict["message"] as? String ?? "Unknown error occurred"
        let errorStatus = errorDict["status"] as? String ?? ""

        print("❌ Gemini Live API Error (\(source)) - Code: \(errorCode), Status: \(errorStatus), Message: \(errorMessage)")

        let userFriendlyMessage: String
        switch errorCode {
        case 401:
            userFriendlyMessage = ErrorMessage.invalidAPIKey(for: .gemini)
        case 402, 403:
            userFriendlyMessage = ErrorMessage.insufficientFunds(for: .gemini)
        case 429:
            userFriendlyMessage = ErrorMessage.rateLimited(for: .gemini)
        case 500...599:
            userFriendlyMessage = ErrorMessage.apiServerError(for: .gemini)
        default:
            if errorStatus.lowercased().contains("permission") || errorStatus.lowercased().contains("forbidden") {
                userFriendlyMessage = ErrorMessage.accessForbidden
            } else if errorStatus.lowercased().contains("quota") || errorStatus.lowercased().contains("insufficient") {
                userFriendlyMessage = ErrorMessage.insufficientFunds(for: .gemini)
            } else {
                userFriendlyMessage = "Transcription error: \(errorMessage)"
            }
        }

        DispatchQueue.main.async {
            self.errorMessage = userFriendlyMessage
        }
    }
}
