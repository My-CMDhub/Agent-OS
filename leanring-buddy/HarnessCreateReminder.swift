//
//  HarnessCreateReminder.swift
//  leanring-buddy
//
//  `createReminder`: the Siri-shaped path (research 2026-10-21, owner's rulings the same day).
//  The model names only the task (and maybe a list); the due comes from the OWNER's words through
//  `ReminderDue.parse`, written as typed `DateComponents` through EventKit — no date is ever typed
//  where an app's parser gets a second guess. The receipt is a re-read by identifier from a FRESH
//  store, and only of the item this verb created (full access exposes every reminder; nothing else
//  is listed or read). Card-free, with a spoken read-back; a past time or a bare hour is asked.
//

import EventKit
import Foundation

nonisolated enum HarnessCreateReminder {
    static let remindersBundleIdentifier = "com.apple.reminders"
    static let maximumTitleLength = 300

    struct Failure: Error, Equatable {
        let code: String
        let message: String
    }

    struct Plan: Equatable {
        let title: String
        /// nil: no due. All-day carries year/month/day only; timed adds hour and minute.
        let due: DateComponents?
        /// The model's title held the owner's date words, and they were taken out.
        let titleWasCleaned: Bool
    }

    /// Owner's ruling 5: fixed, in the zone this Mac is in now. EventKit raises on a non-Gregorian calendar.
    static func fixedCalendar(timeZone: TimeZone = .current) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    static func titleProblem(_ title: String) -> String? {
        if title.count > maximumTitleLength { return "longer than \(maximumTitleLength) characters" }
        if title.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) { return "a control character" }
        return nil
    }

    /// The due from `heard` alone (never the model's title); the title cleaned of the matched date words.
    static func plan(title: String, heard: String, now: Date = Date(), calendar: Calendar = fixedCalendar()) -> Result<Plan, Failure> {
        let due = ReminderDue.parse(heard, now: now, calendar: calendar)
        let phrase = due.phrase.map { String(heard[$0]) }
        if case .ambiguous(let reason) = due.kind {
            return .failure(Failure(code: "reminderDueUnclear",
                                    message: "nothing was created: the owner's due time is unclear (\(reason)\(phrase.map { ", in \"\($0)\"" } ?? "")). "
                                        + "Ask the owner that one question with ask_owner, asking for the day and the time with am or pm, "
                                        + "then call create_reminder again"))
        }
        let cleaned = cleanedTitle(title, removing: phrase)
        guard !cleaned.isEmpty else {
            return .failure(Failure(code: "reminderTitleEmpty", message: "nothing was created: the title held only the date words; give the task itself as the title"))
        }
        if let problem = titleProblem(cleaned) { return .failure(Failure(code: "reminderTitleInvalid", message: "nothing was created: the title is \(problem)")) }
        return .success(Plan(title: cleaned, due: components(for: due.kind, calendar: calendar), titleWasCleaned: cleaned != collapsed(title)))
    }

    /// The owner's date words out of the model's title ("Call Mom at 5 pm today" -> "Call Mom"), and a
    /// connector left dangling at the end ("Call Mom at"). Case-insensitive; nothing else is changed.
    static func cleanedTitle(_ title: String, removing phrase: String?) -> String {
        var text = collapsed(title)
        if let phrase = phrase.map(collapsed), !phrase.isEmpty {
            text = collapsed(text.replacingOccurrences(of: phrase, with: " ", options: .caseInsensitive))
        }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:-\u{2013}\u{2014}"))
        for connector in [" at", " on", " by", " for", " due"] where text.lowercased().hasSuffix(connector) {
            text = String(text.dropLast(connector.count)).trimmingCharacters(in: CharacterSet(charactersIn: " ,;:-"))
        }
        return text
    }

    private static func collapsed(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// All-day = a date only (no hour or minute, which is what makes EventKit file it all-day).
    static func components(for kind: ReminderDue.Kind, calendar: Calendar) -> DateComponents? {
        func parts(_ date: Date, _ units: Set<Calendar.Component>) -> DateComponents {
            var components = calendar.dateComponents(units, from: date)
            components.calendar = calendar
            components.timeZone = calendar.timeZone
            return components
        }
        switch kind {
        case .none, .ambiguous: return nil
        case .allDay(let day): return parts(day, [.year, .month, .day])
        case .timed(let when): return parts(when, [.year, .month, .day, .hour, .minute])
        }
    }

    /// The one list named exactly `name`; nil when none or more than one (never "nearest").
    static func exactList(named name: String?, among titles: [String]) -> Int? {
        guard let name, !name.isEmpty else { return nil }
        let matches = titles.indices.filter { titles[$0] == name }
        return matches.count == 1 ? matches[0] : nil
    }

    /// Same day, and the same hour and minute when timed (EventKit may hand back more fields than were set).
    static func sameDue(_ read: DateComponents?, _ wanted: DateComponents?) -> Bool {
        guard let wanted else { return read == nil || (read?.year == nil && read?.day == nil) }
        guard let read else { return false }
        return read.year == wanted.year && read.month == wanted.month && read.day == wanted.day
            && read.hour == wanted.hour && read.minute == wanted.minute
    }

    /// "Call Mom, today at 5:00 pm, in Reminders." — said back to the owner instead of a card.
    static func spokenReadBack(title: String, due: DateComponents?, list: String, now: Date = Date(), calendar: Calendar = fixedCalendar()) -> String {
        var when = ", with no due date"
        if let due, let date = calendar.date(from: due) {
            let day = ReminderDue.day(date, now: now, calendar: calendar, locale: .current)
            when = due.hour == nil ? ", \(day) (all day)" : ", \(day) at \(ReminderDue.clockTime(date, calendar: calendar))"
        }
        return "\(title)\(when), in your \(list) list"
    }

    static var isAuthorized: Bool { EKEventStore.authorizationStatus(for: .reminder) == .fullAccess }

    /// Writes the reminder, then re-reads it by identifier from a fresh store. The response's
    /// `verification` is that read-back; a mismatch still names what was made (it exists).
    static func create(_ plan: Plan, listName: String?) -> (report: [String: Any], failure: Failure?) {
        guard isAuthorized else {
            return ([:], Failure(code: "remindersNotAuthorized",
                                 message: "J.A.R.V.I.S. has no full access to Reminders (status \(EKEventStore.authorizationStatus(for: .reminder).rawValue)); "
                                    + "nothing was created. Use the Reminders app instead"))
        }
        let store = EKEventStore()
        let lists = store.calendars(for: .reminder)
        var report: [String: Any] = [:]
        let list: EKCalendar
        if let index = exactList(named: listName, among: lists.map(\.title)) {
            list = lists[index]
        } else if let fallback = store.defaultCalendarForNewReminders() {
            list = fallback
            if let listName, !listName.isEmpty { report["listNote"] = "no one list is named \"\(listName)\"; it went into the default list" }
        } else {
            return ([:], Failure(code: "reminderNoList", message: "Reminders has no default list; nothing was created"))
        }
        let reminder = EKReminder(eventStore: store)
        reminder.title = plan.title
        reminder.calendar = list
        reminder.dueDateComponents = plan.due
        let calendar = plan.due?.calendar ?? fixedCalendar()
        let alarmDate = plan.due.flatMap { $0.hour == nil ? nil : calendar.date(from: $0) }
        if let alarmDate { reminder.addAlarm(EKAlarm(absoluteDate: alarmDate)) }
        do {
            try store.save(reminder, commit: true)
        } catch {
            return ([:], Failure(code: "reminderSaveFailed", message: "Reminders refused the write (\((error as NSError).code)); nothing was created"))
        }
        let identifier = reminder.calendarItemIdentifier
        report["identifier"] = identifier
        report["list"] = list.title
        // A fresh store sees only what reached the database; ask a few times before calling it unseen.
        // The store is held while its item is read: live 2026-10-21, `alarms` on an item whose temporary
        // store was already released threw inside EventKit (-[__NSSetM addObject:] nil) and aborted Clicky.
        let freshStore = EKEventStore()
        var read: EKReminder?
        for attempt in 0..<5 where read == nil {
            if attempt > 0 { Thread.sleep(forTimeInterval: 0.2) }
            read = freshStore.calendarItem(withIdentifier: identifier) as? EKReminder
        }
        guard let read else {
            return (report, Failure(code: "notObserved", message: "the reminder was saved but a fresh read could not find it"))
        }
        let checks: [String: Bool] = [
            "title": read.title == plan.title,
            "due": sameDue(read.dueDateComponents, plan.due),
            "list": read.calendar?.calendarIdentifier == list.calendarIdentifier,
            "incomplete": !read.isCompleted,
            "alarm": alarmDate == nil || read.alarms?.contains { $0.absoluteDate == alarmDate } == true
        ]
        report["readBack"] = checks
        report["readBackDue"] = read.dueDateComponents.map { [$0.year, $0.month, $0.day, $0.hour, $0.minute].map { $0 as Any? ?? NSNull() } } ?? NSNull()
        report["spoken"] = spokenReadBack(title: plan.title, due: plan.due, list: list.title)
        withExtendedLifetime(freshStore) {}
        let failed = checks.filter { !$0.value }.keys.sorted()
        return failed.isEmpty ? (report, nil)
            : (report, Failure(code: "notObserved", message: "the reminder was saved, but a fresh read differs in: \(failed.joined(separator: ", "))"))
    }

    /// Test cleanup (the probe's `--reminder-complete-title=`, the launch suite's): marks completed the
    /// incomplete reminders whose title `matches` — several only when `allowSeveral` (a "JARVIS " probe's
    /// leftovers), else ONLY when exactly one matches across every list, so a sole match is the one the
    /// test just made (the suite proved none before, one after). Never deleted; titles compared in
    /// process, never listed out.
    static func completeTestReminders(matching matches: @escaping (String) -> Bool, allowSeveral: Bool, done: @escaping (String) -> Void) {
        guard isAuthorized else { return done("notAuthorized") }
        let store = EKEventStore()
        store.fetchReminders(matching: store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)) { found in
            let mine = (found ?? []).filter { matches($0.title ?? "") }
            guard allowSeveral || mine.count == 1 else { return done("matched \(mine.count), completed 0 (refused: not exactly one)") }
            var saved = 0
            for reminder in mine {
                reminder.isCompleted = true
                if (try? store.save(reminder, commit: true)) != nil { saved += 1 }
            }
            withExtendedLifetime(store) {}
            done("matched \(mine.count), completed \(saved)")
        }
    }

    /// `--reminder-complete-title=`: a "JARVIS " title completes every exact match; any other title only a sole one.
    static func completeTestReminders(titled title: String, done: @escaping (String) -> Void) {
        completeTestReminders(matching: { $0 == title }, allowSeveral: title.hasPrefix("JARVIS "), done: done)
    }

    /// The launch suite's fallback when its AX checkbox press did not complete its reminder (E12/M02/M04
    /// 2026-10-21, EventKit-made rows: markedCompleted false x3): the sole incomplete reminder holding a phrase.
    nonisolated static func completeSoleTestReminder(containing phrases: [String]) -> Bool {
        final class Box: @unchecked Sendable { var line = "" }
        let box = Box(), semaphore = DispatchSemaphore(value: 0)
        completeTestReminders(matching: { title in phrases.contains { title.lowercased().contains($0) } }, allowSeveral: false) { line in
            box.line = line
            semaphore.signal()
        }
        return semaphore.wait(timeout: .now() + 5) == .success && box.line == "matched 1, completed 1"
    }
}
