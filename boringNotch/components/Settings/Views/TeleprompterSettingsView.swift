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
}
