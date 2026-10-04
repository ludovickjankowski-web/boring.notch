//
//  ShelfIntelligenceService.swift
//  boringNotch
//
//  Apple Intelligence actions on shelf items: summarize, translate, and pull
//  out action items and dates. Text is read from the items locally and sent
//  only to the on-device model; the result opens in a small window where it
//  can be copied or dropped back onto the shelf.
//

import AppKit
import Defaults
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

enum ShelfIntelligenceAction: Equatable {
    case summarize
    case translate(String)
    case extractActions

    var title: String {
        switch self {
        case .summarize:
            return String(localized: "Summarize")
        case .translate(let code):
            let language = Locale.current.localizedString(forLanguageCode: code) ?? code
            return String(localized: "Translate to \(language)")
        case .extractActions:
            return String(localized: "Find Actions & Dates")
        }
    }

    var icon: String {
        switch self {
        case .summarize: return "text.append"
        case .translate: return "translate"
        case .extractActions: return "checklist"
        }
    }

    /// Translations offered in the menu: the user's language, plus English for
    /// everyone who doesn't already use it.
    static var translationTargets: [String] {
        let preferred = Locale.preferredLanguages.first.flatMap { Locale(identifier: $0).language.languageCode?.identifier } ?? "en"
        return preferred == "en" ? ["en"] : [preferred, "en"]
    }
}

@MainActor
enum ShelfIntelligenceService {
    /// Most text the shelf will read from one selection; longer inputs are cut.
    static let maxTotalCharacters = 40_000
    private static let none = "NONE"

    static var isEnabled: Bool { Defaults[.enableAIShelf] && AppleIntelligence.isAvailable }

    /// Whether the item holds text the model can read.
    static func canProcess(_ item: ShelfItem) -> Bool {
        switch item.kind {
        case .text: return true
        case .link: return false
        case .file:
            guard let url = item.fileURL else { return false }
            if isTextBlock(url) { return true }
            guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
            return type.conforms(to: .pdf) || type.conforms(to: .text) || type.conforms(to: .rtfd)
                || type.conforms(to: .sourceCode) || richDocumentTypes.contains(where: type.conforms(to:))
        }
    }

    private static let richDocumentTypes: [UTType] = [
        UTType("org.openxmlformats.wordprocessingml.document"),
        UTType("com.microsoft.word.doc"),
        UTType("org.oasis-open.opendocument.text"),
    ].compactMap { $0 }

    static func run(_ action: ShelfIntelligenceAction, on items: [ShelfItem]) {
        let processable = items.filter(canProcess)
        guard !processable.isEmpty else { return }
        let title = processable.count == 1 ? processable[0].displayName : String(localized: "\(processable.count) items")
        let model = IntelligenceResultModel(action: action, source: title)
        IntelligenceResultWindow.show(model)

        model.task = Task {
            do {
                let text = try await collectText(from: processable)
                let result = try await perform(action, on: text)
                model.finish(with: result)
            } catch is CancellationError {
                return
            } catch {
                model.fail(with: AppleIntelligence.message(for: error))
            }
        }
    }

    // MARK: Generation

    private static func perform(_ action: ShelfIntelligenceAction, on text: String) async throws -> String {
        let language = AppleIntelligence.userLanguageName
        let parts = AppleIntelligence.chunks(of: text)

        switch action {
        case .summarize:
            let instructions = "Summarize the text in \(language). Start with a one-sentence overview, then list up to five key points, one per line, each starting with \"• \". Plain text only, no markdown, no title."
            if parts.count == 1 {
                return try await AppleIntelligence.respond(instructions: instructions, prompt: framed(parts[0], "Summarize it in \(language)."), temperature: 0.2)
            }
            // Too long for one pass: summarize each part, then summarize the summaries.
            var partials: [String] = []
            for part in parts {
                try Task.checkCancellation()
                partials.append(try await AppleIntelligence.respond(
                    instructions: "Summarize this part of a longer document in \(language), in at most five short sentences. Plain text only.",
                    prompt: framed(part, "Summarize it in \(language)."),
                    temperature: 0.2
                ))
            }
            return try await AppleIntelligence.respond(instructions: instructions, prompt: framed(partials.joined(separator: "\n\n"), "Summarize it in \(language)."), temperature: 0.2)

        case .translate(let code):
            let target = Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code
            var translated: [String] = []
            for part in parts {
                try Task.checkCancellation()
                translated.append(try await AppleIntelligence.respond(
                    instructions: "Translate the text into \(target), faithfully and naturally. Keep the line breaks and structure. Output only the translation.",
                    prompt: framed(part, "Translate it into \(target)."),
                    temperature: 0.2
                ))
            }
            return translated.joined(separator: "\n\n")

        case .extractActions:
            var lines: [String] = []
            for part in parts {
                try Task.checkCancellation()
                let answer = try await AppleIntelligence.respond(
                    instructions: "List the action items, deadlines, appointments and important dates found in the text. Write in \(language), one per line, each starting with \"• \", putting the date or deadline first when there is one. Only include things actually in the text. If there are none, reply exactly \(none).",
                    prompt: framed(part, "List them in \(language)."),
                    temperature: 0.1
                )
                for line in answer.components(separatedBy: .newlines) {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty, trimmed != none, !lines.contains(trimmed) else { continue }
                    lines.append(trimmed)
                }
            }
            return lines.isEmpty ? String(localized: "No actions or dates found.") : lines.joined(separator: "\n")
        }
    }

