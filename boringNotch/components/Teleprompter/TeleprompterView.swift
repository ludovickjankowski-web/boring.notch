//
//  TeleprompterView.swift
//  boringNotch
//
//  Open-notch tab that scrolls a script right under the camera.
//

import Defaults
import SwiftUI

struct TeleprompterView: View {
    @ObservedObject var prompter = TeleprompterManager.shared
    @Default(.teleprompterText) var script
    @Default(.teleprompterSpeed) var speed
    @Default(.teleprompterFontSize) var fontSize

    /// Narrow column centred under the camera keeps your gaze near the lens.
    private let columnWidth: CGFloat = 360
    private let nudge: CGFloat = 40

    var body: some View {
        HStack(spacing: 12) {
            VStack(spacing: 8) {
                controlButton("textformat.size.smaller", help: "Smaller text") {
                    fontSize = max(TeleprompterManager.fontSizeRange.lowerBound, fontSize - 2)
                }
                controlButton("textformat.size.larger", help: "Larger text") {
                    fontSize = min(TeleprompterManager.fontSizeRange.upperBound, fontSize + 2)
                }
                controlButton("square.and.pencil", help: "Edit script") {
                    SettingsWindowController.shared.showWindow()
                }
            }

            scrollingScript
                .frame(width: columnWidth)
                .frame(maxHeight: .infinity)

            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    controlButton("backward.fill", help: "Back") { prompter.scrub(by: -nudge) }
                    controlButton(prompter.isRunning ? "pause.fill" : "play.fill", help: prompter.isRunning ? "Pause" : "Start", prominent: true) {
                        prompter.toggle()
                    }
                    controlButton("forward.fill", help: "Forward") { prompter.scrub(by: nudge) }
                }
                HStack(spacing: 8) {
                    controlButton("minus", help: "Slower") {
                        speed = max(TeleprompterManager.speedRange.lowerBound, speed - 10)
                    }
                    Text("\(Int(speed))")
                        .font(.system(.caption, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.gray)
                        .frame(width: 30)
                    controlButton("plus", help: "Faster") {
                        speed = min(TeleprompterManager.speedRange.upperBound, speed + 10)
                    }
                }
                controlButton("arrow.counterclockwise", help: "Back to start") { prompter.reset() }
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Leaving the tab must release the notch, which stays open while scrolling.
        .onDisappear { prompter.pause() }
    }

    private var scrollingScript: some View {
        TimelineView(.animation(paused: !prompter.isRunning)) { context in
            GeometryReader { geo in
                Text(script.isEmpty ? String(localized: "Add your script in Settings > Teleprompter.") : script)
                    .font(.system(size: fontSize, weight: .semibold, design: .rounded))
                    .foregroundStyle(script.isEmpty ? .gray : .white)
                    .lineSpacing(fontSize * 0.25)
                    .multilineTextAlignment(.center)
                    .frame(width: geo.size.width)
                    .fixedSize(horizontal: false, vertical: true)
                    .background {
                        GeometryReader { text in
                            Color.clear.preference(key: ScriptHeightKey.self, value: text.size.height)
                        }
                    }
                    // Start a little below the top edge so the first line is readable before scrolling.
                    .offset(y: 12 - prompter.offset(at: context.date))
            }
            .clipped()
            .mask {
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: 0.12),
                        .init(color: .black, location: 0.8),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
        .onPreferenceChange(ScriptHeightKey.self) { height in
            prompter.contentHeight = height
        }
    }

    private func controlButton(_ icon: String, help: LocalizedStringKey, prominent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: prominent ? 15 : 12, weight: .semibold))
                .foregroundStyle(prominent ? .black : .white)
                .frame(width: prominent ? 36 : 28, height: prominent ? 36 : 28)
                .background(Circle().fill(prominent ? Color.white : Color.white.opacity(0.12)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

private struct ScriptHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
