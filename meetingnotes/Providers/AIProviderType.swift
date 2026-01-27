//
//  AIProviderType.swift
//  meetingnotes
//
//  AI provider type enumeration for multi-provider support
//

import Foundation

enum AIProviderType: String, Codable, CaseIterable, Identifiable {
    case openai = "OpenAI"
    case gemini = "Gemini"
    case claude = "Claude"

    var id: String { rawValue }

    var displayName: String {
        rawValue
    }

    /// Indicates if this provider requires a secondary provider for full functionality
    /// (e.g., Claude needs OpenAI for transcription)
    var requiresSecondaryProvider: Bool {
        switch self {
        case .claude:
            return true
        case .openai, .gemini:
            return false
        }
    }

    /// The secondary provider needed, if any
    var secondaryProvider: AIProviderType? {
        switch self {
        case .claude:
            return .openai
        case .openai, .gemini:
            return nil
        }
    }

    /// Human-readable description of provider capabilities
    var capabilityDescription: String {
        switch self {
        case .openai:
            return "Real-time transcription and note generation"
        case .gemini:
            return "Real-time transcription and note generation"
        case .claude:
            return "Note generation only (uses OpenAI for transcription)"
        }
    }
}
