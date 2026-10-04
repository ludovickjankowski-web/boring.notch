//
//  AppleIntelligence.swift
//  boringNotch
//
//  Thin wrapper over Apple's on-device language model (Foundation Models,
//  macOS 26+). Everything runs locally: no network, no account. Callers
//  check `isAvailable` first; on older systems or Macs without Apple
//  Intelligence the features simply stay hidden.
//

import Foundation
import NaturalLanguage
import OSLog
#if canImport(FoundationModels)
import FoundationModels
#endif

enum AppleIntelligenceError: LocalizedError {
    case unavailable
    case emptyInput

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return AppleIntelligence.unavailableReason ?? String(localized: "Apple Intelligence is not available.")
        case .emptyInput:
            return String(localized: "There is no text to work with.")
        }
    }
}

enum AppleIntelligence {
    static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "boringNotch", category: "AppleIntelligence")

    /// The on-device model has a small context window (about 4,000 tokens,
    /// prompt and answer together), so inputs are capped well below it.
    static let maxInputCharacters = 6_000

    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        #endif
        return false
    }

    /// Why the model can't be used, phrased for Settings. Nil when available.
    static var unavailableReason: String? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return nil
            case .unavailable(.deviceNotEligible):
                return String(localized: "This Mac doesn't support Apple Intelligence.")
            case .unavailable(.appleIntelligenceNotEnabled):
                return String(localized: "Turn on Apple Intelligence in System Settings to use these features.")
            case .unavailable(.modelNotReady):
                return String(localized: "The Apple Intelligence model is still downloading. Try again later.")
            case .unavailable:
                return String(localized: "Apple Intelligence is not available right now.")
            }
        }
        #endif
        return String(localized: "Apple Intelligence features require macOS 26 or later.")
    }

    /// The user's language, so answers match it even when the input doesn't say.
    static var userLanguageName: String {
        let code = Locale.preferredLanguages.first.map { Locale(identifier: $0).language.languageCode?.identifier ?? "en" } ?? "en"
        return Locale(identifier: "en").localizedString(forLanguageCode: code) ?? "English"
    }

    /// English name of the language the text is written in, falling back to
    /// the user's language. The small model drifts into English unless told.
    static func languageName(of text: String) -> String {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(2_000)))
        guard let code = recognizer.dominantLanguage?.rawValue,
              let name = Locale(identifier: "en").localizedString(forLanguageCode: code) else {
            return userLanguageName
        }
        return name
    }

    /// One-shot generation in a fresh session.
    static func respond(instructions: String, prompt: String, temperature: Double = 0.4) async throws -> String {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AppleIntelligenceError.emptyInput
        }
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), isAvailable {
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(to: prompt, options: GenerationOptions(temperature: temperature))
            return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        #endif
        throw AppleIntelligenceError.unavailable
    }

    /// Splits long text into chunks the model can take one at a time,
    /// cutting at paragraph or sentence boundaries where possible.
    static func chunks(of text: String, size: Int = maxInputCharacters) -> [String] {
        var result: [String] = []
        var remaining = Substring(text)
        while remaining.count > size {
            let limit = remaining.index(remaining.startIndex, offsetBy: size)
            let window = remaining[..<limit]
            let cut = window.range(of: "\n\n", options: .backwards)?.upperBound
                ?? window.range(of: ". ", options: .backwards)?.upperBound
                ?? limit
            let end = remaining.distance(from: remaining.startIndex, to: cut) > size / 2 ? cut : limit
            result.append(String(remaining[..<end]))
            remaining = remaining[end...]
        }
        if !remaining.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result.append(String(remaining))
        }
        return result
    }

    /// Readable message for a generation failure.
    static func message(for error: Error) -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), let error = error as? LanguageModelSession.GenerationError {
            switch error {
            case .exceededContextWindowSize:
                return String(localized: "The text is too long for the on-device model.")
            case .guardrailViolation, .refusal:
                return String(localized: "Apple Intelligence declined to process this text.")
            case .unsupportedLanguageOrLocale:
                return String(localized: "This language isn't supported by Apple Intelligence yet.")
            case .rateLimited, .concurrentRequests:
                return String(localized: "Apple Intelligence is busy. Try again in a moment.")
            default:
                break
            }
        }
        #endif
        return error.localizedDescription
    }
}
