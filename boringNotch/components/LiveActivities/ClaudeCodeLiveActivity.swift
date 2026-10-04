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
