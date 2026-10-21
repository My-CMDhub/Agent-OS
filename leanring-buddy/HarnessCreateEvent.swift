//
//  HarnessCreateEvent.swift
//  leanring-buddy
//
//  `createEvent`: a calendar event the way `createReminder` makes a reminder (owner's ruling
//  2026-10-21: API-first, card-free, no invitees). The model names only the event (and maybe a
//  calendar, matched exactly); the start comes from the OWNER's words through `ReminderDue.parse`,
//  an hour long unless their words gave a range the detector reads as one ("3 to 4 pm"). An event
//  needs a time, so no time or an unclear one refuses with the question to ask. The receipt is a
//  re-read by identifier from a fresh store, of this one event only. Calendars are never created,
//  renamed or listed out, and no attendee is ever added (EventKit cannot send an invitation anyway).
//

import EventKit
import Foundation

nonisolated enum HarnessCreateEvent {
    static let calendarBundleIdentifier = "com.apple.iCal"
    static let defaultDuration: TimeInterval = 3600
    typealias Failure = HarnessCreateReminder.Failure

    struct Plan: Equatable {
        let title: String
        let start: Date
        /// All-day: the start's day (EventKit spans the day itself).
        let end: Date
        let allDay: Bool
        let titleWasCleaned: Bool
    }

    /// The start from `heard` alone (never the model's title); the title cleaned of the matched date words.
    static func plan(title: String, heard: String, now: Date = Date(),
                     calendar: Calendar = HarnessCreateReminder.fixedCalendar()) -> Result<Plan, Failure> {
        let due = ReminderDue.parse(heard, now: now, calendar: calendar)
        let phrase = due.phrase.map { String(heard[$0]) }
        let ask = "Ask the owner that one question with ask_owner, asking for the day and the start time with am or pm, then call create_event again"
        let start: Date, allDay: Bool
        switch due.kind {
        case .ambiguous(let reason):
            return .failure(Failure(code: "eventTimeUnclear", message: "nothing was created: the owner's time is unclear (\(reason)"
                                        + "\(phrase.map { ", in \"\($0)\"" } ?? "")). " + ask))
        case .none:
            return .failure(Failure(code: "eventTimeMissing", message: "nothing was created: an event needs a day and a time, and the owner's words give none. " + ask))
        case .allDay(let day): (start, allDay) = (day, true)
        case .timed(let when): (start, allDay) = (when, false)
        }
        let cleaned = HarnessCreateReminder.cleanedTitle(title, removing: phrase)
        guard !cleaned.isEmpty else {
            return .failure(Failure(code: "eventTitleEmpty", message: "nothing was created: the title held only the date words; give the event's name as the title"))
        }
        if let problem = HarnessCreateReminder.titleProblem(cleaned) { return .failure(Failure(code: "eventTitleInvalid", message: "nothing was created: the title is \(problem)")) }
        // "tomorrow 3 to 4 pm" is ONE detector match carrying a duration (probe 2026-10-21); else an hour.
        let said = phrase.flatMap { ReminderDue.matches(in: $0).first?.duration }.flatMap { $0 > 0 ? $0 : nil }
        return .success(Plan(title: cleaned, start: start, end: allDay ? start : start.addingTimeInterval(said ?? defaultDuration),
                             allDay: allDay, titleWasCleaned: cleaned != HarnessCreateReminder.cleanedTitle(title, removing: nil)))
    }

    /// Same start and end to the second when timed; the same day and all-day otherwise.
    static func matches(_ plan: Plan, start: Date, end: Date, allDay: Bool, calendar: Calendar) -> [String: Bool] {
        plan.allDay
            ? ["allDay": allDay, "start": calendar.isDate(start, inSameDayAs: plan.start), "end": true]
            : ["allDay": !allDay, "start": abs(start.timeIntervalSince(plan.start)) < 1, "end": abs(end.timeIntervalSince(plan.end)) < 1]
    }

    /// "JARVIS test meeting, Tomorrow from 3:00 pm to 4:00 pm, in your Home calendar."
    static func spokenReadBack(_ plan: Plan, calendarName: String, now: Date = Date(), calendar: Calendar = HarnessCreateReminder.fixedCalendar()) -> String {
        let day = ReminderDue.day(plan.start, now: now, calendar: calendar, locale: .current)
        let when = plan.allDay ? "\(day) (all day)"
            : "\(day) from \(ReminderDue.clockTime(plan.start, calendar: calendar)) to \(ReminderDue.clockTime(plan.end, calendar: calendar))"
        return "\(plan.title), \(when), in your \(calendarName) calendar"
    }

    static var isAuthorized: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }

    /// The one line an event task's first turn carries while EventKit is granted; nil when the
    /// owner's words name no event, or a reminder (its own note speaks).
    static func note(heard: String, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String? {
        let tokens = RealtimeVoiceVerbs.foldedTokens(heard)
        func names(_ app: String) -> Bool {
            let stems = RealtimeHeardCheck.builtInTaskNouns[app] ?? []
            return tokens.contains { token in stems.contains { token.hasPrefix($0) } }
        }
        guard names("Calendar.app"), !names("Reminders.app") else { return nil }
        let due = ReminderDue.parse(heard, now: now, calendar: calendar)
        let quoted = due.phrase.map { "\"\(heard[$0])\"" } ?? ""
        let tool = "Create it with create_event (title: the event's name only, never the date words \(quoted); no invitees); "
            + "local code sets the time from the owner's words and reads it back."
        switch due.kind {
        case .timed(let date):
            return "Owner's start time, parsed from their words: \(ReminderDue.display(date, now: now, calendar: calendar, locale: locale)) "
                + "(an hour, unless they said an end). " + tool
        case .allDay(let date):
            return "Owner's day, parsed from their words: \(ReminderDue.day(date, now: now, calendar: calendar, locale: locale)) (all-day). " + tool
        case .ambiguous(let reason):
            return "The owner's time is unclear (\(reason), in \(quoted)). Before creating the event, ask the owner that one question with ask_owner; then "
                + tool.prefix(1).lowercased() + tool.dropFirst()
        case .none:
            return "The owner's words give no day or time for the event. Ask the owner when with ask_owner; then "
                + tool.prefix(1).lowercased() + tool.dropFirst()
        }
    }

    /// Writes the event, then re-reads it by identifier from a fresh store. The response's
    /// `verification` is that read-back; a mismatch still names what was made (it exists).
    static func create(_ plan: Plan, calendarName: String?) -> (report: [String: Any], failure: Failure?) {
        guard isAuthorized else {
            return ([:], Failure(code: "calendarNotAuthorized",
                                 message: "J.A.R.V.I.S. has no full access to Calendar (status \(EKEventStore.authorizationStatus(for: .event).rawValue)); "
                                    + "nothing was created. Use the Calendar app instead"))
        }
        let store = EKEventStore()
        let writable = store.calendars(for: .event).filter(\.allowsContentModifications)
        var report: [String: Any] = [:]
        let target: EKCalendar
        if let index = HarnessCreateReminder.exactList(named: calendarName, among: writable.map(\.title)) {
            target = writable[index]
        } else if let fallback = store.defaultCalendarForNewEvents {
            target = fallback
            if let calendarName, !calendarName.isEmpty { report["calendarNote"] = "no one writable calendar is named \"\(calendarName)\"; it went into the default calendar" }
        } else {
            return ([:], Failure(code: "eventNoCalendar", message: "Calendar has no default calendar for new events; nothing was created"))
        }
        let event = EKEvent(eventStore: store)
        event.title = plan.title
        event.calendar = target
        event.isAllDay = plan.allDay
        event.startDate = plan.start
        event.endDate = plan.end
        do {
            try store.save(event, span: .thisEvent, commit: true)
        } catch {
            return ([:], Failure(code: "eventSaveFailed", message: "Calendar refused the write (\((error as NSError).code)); nothing was created"))
        }
        guard let identifier = event.eventIdentifier else {
            return ([:], Failure(code: "notObserved", message: "the event was saved but has no identifier to read it back by"))
        }
        report["identifier"] = identifier
        report["calendar"] = target.title
        // Held while read, as createReminder's must be (a released store's item threw inside EventKit).
        let freshStore = EKEventStore()
        var read: EKEvent?
        for attempt in 0..<5 where read == nil {
            if attempt > 0 { Thread.sleep(forTimeInterval: 0.2) }
            read = freshStore.event(withIdentifier: identifier)
        }
        guard let read else {
            withExtendedLifetime(freshStore) {}
            return (report, Failure(code: "notObserved", message: "the event was saved but a fresh read could not find it"))
        }
        let calendar = HarnessCreateReminder.fixedCalendar()
        var checks = matches(plan, start: read.startDate, end: read.endDate, allDay: read.isAllDay, calendar: calendar)
        checks["title"] = read.title == plan.title
        checks["calendar"] = read.calendar?.calendarIdentifier == target.calendarIdentifier
        checks["noInvitees"] = read.attendees?.isEmpty ?? true
        report["readBack"] = checks
        report["readBackTimes"] = [ISO8601DateFormatter().string(from: read.startDate), ISO8601DateFormatter().string(from: read.endDate), read.isAllDay] as [Any]
        report["spoken"] = spokenReadBack(plan, calendarName: target.title)
        withExtendedLifetime(freshStore) {}
        let failed = checks.filter { !$0.value }.keys.sorted()
        return failed.isEmpty ? (report, nil)
            : (report, Failure(code: "notObserved", message: "the event was saved, but a fresh read differs in: \(failed.joined(separator: ", "))"))
    }
}
