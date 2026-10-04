//
//  AssistantView.swift
//  boringNotch
//
//  Open-notch tab for quick questions to Apple Intelligence's on-device model.
//

import AppKit
import SwiftUI

struct AssistantView: View {
    @ObservedObject var assistant = AssistantManager.shared
    @FocusState private var fieldFocused: Bool
    @State private var hostWindow: BoringNotchSkyLightWindow?
    /// Keeps the notch open while typing; see `beginTyping()`.
    @State private var holdsNotchOpen = false
    @State private var releaseTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 8) {
            conversation
            inputBar
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(HostWindowReader(window: $hostWindow))
        .onAppear(perform: handleFocusRequest)
        .onChange(of: assistant.focusRequested) { handleFocusRequest() }
        // Apply a pending focus once the window resolves; the reader reports asynchronously.
        .onChange(of: hostWindow) { _, window in
            if fieldFocused { window?.wantsKeyForTextInput = true }
        }
        .onChange(of: fieldFocused) { _, focused in
            if focused {
                beginTyping()
            } else {
                scheduleRelease()
            }
        }
        .onChange(of: assistant.isResponding) { _, responding in
            if !responding && !fieldFocused { scheduleRelease() }
        }
        .onExitCommand { endTyping() }
        // The one unambiguous "done" signal: the tab or the notch went away.
        .onDisappear { endTyping() }
    }

    // MARK: Conversation

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if assistant.messages.isEmpty {
                        placeholder
                    }
                    ForEach(assistant.messages) { message in
                        bubble(message).id(message.id)
                    }
                    if let error = assistant.error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.top, 4)
            }
            .onChange(of: assistant.messages) {
                withAnimation(.smooth(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    private var placeholder: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Ask anything", systemImage: "sparkles")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
            Text("Answers come from Apple Intelligence on this Mac. Nothing is sent online.")
                .font(.system(size: 11))
                .foregroundStyle(.gray)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
    }

    @ViewBuilder
    private func bubble(_ message: AssistantMessage) -> some View {
        switch message.role {
        case .user:
            Text(message.text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
                .frame(maxWidth: .infinity, alignment: .trailing)
                .textSelection(.enabled)
        case .action:
            if let action = message.action {
                actionCard(action, messageID: message.id)
            }
        case .assistant:
            Group {
                if message.text.isEmpty {
                    ProgressView().controlSize(.small)
                } else {
                    Text(Self.markdown(message.text))
                        .font(.system(size: 12))
                        .foregroundStyle(Color(white: 0.9))
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func actionCard(_ action: AssistantAction, messageID: UUID) -> some View {
        HStack(spacing: 8) {
            Image(systemName: action.undone ? "arrow.uturn.backward.circle" : (action.kind == .reminder ? "checklist" : "calendar.badge.plus"))
                .foregroundStyle(action.undone ? .gray : .green)
            VStack(alignment: .leading, spacing: 1) {
                Text(action.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(action.undone ? .gray : .white)
                    .strikethrough(action.undone)
                    .lineLimit(1)
                Text(action.undone
                     ? String(localized: "Removed")
                     : (action.kind == .reminder ? String(localized: "Reminder") : String(localized: "Calendar event"))
                        + (action.when.isEmpty ? "" : " · \(action.when)"))
                    .font(.system(size: 10))
                    .foregroundStyle(.gray)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if !action.undone {
                Button("Undo") { assistant.undo(messageID) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.white.opacity(0.14)))
            }
        }
        .padding(8)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }

    private static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }

    // MARK: Input

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("Ask Apple Intelligence…", text: $assistant.draft, axis: .horizontal)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($fieldFocused)
                .onSubmit(send)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color.white.opacity(0.08), in: Capsule())
                .overlay(Capsule().strokeBorder(Color.white.opacity(fieldFocused ? 0.18 : 0)))
                .animation(.easeOut(duration: 0.15), value: fieldFocused)

            // Real Buttons, not tap gestures: clicking blurs the field and flips
            // the window's key status mid-click, which swallows bare taps.
            if assistant.isResponding {
                iconButton("stop.fill", help: "Stop") { assistant.stop() }
            } else {
                iconButton("arrow.up", help: "Send", prominent: true, action: send)
                    .disabled(assistant.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            iconButton("square.and.pencil", help: "New conversation") {
                assistant.reset()
                fieldFocused = true
            }
            .disabled(assistant.messages.isEmpty)
        }
    }

    private func handleFocusRequest() {
        guard assistant.focusRequested else { return }
        assistant.focusRequested = false
        fieldFocused = true
    }

    private func send() {
        assistant.send()
        fieldFocused = true
    }

    private func iconButton(_ icon: String, help: LocalizedStringKey, prominent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(prominent ? .black : .white)
                .frame(width: 28, height: 28)
                .background(Circle().fill(prominent ? Color.white : Color.white.opacity(0.12)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: Keyboard and notch hold

    /// The notch window only takes keystrokes while it's key (see
    /// BoringNotchSkyLightWindow.wantsKeyForTextInput), and becoming key fires
    /// a spurious hover-exit, so the notch is held open while typing.
    private func beginTyping() {
        releaseTask?.cancel()
        releaseTask = nil
        hostWindow?.wantsKeyForTextInput = true
        if !holdsNotchOpen {
            holdsNotchOpen = true
            SharingStateManager.shared.beginInteraction()
        }
    }

    /// Focus flips for incidental reasons (clicking a button blurs the field),
    /// so the hold is only released if focus stays away for a moment.
    private func scheduleRelease() {
        releaseTask?.cancel()
        releaseTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, !fieldFocused, !assistant.isResponding else { return }
            releaseHold()
        }
    }

    private func releaseHold() {
        guard holdsNotchOpen else { return }
        holdsNotchOpen = false
        SharingStateManager.shared.endInteraction()
    }

    private func endTyping() {
        releaseTask?.cancel()
        releaseTask = nil
        fieldFocused = false
        releaseHold()
        guard let window = hostWindow else { return }
        window.wantsKeyForTextInput = false
        // Hand the keyboard back to the app the user was in.
        if window.isKeyWindow {
            NSWorkspace.shared.frontmostApplication?.activate()
        }
    }
}

/// Reports the notch window hosting a view.
private struct HostWindowReader: NSViewRepresentable {
    @Binding var window: BoringNotchSkyLightWindow?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { window = view.window as? BoringNotchSkyLightWindow }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if window == nil {
            DispatchQueue.main.async { window = nsView.window as? BoringNotchSkyLightWindow }
        }
    }
}
