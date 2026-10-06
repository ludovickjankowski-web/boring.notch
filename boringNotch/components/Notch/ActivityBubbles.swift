//
//  ActivityBubbles.swift
//  boringNotch
//
//  When several live activities run at once, the one in front fills the
//  closed notch and the others sit beside it as small round bubbles, like the
//  iPhone's Dynamic Island. Clicking a bubble brings that activity to front.
//

import SwiftUI

struct ActivityBubbles: View {
    let items: [LiveActivityItem]
    /// Height of the closed notch; bubbles are a little smaller so they read
    /// as separate from it.
    let notchHeight: CGFloat
    let select: (LiveActivityItem) -> Void

    static let gap: CGFloat = 6
    static let spacing: CGFloat = 5

    static func diameter(forNotchHeight height: CGFloat) -> CGFloat {
        max(18, height - 4)
    }

    static func width(count: Int, notchHeight: CGFloat) -> CGFloat {
        guard count > 0 else { return 0 }
        return CGFloat(count) * diameter(forNotchHeight: notchHeight) + CGFloat(count - 1) * spacing
    }

    var body: some View {
        let diameter = Self.diameter(forNotchHeight: notchHeight)
        HStack(spacing: Self.spacing) {
            ForEach(items) { item in
                Button {
                    select(item)
                } label: {
                    ActivityBubble(item: item, diameter: diameter)
                }
                .buttonStyle(.plain)
                .transition(.scale(scale: 0.3).combined(with: .opacity))
            }
        }
        .frame(height: notchHeight)
        .animation(.smooth(duration: 0.3), value: items)
    }
}

private struct ActivityBubble: View {
    let item: LiveActivityItem
    let diameter: CGFloat
    @ObservedObject private var music = MusicManager.shared
    @ObservedObject private var pomodoro = PomodoroManager.shared
    @ObservedObject private var claudeCode = ClaudeCodeMonitor.shared
    @State private var isHovering = false

    var body: some View {
        ZStack {
            Circle().fill(.black)
            content
        }
        .frame(width: diameter, height: diameter)
        .scaleEffect(isHovering ? 1.08 : 1)
        .animation(.smooth(duration: 0.15), value: isHovering)
        .onHover { isHovering = $0 }
        .help(help)
    }

    @ViewBuilder
    private var content: some View {
        let inner = diameter - 8
        switch item {
        case .music:
            Image(nsImage: music.albumArt)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: inner, height: inner)
                .clipShape(Circle())
                .opacity(music.isPlaying ? 1 : 0.5)
        case .pomodoro:
            ZStack {
                PomodoroRing(progress: pomodoro.progress, tint: pomodoro.phase.tint, lineWidth: 2.5)
                Image(systemName: pomodoro.phase.icon)
                    .font(.system(size: inner * 0.38, weight: .semibold))
                    .foregroundStyle(pomodoro.phase.tint)
            }
            .frame(width: inner - 2, height: inner - 2)
        case .claudeCode:
            Image(systemName: "terminal.fill")
                .font(.system(size: inner * 0.5, weight: .semibold))
                .foregroundStyle(claudeCode.visibleSessions.first?.state.tint ?? .gray)
        case .notification:
            Image(systemName: "bell.fill")
                .font(.system(size: inner * 0.5, weight: .semibold))
                .foregroundStyle(.white)
        }
    }

    private var help: String {
        switch item {
        case .music:
            return music.songTitle.isEmpty ? String(localized: "Music") : "\(music.songTitle) – \(music.artistName)"
        case .pomodoro:
            return String(localized: "Timer")
        case .claudeCode:
            return claudeCode.visibleSessions.first.map { "\($0.project) · \($0.state.label)" } ?? "Claude Code"
        case .notification(let notification):
            return notification.appName ?? String(localized: "Notification")
        }
    }
}
