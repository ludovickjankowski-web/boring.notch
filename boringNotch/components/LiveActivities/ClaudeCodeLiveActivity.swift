//
//  ClaudeCodeLiveActivity.swift
//  boringNotch
//
//  Closed-notch status for Claude Code sessions reported by ClaudeCodeMonitor.
//

import SwiftUI

extension ClaudeCodeSessionState {
    var tint: Color {
        switch self {
        case .working: return .green
        case .waiting: return .orange
        case .done: return .blue
        case .idle: return .gray
        }
    }

    var label: String {
        switch self {
        case .working: return String(localized: "Working")
        case .waiting: return String(localized: "Needs you")
        case .done: return String(localized: "Done")
        case .idle: return String(localized: "Idle")
        }
    }
}

struct ClaudeCodeLiveActivity: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject var monitor = ClaudeCodeMonitor.shared
    @ObservedObject var coordinator = BoringViewCoordinator.shared

    static let sideWidth: CGFloat = 44
    static let announcementWidth: CGFloat = 150

    private var isAnnouncing: Bool {
        coordinator.expandingView.show && coordinator.expandingView.type == .claudeCode
    }

    var body: some View {
        let sessions = monitor.visibleSessions
        let lead = sessions.first
        let iconSize = max(0, vm.effectiveClosedNotchHeight - 12)

        HStack {
            Image(systemName: "terminal.fill")
                .font(.system(size: iconSize * 0.6, weight: .semibold))
                .foregroundStyle(lead?.state.tint ?? .gray)
                .frame(width: iconSize, height: iconSize)
                .frame(width: isAnnouncing ? Self.announcementWidth : Self.sideWidth, alignment: .leading)
                .overlay(alignment: .trailing) {
                    if isAnnouncing, let lead {
                        Text(lead.project)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(width: Self.announcementWidth - iconSize - 6, alignment: .leading)
                            .transition(.blurReplace)
                    }
                }

            Rectangle()
                .fill(.black)
                .frame(width: vm.closedNotchSize.width - 4 + 2 * liveActivityEdgeMargin)

            Group {
                if isAnnouncing, let lead {
                    Text(lead.state.label)
                        .foregroundStyle(lead.state.tint)
                        .lineLimit(1)
                        .transition(.blurReplace)
                } else {
                    sessionIndicators(sessions)
                }
            }
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .frame(width: isAnnouncing ? Self.announcementWidth : Self.sideWidth, alignment: .trailing)
        }
        .frame(height: vm.effectiveClosedNotchHeight, alignment: .center)
        .animation(.smooth, value: isAnnouncing)
        .animation(.smooth, value: sessions)
    }

    /// One dot per session (up to four), pulsing while Claude is working.
    @ViewBuilder
    private func sessionIndicators(_ sessions: [ClaudeCodeSession]) -> some View {
        HStack(spacing: 4) {
            ForEach(sessions.prefix(4)) { session in
                StatusDot(color: session.state.tint, pulsing: session.state == .working)
            }
        }
    }
}

private struct StatusDot: View {
    let color: Color
    let pulsing: Bool
    @State private var dimmed = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .opacity(pulsing && dimmed ? 0.35 : 1)
            .onAppear { updateAnimation() }
            .onChange(of: pulsing) { updateAnimation() }
    }

    private func updateAnimation() {
        if pulsing {
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { dimmed = true }
        } else {
            withAnimation(.smooth) { dimmed = false }
        }
    }
}

/// Open-notch prompt for a tool call Claude Code wants to make.
struct ClaudeCodePermissionView: View {
    let request: ClaudeCodePermissionRequest
    @ObservedObject var monitor = ClaudeCodeMonitor.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "terminal.fill")
                    .foregroundStyle(.orange)
                Text(request.project)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text("wants to use \(request.toolName)", comment: "Claude Code permission prompt, e.g. 'wants to use Bash'.")
                    .foregroundStyle(.gray)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if monitor.pendingPermissions.count > 1 {
                    Text("+\(monitor.pendingPermissions.count - 1)")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.gray)
                        .help("More requests are waiting")
                }
            }
            .font(.system(size: 13))

            if !request.detail.isEmpty {
                ScrollView(.vertical, showsIndicators: false) {
                    Text(request.detail)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color(white: 0.85))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 44)
                .padding(8)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }

            HStack(spacing: 8) {
                Button {
                    monitor.resolve(request.id, with: .askInTerminal)
                } label: {
                    Text("Answer in Terminal")
                        .font(.system(size: 11))
                        .foregroundStyle(.gray)
                }
                .buttonStyle(.plain)
                .help("Let Claude Code ask in the terminal instead")

                Spacer()

                decisionButton("Deny", systemImage: "xmark", prominent: false) {
                    monitor.resolve(request.id, with: .deny)
                }
                decisionButton("Allow", systemImage: "checkmark", prominent: true) {
                    monitor.resolve(request.id, with: .allow)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func decisionButton(_ title: LocalizedStringKey, systemImage: String, prominent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(prominent ? .black : .white)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Capsule().fill(prominent ? Color.white : Color.white.opacity(0.14)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
