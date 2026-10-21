//
//  LaunchSuiteEventKitTruth.swift
//  leanring-buddy
//
//  The launch suite's Calendar/Reminders truth, read from EventKit (read-only, a fresh store per read)
//  instead of the apps' windows. 2026-10-21T09-08-34Z skipped E03/E13 ("Calendar did not show tomorrow
//  in a month grid") and E12 ("Today count unreadable") because a VIEW decided the truth; the database
//  does not depend on which view is up. Readings come back in the AX rows' own shapes ("<Title>. Starts on
//  <day> at 3:00 pm", "Incomplete, <title>, <list>, <due>") so every verdict stays as it was measured.
//  Without full access the AX read runs and the evidence says so (`truthSource`).
//

import EventKit
import Foundation

extension GeneralitySuite {
    nonisolated static func eventKitReady(_ type: EKEntityType) -> Bool {
        EKEventStore.authorizationStatus(for: type) == .fullAccess
    }

    nonisolated static func truthSource(_ type: EKEntityType) -> String {
        eventKitReady(type) ? "eventKit"
            : "accessibility (EventKit status \(EKEventStore.authorizationStatus(for: type).rawValue), not fullAccess)"
    }

    /// EventKit when fully authorised (no app launched); else the AX read, launching the app behind if needed.
    static func truthRead<T: Sendable>(_ type: EKEntityType, _ bundle: String, eventKit: @escaping @Sendable () -> T?,
                                       accessibility: @escaping @Sendable () -> T?) async -> T? {
        eventKitReady(type) ? (await read(eventKit) ?? nil) : await readLaunchingIfNeeded(bundle, accessibility)
    }

    // MARK: events

    /// Calendar's own event description, as E03/E13 measured it on the month grid.
    nonisolated static func eventDescription(title: String, start: Date, allDay: Bool, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("dMMMMyyyy")
        let day = formatter.string(from: start)
        return allDay ? "\(title). \(day), All Day" : "\(title). Starts on \(day) at \(ReminderDue.clockTime(start, calendar: calendar))"
    }

    /// Every event overlapping tomorrow, in all calendars; nil without full access.
    nonisolated static func eventKitTomorrowEvents(now: Date = Date()) -> [String]? {
        guard eventKitReady(.event) else { return nil }
        let calendar = Calendar.current
        guard let start = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)),
              let end = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
        let store = EKEventStore()
        let events = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
        let read = events.map { eventDescription(title: $0.title ?? "", start: $0.startDate, allDay: $0.isAllDay) }
        withExtendedLifetime(store) {}
        return read
    }

    // MARK: reminders

    nonisolated struct IncompleteReminder: Sendable, Equatable {
        let title: String
        let list: String
        let due: DateComponents?
    }

    /// Every incomplete reminder in every list (read in process; only matches leave it); nil without full access or on a 5 s timeout.
    nonisolated static func eventKitIncompleteReminders() -> [IncompleteReminder]? {
        guard eventKitReady(.reminder) else { return nil }
        final class Box: @unchecked Sendable { var found: [IncompleteReminder]? }
        let box = Box(), semaphore = DispatchSemaphore(value: 0), store = EKEventStore()
        store.fetchReminders(matching: store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)) { found in
            box.found = (found ?? []).map { IncompleteReminder(title: $0.title ?? "", list: $0.calendar?.title ?? "", due: $0.dueDateComponents) }
            semaphore.signal()
        }
        let done = semaphore.wait(timeout: .now() + 5) == .success
        withExtendedLifetime(store) {}
        return done ? box.found : nil
    }

    /// ", <list>, Today at 5:00 pm" — the AX row's text after its title (`dueText`); ", <list>" undated.
    nonisolated static func reminderDueText(_ reminder: IncompleteReminder, now: Date = Date()) -> String {
        guard let due = reminder.due, let date = (due.calendar ?? .current).date(from: due) else { return ", \(reminder.list)" }
        let day = ReminderDue.day(date, now: now, calendar: .current, locale: .current)
        return ", \(reminder.list), " + (due.hour == nil ? day : "\(day) at \(ReminderDue.clockTime(date, calendar: .current))")
    }

    nonisolated static func reminderRow(_ reminder: IncompleteReminder, now: Date = Date()) -> String {
        "Incomplete, \(reminder.title)" + reminderDueText(reminder, now: now)
    }

    /// E12's reading: Today = incomplete reminders due by the end of today (the smart list holds overdue ones too).
    nonisolated static func remindersTodayRead(_ all: [IncompleteReminder], now: Date = Date()) -> RemindersToday {
        let endOfToday = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: now)) ?? now
        let today = all.filter { r in r.due.flatMap { ($0.calendar ?? .current).date(from: $0) }.map { $0 < endOfToday } ?? false }.count
        let calls = all.filter { folded($0.title).contains("call mom") }
        return RemindersToday(today: today, callMom: calls.map { reminderRow($0, now: now) }, callMomDue: calls.map { reminderDueText($0, now: now) })
    }

    nonisolated static func matching(_ all: [IncompleteReminder], _ phrases: [String]) -> [IncompleteReminder] {
        all.filter { r in phrases.contains { folded(r.title).contains($0) } }
    }

    /// E04's reading by list title, whatever Reminders shows: Shopping's incomplete count (0 with no such list),
    /// its title when it exists, and its incomplete titles.
    nonisolated static func shoppingRead(_ all: [IncompleteReminder], listTitles: [String]) -> (count: Int?, shown: String?, items: [String]) {
        let mine = all.filter { $0.list.lowercased() == shoppingListName }
        return (mine.count, listTitles.first { $0.lowercased() == shoppingListName }, mine.map(\.title))
    }

    nonisolated static func eventKitShoppingList() -> (count: Int?, shown: String?, items: [String])? {
        guard let all = eventKitIncompleteReminders() else { return nil }
        let store = EKEventStore()
        let titles = store.calendars(for: .reminder).map(\.title)
        withExtendedLifetime(store) {}
        return shoppingRead(all, listTitles: titles)
    }
}
