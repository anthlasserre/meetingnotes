//
//  Language.swift
//  meetingnotes
//
//  Language enumeration for transcription and note generation
//

import Foundation

/// Supported languages for transcription and note generation
enum Language: String, Codable, CaseIterable, Identifiable {
    case english = "en"
    case spanish = "es"
    case french = "fr"
    case german = "de"
    case italian = "it"
    case portuguese = "pt"
    case chinese = "zh"
    case japanese = "ja"
    case korean = "ko"
    case hindi = "hi"

    var id: String { rawValue }

    /// Display name for the language in its native form
    var displayName: String {
        switch self {
        case .english:
            return "English"
        case .spanish:
            return "Español"
        case .french:
            return "Français"
        case .german:
            return "Deutsch"
        case .italian:
            return "Italiano"
        case .portuguese:
            return "Português"
        case .chinese:
            return "中文"
        case .japanese:
            return "日本語"
        case .korean:
            return "한국어"
        case .hindi:
            return "हिन्दी"
        }
    }

    /// Flag emoji representing the language
    var flagEmoji: String {
        switch self {
        case .english:
            return "🇺🇸"
        case .spanish:
            return "🇪🇸"
        case .french:
            return "🇫🇷"
        case .german:
            return "🇩🇪"
        case .italian:
            return "🇮🇹"
        case .portuguese:
            return "🇵🇹"
        case .chinese:
            return "🇨🇳"
        case .japanese:
            return "🇯🇵"
        case .korean:
            return "🇰🇷"
        case .hindi:
            return "🇮🇳"
        }
    }
}
