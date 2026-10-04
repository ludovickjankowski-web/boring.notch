//
//  AssistantTools.swift
//  boringNotch
//
//  Tools the notch assistant can call: create a reminder, add a calendar
//  event, and read the schedule for a day. Everything goes through EventKit
//  on this Mac. Created items show up in the conversation with an Undo.
//

import EventKit
import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Something the assistant did on the user's behalf, shown as a card.
struct AssistantAction: Equatable {
    enum Kind { case reminder, event }
    let kind: Kind
    let title: String
    let when: String
    let itemIdentifier: String
    var undone = false
}

@MainActor
final class AssistantActions {
    static let shared = AssistantActions()

    private let store = EKEventStore()

    private init() {}

    /// The small model is unreliable at date arithmetic, so each message carries
    /// the current time and the dates of the coming week to copy from.
    static func dateContext(now: Date = Date()) -> String {
        let calendar = Calendar.current
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "EEEE yyyy-MM-dd"
        let time = DateFormatter()
        time.locale = Locale(identifier: "en_US_POSIX")
        time.dateFormat = "HH:mm"

        var entries: [String] = []
        for offset in 0...7 {
            guard let date = calendar.date(byAdding: .day, value: offset, to: now) else { continue }
            let label: String
            switch offset {
            case 0: label = "today"
            case 1: label = "tomorrow"
            default: label = offset == 7 ? "next \(day.weekdaySymbols[calendar.component(.weekday, from: date) - 1])" : day.weekdaySymbols[calendar.component(.weekday, from: date) - 1]
            }
            entries.append("\(label) = \(day.string(from: date))")
        }
        return "[Now: \(day.string(from: now)) \(time.string(from: now))]\n[Dates: \(entries.joined(separator: "; "))]\n"
    }

