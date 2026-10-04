//
//  AssistantManager.swift
//  boringNotch
//
//  Conversation state for the Assistant tab: a short chat with Apple's
//  on-device model, streamed as it's written. Nothing leaves the Mac.
//

import Defaults
import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

struct AssistantMessage: Identifiable, Equatable {
    enum Role { case user, assistant, action }
    let id = UUID()
    let role: Role
    var text: String
    /// Set for `.action` messages: what the assistant did, with an Undo.
    var action: AssistantAction?
}

@MainActor
final class AssistantManager: ObservableObject {
    static let shared = AssistantManager()

    @Published private(set) var messages: [AssistantMessage] = []
    @Published private(set) var isResponding = false
    @Published private(set) var error: String?
    @Published var draft = ""
    /// Set to ask the view to focus its text field (e.g. from the shortcut);
    /// the view clears it once handled, so merely hovering the notch open
    /// on this tab never grabs the keyboard.
    @Published var focusRequested = false

    /// A LanguageModelSession on macOS 26+, kept so follow-up questions have context.
    private var session: AnyObject?
    private var task: Task<Void, Never>?

    private init() {}

    var isAvailable: Bool { Defaults[.enableAssistant] && AppleIntelligence.isAvailable }

    func requestFocus() { focusRequested = true }

    func send() {
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isResponding else { return }
        draft = ""
        error = nil
        messages.append(AssistantMessage(role: .user, text: prompt))
        messages.append(AssistantMessage(role: .assistant, text: ""))
        isResponding = true

        task = Task {
            defer {
                isResponding = false
                task = nil
                // Drop an empty answer bubble left by a failure or a stop.
                if messages.last?.role == .assistant, messages.last?.text.isEmpty == true {
                    messages.removeLast()
                }
            }
            do {
                try await stream(prompt)
            } catch is CancellationError {
                return
            } catch {
                self.error = AppleIntelligence.message(for: error)
                #if canImport(FoundationModels)
                // A full context window can't take another turn: start over next time.
                if #available(macOS 26.0, *),
                   case .exceededContextWindowSize = error as? LanguageModelSession.GenerationError {
                    session = nil
                }
                #endif
            }
        }
    }

    /// Shows an item a tool created, just above the answer being written.
    func recordAction(_ action: AssistantAction) {
        let card = AssistantMessage(role: .action, text: action.title, action: action)
        if isResponding, let last = messages.indices.last, messages[last].role == .assistant {
            messages.insert(card, at: last)
        } else {
            messages.append(card)
        }
    }

    func undo(_ messageID: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == messageID }),
              let action = messages[index].action, !action.undone,
              AssistantActions.shared.undo(action) else { return }
        messages[index].action?.undone = true
    }

    func stop() {
        task?.cancel()
        // The cancelled session may still be finishing its turn; use a fresh one.
        session = nil
    }

    func reset() {
        stop()
        messages = []
        error = nil
        draft = ""
    }

    private func stream(_ prompt: String) async throws {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), AppleIntelligence.isAvailable {
            let session = (self.session as? LanguageModelSession) ?? makeSession()
            self.session = session
            let stream = session.streamResponse(
                to: AssistantActions.dateContext() + prompt,
                options: GenerationOptions(temperature: 0.6)
            )
            for try await snapshot in stream {
                try Task.checkCancellation()
                if let index = messages.lastIndex(where: { $0.role == .assistant }) {
                    messages[index].text = snapshot.content
                }
            }
            return
        }
        #endif
        throw AppleIntelligenceError.unavailable
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private func makeSession() -> LanguageModelSession {
        LanguageModelSession(tools: AssistantTools.all, instructions: """
        You are a quick assistant that lives in the notch of the user's Mac. Answer in the user's \
        language (default: \(AppleIntelligence.userLanguageName)). Be brief: a few sentences or a short list. \
        Use plain text with at most light markdown (bold, lists). If you don't know something or it \
        needs live information, say so instead of guessing.
        Tools: createReminder, createEvent, readCalendar. You cannot see the calendar unless you call \
        readCalendar, so call it before answering any question about the user's plans, then answer only \
        from what it returns. When the user asks to be reminded of something or to add something to the \
        calendar, call the matching tool, then confirm in one short sentence. Each message starts with the \
        current time and a date table: always take dates from it, never compute them yourself, and don't \
        mention the table.
        """)
    }
    #endif
}
