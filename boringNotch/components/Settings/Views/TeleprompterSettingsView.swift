//
//  TeleprompterSettingsView.swift
//  boringNotch
//

import Defaults
import KeyboardShortcuts
import SwiftUI

struct TeleprompterSettingsView: View {
    @Default(.enableTeleprompter) var enabled
    @Default(.teleprompterText) var script
    @Default(.teleprompterSpeed) var speed
    @Default(.teleprompterFontSize) var fontSize
    @Default(.enableAITeleprompter) var aiEnabled
    @State private var rewriting: ScriptRewrite?
    @State private var previousScript: String?
    @State private var rewriteError: String?

    var body: some View {
        Form {
            Section {
                Defaults.Toggle(key: .enableTeleprompter) {
                    Text("Show Teleprompter tab")
                }
                KeyboardShortcuts.Recorder("Open and start/pause:", name: .toggleTeleprompter)
            } header: {
                Text("General")
            } footer: {
                Text(
                    "The script scrolls right under the camera, so you can read it while looking at the lens. The notch stays open while it scrolls.",
                    comment: "Footer explaining the teleprompter."
                )
                .foregroundStyle(.secondary)
                .font(.caption)
            }

            Section {
                TextEditor(text: $script)
                    .font(.system(.body, design: .rounded))
                    .frame(minHeight: 220)
                    .scrollContentBackground(.hidden)
            } header: {
                Text("Script")
            }
            .disabled(!enabled)

            if aiEnabled && AppleIntelligence.isAvailable {
                intelligenceSection
                    .disabled(!enabled)
            }

            Section {
                Slider(value: $speed, in: TeleprompterManager.speedRange, step: 5) {
                    Text("Speed - \(Int(speed))", comment: "Teleprompter scroll speed in points per second.")
                }
                Slider(value: $fontSize, in: TeleprompterManager.fontSizeRange, step: 1) {
                    Text("Text size - \(Int(fontSize))", comment: "Teleprompter font size.")
                }
            } header: {
                Text("Display")
            }
            .disabled(!enabled)
        }
        .accentColor(.effectiveAccent)
        .navigationTitle("Teleprompter")
    }

    private var intelligenceSection: some View {
        Section {
            HStack(spacing: 8) {
                rewriteButton(.fromNotes)
                rewriteButton(.shorten)
                rewriteButton(.conversational)
                rewriteButton(.formal)
            }
            .controlSize(.small)

            HStack(spacing: 8) {
                Menu {
                    ForEach(ScriptRewrite.translationLanguages, id: \.self) { language in
                        Button(Locale.current.localizedString(forLanguageCode: language) ?? language) {
                            rewrite(.translate(language))
                        }
                    }
                } label: {
                    Label("Translate", systemImage: "translate")
                }
                .fixedSize()
                .disabled(rewriting != nil)
            }
            .controlSize(.small)

            HStack(spacing: 8) {
                if let rewriting {
                    ProgressView().controlSize(.small)
                    Text(rewriting.progressLabel)
                        .foregroundStyle(.secondary)
                } else if let rewriteError {
                    Label(rewriteError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                Spacer()
                if previousScript != nil, rewriting == nil {
                    Button {
                        if let previousScript { script = previousScript }
                        previousScript = nil
                    } label: {
                        Label("Undo", systemImage: "arrow.uturn.backward")
                    }
                    .controlSize(.small)
                }
            }
            .font(.caption)
        } header: {
            Text("Apple Intelligence")
        } footer: {
            Text(
                "Write a few notes, then turn them into a script you can read aloud. Everything runs on this Mac.",
                comment: "Footer explaining the teleprompter script assistant."
            )
            .foregroundStyle(.secondary)
            .font(.caption)
        }
    }

    private func rewriteButton(_ action: ScriptRewrite) -> some View {
        Button {
            rewrite(action)
        } label: {
            Label(action.title, systemImage: action.icon)
        }
        .fixedSize()
        .disabled(rewriting != nil || script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private func rewrite(_ action: ScriptRewrite) {
        let original = script
        rewriting = action
        rewriteError = nil
        Task {
            defer { rewriting = nil }
            do {
                // Long scripts are rewritten piece by piece to fit the model's context.
                let language = action.outputLanguage(for: original)
                var parts: [String] = []
                for chunk in AppleIntelligence.chunks(of: original) {
                    parts.append(try await AppleIntelligence.respond(
                        instructions: action.instructions(language: language),
                        prompt: action.prompt(chunk, language: language),
                        temperature: 0.5
                    ))
                }
                // Ignore the result if the script was edited while the model worked.
                guard script == original else { return }
                previousScript = original
                script = parts.joined(separator: "\n\n")
            } catch {
                rewriteError = AppleIntelligence.message(for: error)
            }
        }
    }
}

/// Script rewrites offered by the on-device model.
enum ScriptRewrite: Hashable {
    case fromNotes
    case shorten
    case conversational
    case formal
    case translate(String)

    static let translationLanguages = ["en", "fr", "es", "de", "it", "pt", "nl", "ja", "zh", "ko"]

    var title: LocalizedStringKey {
        switch self {
        case .fromNotes: return "Notes to script"
        case .shorten: return "Shorten"
        case .conversational: return "Casual"
        case .formal: return "Formal"
        case .translate: return "Translate"
        }
    }

    var icon: String {
        switch self {
        case .fromNotes: return "wand.and.stars"
        case .shorten: return "arrow.down.right.and.arrow.up.left"
        case .conversational: return "bubble.left.and.bubble.right"
        case .formal: return "briefcase"
        case .translate: return "translate"
        }
    }

    var progressLabel: String {
        switch self {
        case .translate: return String(localized: "Translating…")
        default: return String(localized: "Rewriting…")
        }
    }

    private static let format = "Use short paragraphs separated by blank lines; no headings, bullet points, markdown or stage directions. Output only the script."

    func instructions(language: String) -> String {
        switch self {
        case .fromNotes:
            return "You are a scriptwriter. You expand rough notes into a short script that a person reads aloud on camera: natural spoken sentences that connect the ideas, with a brief opening and closing line. Cover every note in order. Do not add facts, claims or details that are not in the notes. \(Self.format) Write in \(language)."
        case .shorten:
            return "You shorten scripts that are read aloud to about half their length, keeping the key points and the speaker's voice. Do not add anything new. \(Self.format) Write in \(language)."
        case .conversational:
            return "You rewrite scripts that are read aloud in a warm, relaxed, conversational tone, as if talking to a friend, without changing what is said. \(Self.format) Write in \(language)."
        case .formal:
            return "You rewrite scripts that are read aloud in a clear, polished, professional tone without changing what is said. \(Self.format) Write in \(language)."
        case .translate:
            return "You translate scripts that are read aloud into \(language), faithfully and naturally, keeping the paragraph breaks. Output only the translation."
        }
    }

    /// Language of the result: the target for translations, otherwise the script's own.
    func outputLanguage(for script: String) -> String {
        if case .translate(let code) = self {
            return Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code
        }
        return AppleIntelligence.languageName(of: script)
    }

    func prompt(_ text: String, language: String) -> String {
        switch self {
        case .fromNotes: return "Notes:\n\(text)\n\nWrite the script in \(language)."
        case .translate: return "Script:\n\(text)\n\nTranslate it into \(language)."
        default: return "Script:\n\(text)\n\nRewrite it in \(language)."
        }
    }
}
