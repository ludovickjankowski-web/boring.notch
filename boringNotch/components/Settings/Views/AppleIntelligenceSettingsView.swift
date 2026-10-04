//
//  AppleIntelligenceSettingsView.swift
//  boringNotch
//

import Defaults
import KeyboardShortcuts
import SwiftUI

struct AppleIntelligenceSettingsView: View {
    @Default(.enableAssistant) var assistantEnabled
    private let available = AppleIntelligence.isAvailable

    var body: some View {
        Form {
            Section {
                if available {
                    Label {
                        Text("Apple Intelligence is ready. Everything runs on this Mac; nothing is sent online.")
                    } icon: {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                } else {
                    Label {
                        Text(AppleIntelligence.unavailableReason ?? "")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                }
            } header: {
                Text("Status")
            }

            Section {
                Defaults.Toggle(key: .enableAssistant) {
                    Text("Show Assistant tab")
                }
                KeyboardShortcuts.Recorder("Ask a question:", name: .openAssistant)
                    .disabled(!assistantEnabled)
            } header: {
                Text("Assistant")
            } footer: {
                Text(
                    "Ask quick questions right from the notch. Press Escape or move away to give the keyboard back.",
                    comment: "Footer explaining the notch assistant."
                )
                .foregroundStyle(.secondary)
                .font(.caption)
            }

            Section {
                Defaults.Toggle(key: .enableDailyBrief) {
                    Text("Daily brief above the calendar")
                }
                Defaults.Toggle(key: .enableAIShelf) {
                    Text("Summarize, translate and find actions in shelf items")
                }
                Defaults.Toggle(key: .enableAITeleprompter) {
                    Text("Script assistant in Teleprompter settings")
                }
            } header: {
                Text("Features")
            } footer: {
                Text(
                    "Shelf actions are in the item's right-click menu. The daily brief needs calendar access.",
                    comment: "Footer explaining where Apple Intelligence features appear."
                )
                .foregroundStyle(.secondary)
                .font(.caption)
            }
        }
        .disabled(!available)
        .accentColor(.effectiveAccent)
        .navigationTitle("Apple Intelligence")
    }
}