    /// Wraps input so the model treats it as material, with the task restated
    /// last, where the small model pays most attention.
    private static func framed(_ text: String, _ task: String) -> String {
        "Text:\n\(text)\n\n\(task)"
    }

    // MARK: Text extraction

    private static func collectText(from items: [ShelfItem]) async throws -> String {
        var sections: [String] = []
        for item in items {
            guard let text = try await text(of: item)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { continue }
            sections.append(items.count > 1 ? "\(item.displayName)\n\(text)" : text)
        }
        let joined = sections.joined(separator: "\n\n")
        guard !joined.isEmpty else { throw AppleIntelligenceError.emptyInput }
        return String(joined.prefix(maxTotalCharacters))
    }

    private static func text(of item: ShelfItem) async throws -> String? {
        switch item.kind {
        case .text(let string):
            return string
        case .link:
            return nil
        case .file:
            guard let url = item.fileURL else { return nil }
            return try await Task.detached(priority: .userInitiated) {
                try url.accessSecurityScopedResource { try readText(at: $0) }
            }.value
        }
    }

    private static func isTextBlock(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "json" && url.path.contains("TextBlocks")
    }

    nonisolated private static func readText(at url: URL) throws -> String? {
        if url.pathExtension.lowercased() == "json" && url.path.contains("TextBlocks") {
            struct TextBlock: Decodable { let content: String }
            return try JSONDecoder().decode(TextBlock.self, from: Data(contentsOf: url)).content
        }
        let type = UTType(filenameExtension: url.pathExtension)
        if type?.conforms(to: .pdf) == true {
            return PDFDocument(url: url)?.string
        }
        if type?.conforms(to: .plainText) == true || type?.conforms(to: .sourceCode) == true {
            if let string = try? String(contentsOf: url, encoding: .utf8) { return string }
        }
        // RTF, Word, OpenDocument, HTML…
        if let attributed = try? NSAttributedString(url: url, options: [:], documentAttributes: nil) {
            return attributed.string
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}

// MARK: - Result window

@MainActor
final class IntelligenceResultModel: ObservableObject {
    let action: ShelfIntelligenceAction
    let source: String
    @Published private(set) var result: String?
    @Published private(set) var error: String?
    var task: Task<Void, Never>?

    init(action: ShelfIntelligenceAction, source: String) {
        self.action = action
        self.source = source
    }

    var isWorking: Bool { result == nil && error == nil }

    func finish(with text: String) { result = text }
    func fail(with message: String) { error = message }
}

@MainActor
enum IntelligenceResultWindow {
    /// Open windows, each with the delegate that cancels its work on close.
    private static var open: [(window: NSWindow, delegate: CloseDelegate)] = []

    private final class CloseDelegate: NSObject, NSWindowDelegate {
        let model: IntelligenceResultModel
        init(model: IntelligenceResultModel) { self.model = model }

        func windowWillClose(_ notification: Notification) {
            model.task?.cancel()
            let window = notification.object as? NSWindow
            IntelligenceResultWindow.open.removeAll { $0.window === window }
        }
    }

    static func show(_ model: IntelligenceResultModel) {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 320),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.title = model.action.title
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.contentViewController = NSHostingController(rootView: IntelligenceResultView(model: model) { [weak window] in
            window?.close()
        })
        window.setContentSize(NSSize(width: 440, height: 320))
        window.center()
        let delegate = CloseDelegate(model: model)
        window.delegate = delegate
        open.append((window, delegate))

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

private struct IntelligenceResultView: View {
    @ObservedObject var model: IntelligenceResultModel
    let close: () -> Void
    @State private var copied = false
    @State private var added = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(model.source, systemImage: model.action.icon)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)

            Group {
                if let result = model.result {
                    ScrollView {
                        Text(result)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else if let error = model.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 8) {
                        ProgressView()
                        Text("Apple Intelligence is working on this Mac…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))

            HStack {
                Button {
                    guard let result = model.result else { return }
                    ShelfStateViewModel.shared.add([ShelfItem(kind: .text(string: result))])
                    added = true
                } label: {
                    Label(added ? "Added" : "Add to Shelf", systemImage: added ? "checkmark" : "tray.and.arrow.down")
                }
                .disabled(model.result == nil || added)

                Spacer()

                Button {
                    guard let result = model.result else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(result, forType: .string)
                    copied = true
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .disabled(model.result == nil)

                Button("Done", action: close)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(minWidth: 360, minHeight: 240)
    }
}
