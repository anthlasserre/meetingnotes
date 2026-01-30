//
//  TranscriptionProvider.swift
//  meetingnotes
//
//  Protocol for real-time audio transcription providers
//

import Foundation
import Combine

/// Protocol that all transcription providers must implement
protocol TranscriptionProvider: AnyObject {
    /// Connect to the transcription service
    /// - Parameters:
    ///   - apiKey: The API key for authentication
    ///   - language: The language for transcription
    func connect(apiKey: String, language: Language) async throws

    /// Disconnect from the transcription service
    func disconnect()

    /// Send audio data to the transcription service
    /// - Parameters:
    ///   - data: Raw PCM audio data
    ///   - source: The audio source (microphone or system)
    func sendAudioData(_ data: Data, source: AudioSource)

    /// Publisher for transcript chunks received from the service
    var transcriptChunksPublisher: Published<[TranscriptChunk]>.Publisher { get }

    /// Publisher for error messages
    var errorPublisher: Published<String?>.Publisher { get }

    /// Current connection status
    var isConnected: Bool { get }
}
