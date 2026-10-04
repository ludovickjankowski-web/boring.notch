//
//  DailyBriefManager.swift
//  boringNotch
//
//  A one-line summary of what's left on today's calendar, written by the
//  on-device model and shown above the calendar in the open notch. It is
//  regenerated only when the remaining schedule actually changes.
//

import Defaults
import EventKit
import Foundation

@MainActor
final class DailyBriefManager: ObservableObject {
    static let shared = DailyBriefManager()

    @Published private(set) var brief: String?

    private let calendarService = CalendarService()
    private var signature: String?
    private var task: Task<Void, Never>?

    private init() {}

    private var isEnabled: Bool {
        Defaults[.enableDailyBrief] && AppleIntelligence.isAvailable
            && EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    func refreshIfNeeded() {
        guard isEnabled else {
            brief = nil
            signature = nil
            return
        }
        guard task == nil else { return }
        task = Task {
            defer { task = nil }
            let facts = await todaysFacts()
            guard (facts ?? "") != signature else { return }

            guard let facts else {
                signature = ""
                brief = String(localized: "Nothing left on your calendar today.")
                return
            }
            let language = AppleIntelligence.userLanguageName
            do {
                // The facts are worked out here; the small model is unreliable
                // at counting and comparing times, so it only phrases them.
                brief = try await AppleIntelligence.respond(
                    instructions: """
                    You turn facts about someone's remaining day into one short, friendly sentence for a widget \
                    (at most 20 words). Use only the facts given, keep the numbers and times exactly, and do not \
                    list every item. Write in \(language). No greeting, no markdown, no emoji.
                    """,
                    prompt: "Facts:\n\(facts)\n\nWrite the sentence in \(language).",
                    temperature: 0.3
                )
                signature = facts
            } catch {
                AppleIntelligence.logger.error("Daily brief failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// What's left today as a few plain facts, or nil when nothing is.
    private func todaysFacts() async -> String? {
        let now = Date()
        let items = await remainingItems(now: now)
        guard !items.isEmpty else { return nil }

        let time = { (date: Date) in date.formatted(date: .omitted, time: .shortened) }
        let timed = items.filter { !$0.isAllDay }
        var facts = ["- Things left today: \(items.count)"]

        if let current = timed.first(where: { $0.type.isEvent && $0.start <= now }) {
            facts.append("- Happening now: \"\(current.title)\" until \(time(current.end))")
        }
        if let next = timed.first(where: { $0.start > now }) {
            facts.append("- Next: \"\(next.title)\" at \(time(next.start))")
        }
        let allDay = items.filter(\.isAllDay).map { "\"\($0.title)\"" }
        if !allDay.isEmpty {
            facts.append("- All day: " + allDay.joined(separator: ", "))
        }

        // Longest gap of at least an hour between upcoming events.
        let busy = timed.filter { $0.type.isEvent && $0.end > now }.sorted { $0.start < $1.start }
        var longest: (start: Date, end: Date)?
        var busyUntil = busy.first?.end
        for event in busy.dropFirst() {
            if let until = busyUntil, event.start.timeIntervalSince(until) >= 3600,
               event.start.timeIntervalSince(until) > (longest.map { $0.end.timeIntervalSince($0.start) } ?? 0) {
                longest = (until, event.start)
            }
            busyUntil = max(busyUntil ?? event.end, event.end)
        }
        if let longest {
            facts.append("- Longest free stretch: \(time(longest.start)) to \(time(longest.end))")
        }
        if let last = timed.max(by: { $0.end < $1.end }) {
            facts.append("- Last thing ends at \(time(last.type.isReminder ? last.start : last.end))")
        }
        return facts.joined(separator: "\n")
    }

    /// Today's events and reminders that haven't finished yet.
    private func remainingItems(now: Date) async -> [EventModel] {
        let start = Calendar.current.startOfDay(for: now)
        guard let end = Calendar.current.date(byAdding: .day, value: 1, to: start) else { return [] }
        let ids = Array(CalendarManager.shared.selectedCalendarIDs)
        let events = await calendarService.events(from: start, to: end, calendars: ids)

        return events
            .filter { event in
                switch event.type {
                case .event(let status) where status == .declined: return false
                case .reminder(let completed) where completed: return false
                default: break
                }
                return event.isAllDay || event.end > now || (event.type.isReminder && event.start > now)
            }
            .sorted { $0.start < $1.start }
    }
}
