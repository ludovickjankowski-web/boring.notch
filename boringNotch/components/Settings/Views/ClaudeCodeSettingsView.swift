//
//  ClaudeCodeSettingsView.swift
//  boringNotch
//

import AppKit
import Defaults
import SwiftUI

struct ClaudeCodeSettingsView: View {
    @Default(.enableClaudeCodeMonitor) var enabled
    @Default(.claudeCodePort) var port
    // Observed so the configuration re-renders when the token is regenerated.
    @Default(.claudeCodeToken) var token
    @ObservedObject var monitor = ClaudeCodeMonitor.shared
    @State private var copied = false

    var body: some View {
        Form {
            Section {
                Defaults.Toggle(key: .enableClaudeCodeMonitor) {
                    Text("Show Claude Code sessions in the notch")
                }
                if enabled {
                    if let error = monitor.listenerError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.caption)
                    } else if monitor.isListening {
                        Label {
                            Text("Listening on 127.0.0.1:\(String(port))", comment: "Status shown when the Claude Code hook listener is running.")
                        } icon: {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        }
                        .font(.caption)
                    }
                }
            } header: {
                Text("General")
            } footer: {
                Text(
                    "Each session appears as a dot in the closed notch: green while Claude is working, orange when it needs you, blue when it has finished.",
                    comment: "Footer explaining the Claude Code session indicators."
                )
                .foregroundStyle(.secondary)
                .font(.caption)
            }

            Section {
                TextField(value: $port, format: .number.grouping(.never)) {
                    Text("Port", comment: "Local port the Claude Code hooks send events to.")
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(
                        "Merge this into ~/.claude/settings.json, then restart your Claude Code sessions:",
                        comment: "Instruction above the Claude Code hooks configuration."
                    )
                    .font(.callout)
                    ScrollView {
                        Text(ClaudeCodeMonitor.hooksConfiguration)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 140)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(ClaudeCodeMonitor.hooksConfiguration, forType: .string)
                        copied = true
                    } label: {
                        Label(copied ? "Copied" : "Copy configuration", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                }
                Button(role: .destructive) {
                    token = ""
                    _ = ClaudeCodeMonitor.token
                    copied = false
                } label: {
                    Text("Regenerate token", comment: "Button creating a new secret for the Claude Code hooks.")
                }
            } header: {
                Text("Claude Code hooks")
            } footer: {
                Text(
                    "Events are only accepted from this Mac, and only with the secret token in the configuration. Regenerating the token requires updating the configuration.",
                    comment: "Footer explaining how the Claude Code hook endpoint is secured."
                )
                .foregroundStyle(.secondary)
                .font(.caption)
            }
            .disabled(!enabled)
        }
        .accentColor(.effectiveAccent)
        .navigationTitle("Claude Code")
        .onChange(of: port) { copied = false }
    }
}
