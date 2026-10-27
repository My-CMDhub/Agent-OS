//
//  CalendarReader.swift
//  leanring-buddy
//
//  `read_calendar`: what is on the owner's calendar for a day or a range, read through EventKit.
//  Never-taught request 2026-10-25 "what's on my calendar tomorrow?" (a Sunday): the agent drove
//  Calendar's UI to Monday, then decided "tomorrow" was Tuesday, pressed "next day" (verified
//  notObserved although the day changed) and answered "clear tomorrow, Tuesday 27 October". Two
//  causes: the model doing date arithmetic, and navigation the verifier cannot see. So the range is
//  resolved by CODE from the owner's own words (the model's `when` only when theirs name no day),
//  and the events come from the app's data API, a rung above the tree. Reads only, in-process like
//  `find_file`; no harness verb, and never prompts for access from inside a task.
//

import EventKit
import Foundation

nonisolated enum CalendarRange {
    static let maximumDays = 31

    private static let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
    private static let weekdays = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
    private static let month = #"(?:jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|june?|july?|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)"#
    private static let pattern = try! NSRegularExpression(pattern: #"\b(?:"#
        + #"(?<after>(?:the\s+)?day\s+after\s+tomorrow)|(?<today>today|tonight)|(?<tomorrow>tomorrow)|(?<yesterday>yesterday)"#
        + #"|(?<which>this|next)\s+(?<span>weekend|week|month)|(?<weekend>(?:the\s+)?weekend)"#
        + #"|(?:(?<wdq>this|next|on)\s+)?(?<wd>sunday|monday|tuesday|wednesday|thursday|friday|saturday)"#
        + #"|(?<d1>\d{1,2})(?:st|nd|rd|th)?(?:\s+of)?\s+(?<m1>"# + month + #")(?:\s+(?<y1>\d{4}))?"#
        + #"|(?<m2>"# + month + #")\s+(?<d2>\d{1,2})(?:st|nd|rd|th)?(?:,?\s+(?<y2>\d{4}))?"#
        + #")\b"#, options: [.caseInsensitive])

    /// Every day phrase in `words`, spanned from the first day to the last ("today and tomorrow",
    /// "Monday to Wednesday"); nil when none is read. Whole days in `calendar`'s zone. Weekdays
    /// follow NSDataDetector (probed 2026-10-25 on a Sunday, the same parser `create_event` reads
    /// the owner's words with): "Monday" is the next one after today, "next Monday" the one in
    /// next week (weeks start on `calendar.firstWeekday`), so a read agrees with what was made.
    static func parse(_ words: String, now: Date, calendar: Calendar) -> DateInterval? {
        let text = words as NSString
        let today = calendar.startOfDay(for: now)
        func day(_ offset: Int, from base: Date = today) -> Date { calendar.date(byAdding: .day, value: offset, to: base)! }
        func group(_ match: NSTextCheckingResult, _ name: String) -> String? {
            let range = match.range(withName: name)
            return range.location == NSNotFound ? nil : text.substring(with: range).lowercased()
        }
        var found: [DateInterval] = []
        for match in pattern.matches(in: words, range: NSRange(location: 0, length: text.length)) {
            func days(_ start: Date, _ count: Int) { found.append(DateInterval(start: start, end: day(count, from: start))) }
            if group(match, "after") != nil { days(day(2), 1) }
            else if group(match, "today") != nil { days(today, 1) }
            else if group(match, "tomorrow") != nil { days(day(1), 1) }
            else if group(match, "yesterday") != nil { days(day(-1), 1) }
            else if let span = group(match, "span") ?? group(match, "weekend").map({ _ in "weekend" }) {
                let next = group(match, "which") == "next"
                switch span {
                case "weekend":
                    // The Saturday of this weekend (yesterday on a Sunday); "this weekend" on a Sunday is what is left: today.
                    let weekday = calendar.component(.weekday, from: today)
                    let saturday = day(weekday == 1 ? -1 : (7 - weekday + 7) % 7)
                    if next { days(day(7, from: saturday), 2) } else { found.append(DateInterval(start: max(saturday, today), end: day(2, from: saturday))) }
                default:
                    let unit: Calendar.Component = span == "week" ? .weekOfYear : .month
                    let base = next ? calendar.date(byAdding: unit, value: 1, to: today)! : today
                    if let interval = calendar.dateInterval(of: unit, for: base) { found.append(interval) }
                }
            } else if let name = group(match, "wd"), let target = weekdays.firstIndex(of: name) {
                let weekday = calendar.component(.weekday, from: today) - 1
                // "this Monday" said on a Monday is today (review 2026-10-27); a bare or "on" weekday follows NSDataDetector.
                let ahead = (target - weekday + 7) % 7
                var date = day(ahead == 0 && group(match, "wdq") != "this" ? 7 : ahead)
                if group(match, "wdq") == "next", calendar.isDate(date, equalTo: today, toGranularity: .weekOfYear) { date = day(7, from: date) }
                days(date, 1)
            } else if let dayText = group(match, "d1") ?? group(match, "d2"), let monthText = group(match, "m1") ?? group(match, "m2"),
                      let monthIndex = months.firstIndex(of: String(monthText.prefix(3))), let dayNumber = Int(dayText) {
                let year = (group(match, "y1") ?? group(match, "y2")).flatMap { Int($0) }
                var parts = DateComponents(year: year ?? calendar.component(.year, from: today), month: monthIndex + 1, day: dayNumber)
                guard var date = calendar.date(from: parts), calendar.component(.day, from: date) == dayNumber else { continue }
                // ponytail: no year said and over half a year gone means next year's ("5 January" in October); a fixed window, not intent.
                if year == nil, date < day(-183) {
                    parts.year! += 1
                    date = calendar.date(from: parts) ?? date
                }
                days(date, 1)
            }
        }
        guard let start = found.map(\.start).min(), let end = found.map(\.end).max() else { return nil }
        return DateInterval(start: start, end: end)
    }

    /// The owner's words first (the authority, as `ReminderDue` reads a due from them), the model's `when` only
    /// when theirs name no day.
    static func resolve(when: String?, heard: String?, now: Date, calendar: Calendar) -> DateInterval? {
        heard.flatMap { parse($0, now: now, calendar: calendar) } ?? when.flatMap { parse($0, now: now, calendar: calendar) }
    }

    static func dayCount(_ interval: DateInterval, calendar: Calendar) -> Int {
        calendar.dateComponents([.day], from: interval.start, to: interval.end).day ?? 0
    }

    /// "Monday 26 October 2026 (tomorrow)", or "Sunday 25 October 2026 to Saturday 31 October 2026".
    static func label(_ interval: DateInterval, now: Date, calendar: Calendar, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        formatter.dateStyle = .full
        let first = formatter.string(from: interval.start)
        guard dayCount(interval, calendar: calendar) <= 1 else { return first + " to " + formatter.string(from: interval.end.addingTimeInterval(-1)) }
        let offset = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: interval.start).day
        return first + ([0: " (today)", 1: " (tomorrow)", -1: " (yesterday)"][offset ?? 99] ?? "")
    }
}