    /// Parses "yyyy-MM-dd HH:mm", "yyyy-MM-ddTHH:mm" (seconds optional) or "yyyy-MM-dd".
    static func parseDate(_ text: String) -> (date: Date, hasTime: Bool)? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "T", with: " ")
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for (format, hasTime) in [("yyyy-MM-dd HH:mm:ss", true), ("yyyy-MM-dd HH:mm", true), ("yyyy-MM-dd", false)] {
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) { return (date, hasTime) }
        }
        return nil
    }

    private func ensureAccess(to type: EKEntityType) async -> Bool {
        let status = EKEventStore.authorizationStatus(for: type)
        if status == .fullAccess || (type == .event && status == .writeOnly) { return true }
        guard status == .notDetermined else { return false }
        return (try? await (type == .event ? store.requestFullAccessToEvents() : store.requestFullAccessToReminders())) ?? false
    }

    func createReminder(title: String, due: String, notes: String) async -> String {
        guard await ensureAccess(to: .reminder) else {
            return "Could not create the reminder: Boring Notch has no access to Reminders. Tell the user to allow it in System Settings > Privacy & Security > Reminders."
        }
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.notes = notes.isEmpty ? nil : notes
        reminder.calendar = store.defaultCalendarForNewReminders()
        var when = ""
        if let (date, hasTime) = Self.parseDate(due) {
            var components = Calendar.current.dateComponents([.year, .month, .day], from: date)
            if hasTime {
                components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
                reminder.addAlarm(EKAlarm(absoluteDate: date))
            }
            reminder.dueDateComponents = components
            when = date.formatted(date: .abbreviated, time: hasTime ? .shortened : .omitted)
        }
        do {
            try store.save(reminder, commit: true)
        } catch {
            return "Could not create the reminder: \(error.localizedDescription)"
        }
        AssistantManager.shared.recordAction(AssistantAction(kind: .reminder, title: title, when: when, itemIdentifier: reminder.calendarItemIdentifier))
        return when.isEmpty ? "Created the reminder \"\(title)\"." : "Created the reminder \"\(title)\" for \(when)."
    }

    func createEvent(title: String, start: String, durationMinutes: Int, location: String) async -> String {
        guard let (startDate, hasTime) = Self.parseDate(start) else {
            return "Could not add the event: the start date \"\(start)\" is not in the yyyy-MM-ddTHH:mm format."
        }
        guard await ensureAccess(to: .event) else {
            return "Could not add the event: Boring Notch has no access to Calendars. Tell the user to allow it in System Settings > Privacy & Security > Calendars."
        }
        let event = EKEvent(eventStore: store)
        event.title = title
        event.location = location.isEmpty ? nil : location
        event.calendar = store.defaultCalendarForNewEvents
        event.startDate = startDate
        if hasTime {
            event.endDate = startDate.addingTimeInterval(TimeInterval(max(5, durationMinutes) * 60))
        } else {
            event.isAllDay = true
            event.endDate = startDate
        }
        do {
            try store.save(event, span: .thisEvent, commit: true)
        } catch {
            return "Could not add the event: \(error.localizedDescription)"
        }
        let when = startDate.formatted(date: .abbreviated, time: hasTime ? .shortened : .omitted)
        AssistantManager.shared.recordAction(AssistantAction(kind: .event, title: title, when: when, itemIdentifier: event.calendarItemIdentifier))
        return "Added \"\(title)\" to the calendar on \(when)."
    }

    func schedule(for day: String) async -> String {
        guard let (date, _) = Self.parseDate(day) else {
            return "The day \"\(day)\" is not in the yyyy-MM-dd format."
        }
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            return "Boring Notch can't read the calendar: access to Calendars isn't allowed."
        }
        let start = Calendar.current.startOfDay(for: date)
        guard let end = Calendar.current.date(byAdding: .day, value: 1, to: start) else { return "" }
        let ids = Array(CalendarManager.shared.selectedCalendarIDs)
        let items = await CalendarService().events(from: start, to: end, calendars: ids)
            .filter { if case .event(let status) = $0.type { return status != .declined } else { return true } }
            .sorted { $0.start < $1.start }
        guard !items.isEmpty else { return "Nothing is planned on \(day)." }
        let time = { (date: Date) in date.formatted(date: .omitted, time: .shortened) }
        return items.prefix(20).map { item in
            if item.isAllDay { return "- all day: \(item.title)" }
            if item.type.isReminder { return "- reminder at \(time(item.start)): \(item.title)" }
            return "- \(time(item.start))–\(time(item.end)): \(item.title)" + (item.location.map { " (\($0))" } ?? "")
        }.joined(separator: "\n")
    }

    /// Removes an item the assistant created.
    func undo(_ action: AssistantAction) -> Bool {
        guard let item = store.calendarItem(withIdentifier: action.itemIdentifier) else { return false }
        do {
            if let reminder = item as? EKReminder {
                try store.remove(reminder, commit: true)
            } else if let event = item as? EKEvent {
                try store.remove(event, span: .thisEvent, commit: true)
            }
            return true
        } catch {
            AppleIntelligence.logger.error("Undo failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}

#if canImport(FoundationModels)
@available(macOS 26.0, *)
enum AssistantTools {
    static var all: [any Tool] { [CreateReminderTool(), CreateEventTool(), ReadCalendarTool()] }
}

@available(macOS 26.0, *)
struct CreateReminderTool: Tool {
    let name = "createReminder"
    let description = "Creates a reminder in the user's Reminders app. Use it when the user asks to be reminded of something or to note a to-do."

    @Generable
    struct Arguments {
        @Guide(description: "Short title of the reminder, in the user's language")
        var title: String
        @Guide(description: "When it is due, as yyyy-MM-ddTHH:mm taken from the date table, yyyy-MM-dd for a day without time, or an empty string")
        var due: String
        @Guide(description: "Extra details, or an empty string")
        var notes: String
    }

    func call(arguments: Arguments) async throws -> String {
        await AssistantActions.shared.createReminder(title: arguments.title, due: arguments.due, notes: arguments.notes)
    }
}

@available(macOS 26.0, *)
struct CreateEventTool: Tool {
    let name = "createEvent"
    let description = "Adds an event to the user's calendar: meetings, appointments, meals and plans at a given time."

    @Generable
    struct Arguments {
        @Guide(description: "Event title, in the user's language")
        var title: String
        @Guide(description: "Start, as yyyy-MM-ddTHH:mm taken from the date table, or yyyy-MM-dd for an all-day event")
        var start: String
        @Guide(description: "Duration in minutes; 60 if the user didn't say", .range(5...1440))
        var durationMinutes: Int
        @Guide(description: "Location, or an empty string")
        var location: String
    }

    func call(arguments: Arguments) async throws -> String {
        await AssistantActions.shared.createEvent(
            title: arguments.title,
            start: arguments.start,
            durationMinutes: arguments.durationMinutes,
            location: arguments.location
        )
    }
}

@available(macOS 26.0, *)
struct ReadCalendarTool: Tool {
    let name = "readCalendar"
    let description = "Reads the user's calendar. You know nothing about the user's agenda without it: call it for ANY question about what is planned, meetings, events, appointments or free time on a day."

    @Generable
    struct Arguments {
        @Guide(description: "The day, as yyyy-MM-dd taken from the date table")
        var day: String
    }

    func call(arguments: Arguments) async throws -> String {
        await AssistantActions.shared.schedule(for: arguments.day)
    }
}
#endif