nonisolated enum CalendarReader {
    static let maximumEvents = 30

    struct Event: Equatable {
        let title: String?
        let start: Date
        let end: Date
        let allDay: Bool
        let calendar: String?
        let location: String?
    }

    // MARK: Pure

    /// Owner's own text, still app-written: redacted, and withheld when it is no plausible label.
    private static func shown(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        return UntrustedText(raw).isPlausibleControlLabel ? SecretScanner.redact(raw) : nil
    }

    /// All-day first, then by start. A day is named on each event when the range spans days or the event began before it.
    static func toolResult(events: [Event], range: DateInterval, now: Date, calendar: Calendar, locale: Locale = .current) -> [String: Any] {
        let sorted = events.sorted { ($0.allDay ? 0 : 1, $0.start) < ($1.allDay ? 0 : 1, $1.start) }
        let manyDays = CalendarRange.dayCount(range, calendar: calendar) > 1
        let listed = sorted.prefix(maximumEvents).map { event -> [String: Any] in
            let title = event.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            var row: [String: Any] = ["title": title.isEmpty ? "(no title)" : shown(title) ?? "(title withheld)", "allDay": event.allDay]
            if !event.allDay {
                row["start"] = ReminderDue.clockTime(event.start, calendar: calendar)
                row["end"] = ReminderDue.clockTime(event.end, calendar: calendar)
            }
            if manyDays || event.start < range.start { row["day"] = ReminderDue.day(event.start, now: now, calendar: calendar, locale: locale) }
            if let name = shown(event.calendar) { row["calendar"] = name }
            if let place = shown(event.location) { row["location"] = place }
            return row
        }
        var result: [String: Any] = ["ok": true, "range": CalendarRange.label(range, now: now, calendar: calendar, locale: locale),
                                     "events": listed, "count": events.count, "timeZone": calendar.timeZone.identifier]
        if events.count > maximumEvents { result["more"] = events.count - maximumEvents }
        if events.isEmpty { result["message"] = "nothing is on the calendar in this range" }
        return result
    }

    static func refusal(_ error: String, _ message: String) -> [String: Any] {
        RealtimeOpenAppTool.toolResult(for: RealtimeToolRefusal(error: error, message: message))
    }

    /// The range from the words, or the refusal that says what to pass instead.
    static func resolvedRange(when: String?, heard: String?, now: Date, calendar: Calendar) -> Result<DateInterval, RealtimeToolRefusal> {
        guard let range = CalendarRange.resolve(when: when, heard: heard, now: now, calendar: calendar) else {
            return .failure(RealtimeToolRefusal(error: "calendarRangeUnclear",
                message: "no day was read from the words; call read_calendar again with when set to the owner's own day words "
                    + "(\"today\", \"tomorrow\", \"this week\", \"next Monday\", \"26 October\"), never a date you worked out"))
        }
        guard CalendarRange.dayCount(range, calendar: calendar) <= CalendarRange.maximumDays else {
            return .failure(RealtimeToolRefusal(error: "calendarRangeTooLong",
                message: "read_calendar reads at most \(CalendarRange.maximumDays) days at a time; ask for a shorter range"))
        }
        return .success(range)
    }

    // MARK: Live (EventKit: call off the main thread)

    static func toolResult(when: String?, heard: String?, now: Date = Date()) -> [String: Any] {
        let calendar = HarnessCreateReminder.fixedCalendar()
        let range: DateInterval
        switch resolvedRange(when: when, heard: heard, now: now, calendar: calendar) {
        case .failure(let refusal): return RealtimeOpenAppTool.toolResult(for: refusal)
        case .success(let found): range = found
        }
        guard HarnessCreateEvent.isAuthorized else {
            return refusal("calendarNotAuthorized", "J.A.R.V.I.S. has no full access to Calendar (status "
                + "\(EKEventStore.authorizationStatus(for: .event).rawValue)); nothing was read. Tell the owner, who can grant it in "
                + "System Settings > Privacy & Security > Calendars")
        }
        let store = EKEventStore()
        let found = store.events(matching: store.predicateForEvents(withStart: range.start, end: range.end, calendars: nil)).map {
            Event(title: $0.title, start: $0.startDate, end: $0.endDate, allDay: $0.isAllDay, calendar: $0.calendar?.title, location: $0.location)
        }
        withExtendedLifetime(store) {}
        return toolResult(events: found, range: range, now: now, calendar: calendar)
    }
}
