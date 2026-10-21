//
//  ReminderDue.swift
//  leanring-buddy
//
//  A reminder's due date or time, read by local code from the OWNER's words — never guessed by the
//  model, never typed where an app's own parser gets a second guess (research 2026-10-21, how Siri
//  makes reminders: a typed slot, and one short question when it is unclear). NSDataDetector does the
//  reading; the traps it was measured falling into are ruled here: a date-only phrase comes back at an
//  invented 12:00 (all-day here), a past time is not rolled forward (asked), and a bare hour is
//  silently made pm (asked).
//

import Foundation

nonisolated struct ReminderDue: Equatable {
    enum Kind: Equatable {
        /// Nothing the detector reads ("in an hour", "next week", "half past five" all miss): no due understood.
        case none
        case allDay(Date)
        case timed(Date)
        /// Ask the owner, never pick: the reason is the question's subject.
        case ambiguous(String)
    }

    let kind: Kind
    /// The owner's words the date came from ("at 5 pm today"), so the title can be kept clean of them.
    let phrase: Range<String.Index>?

    /// `now` rebases the day the detector chose against the real clock (it takes no reference date):
    /// the same instant in production, a fixed one in tests.
    ///
    /// After an ask_owner, `heard` is `joined(task, answer:)`: the due is read from the ANSWER, on the
    /// task's named day when the answer names none ("at 5 today" + "5 pm" -> today 5 pm; joined with a
    /// space it read as two times and asked again, 2026-10-21). An answer with no date or time at all
    /// answered something else, so the task's own words stand.
    static func parse(_ heard: String, now: Date = Date(), calendar: Calendar = .current) -> ReminderDue {
        guard let cut = heard.range(of: answerSeparator, options: .backwards) else {
            return parseOne(heard, dayOf: nil, now: now, calendar: calendar)
        }
        let task = String(heard[..<cut.lowerBound]), answer = String(heard[cut.upperBound...])
        let answered = parseOne(answer, dayOf: namedDay(in: task, now: now, calendar: calendar), now: now, calendar: calendar)
        guard answered.kind != .none else { return parse(task, now: now, calendar: calendar) }
        // The phrase indexes `heard`, so the title is still cleaned of the answer's words.
        let phrase = answered.phrase.map { range in
            heard.index(cut.upperBound, offsetBy: answer.distance(from: answer.startIndex, to: range.lowerBound))
                ..< heard.index(cut.upperBound, offsetBy: answer.distance(from: answer.startIndex, to: range.upperBound))
        }
        return ReminderDue(kind: answered.kind, phrase: phrase)
    }

    /// Between a task's words and the owner's answer to its ask_owner (`joined`). Every other reader
    /// of the owner's words splits on whitespace, so it reads them as before.
    static let answerSeparator = "\n"
    static func joined(_ task: String, answer: String) -> String { task + answerSeparator + answer }

    static func matches(in text: String) -> [NSTextCheckingResult] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else { return [] }
        return detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).filter { $0.date != nil }
    }

    /// The detector's date moved onto the real clock's day count (it takes no reference date).
    private static func rebased(_ found: Date, now: Date, calendar: Calendar) -> Date {
        let start = calendar.startOfDay(for: now)
        let offset = calendar.dateComponents([.day], from: calendar.startOfDay(for: Date()), to: calendar.startOfDay(for: found)).day ?? 0
        return calendar.date(byAdding: .day, value: offset, to: start) ?? start
    }

    private static func namesDay(_ words: String) -> Bool {
        words.lowercased().range(of: #"\b(today|tonight|tomorrow|mon|tue|wed|thu|fri|sat|sun|jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\b|\d(st|nd|rd|th)\b|\d/\d"#,
                                 options: .regularExpression) != nil
    }

    /// The day the task's one date phrase names in words ("today", "Friday"), even when its hour was unclear.
    private static func namedDay(in text: String, now: Date, calendar: Calendar) -> Date? {
        let found = matches(in: text)
        guard found.count == 1, let date = found[0].date, let range = Range(found[0].range, in: text), namesDay(String(text[range])) else { return nil }
        return rebased(date, now: now, calendar: calendar)
    }

    /// `dayOf`: the day to use when these words name no day of their own.
    private static func parseOne(_ heard: String, dayOf: Date?, now: Date, calendar: Calendar) -> ReminderDue {
        let matches = matches(in: heard)
        guard let match = matches.first, let found = match.date, let range = Range(match.range, in: heard) else {
            return ReminderDue(kind: .none, phrase: nil)
        }
        if matches.count > 1 { return ReminderDue(kind: .ambiguous("more than one date or time was heard"), phrase: range) }

        let words = heard[range].lowercased()
        func has(_ pattern: String) -> Bool { words.range(of: pattern, options: .regularExpression) != nil }
        let start = calendar.startOfDay(for: now)
        let day = dayOf.flatMap { namesDay(words) ? nil : $0 } ?? rebased(found, now: now, calendar: calendar)
        let clock = calendar.dateComponents([.hour, .minute], from: found)
        let when = calendar.date(bySettingHour: clock.hour ?? 12, minute: clock.minute ?? 0, second: 0, of: day) ?? day

        let stated = has(#"\d\s*[ap]\.?\s?m\b"#) || has(#"\d:\d\d"#)
            || has(#"\b(one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve)\s+[ap]\.?\s?m\b"#)
            // The detector's own defaults (09:00, 15:00, 19:00): stated, and said back in the note.
            || has(#"\b(noon|midday|midnight|morning|afternoon|evening|tonight)\b"#)
        if stated {
            return ReminderDue(kind: when < now ? .ambiguous("\(display(when, now: now, calendar: calendar)) has already passed") : .timed(when),
                               phrase: range)
        }
        // "at 5 today", "5 o'clock": the detector made it pm; a guess still.
        if has(#"\bat\s+\d{1,2}\b"#) || has(#"o.?\s?clock"#) || clock.hour != 12 || clock.minute != 0 {
            return ReminderDue(kind: .ambiguous("the hour was heard without am or pm"), phrase: range)
        }
        return ReminderDue(kind: day < start ? .ambiguous("that date has already passed") : .allDay(day), phrase: range)
    }

    /// The one line a reminder task's first turn carries; nil when the owner's words name no reminder or give no due.
    /// Reminders is named by the same fixed stem the voice uses to pick the app (`builtInTaskNouns`).
    /// `structured`: EventKit is granted, so the line points at create_reminder; else the measured UI path.
    static func note(heard: String, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current,
                     structured: Bool = false) -> String? {
        let stems = RealtimeHeardCheck.builtInTaskNouns["Reminders.app"] ?? []
        guard RealtimeVoiceVerbs.foldedTokens(heard).contains(where: { token in stems.contains { token.hasPrefix($0) } }) else { return nil }
        let due = parse(heard, now: now, calendar: calendar)
        let quoted = due.phrase.map { "\"\(heard[$0])\"" } ?? ""
        let title = "Put only the task in the reminder's title, never the date words \(quoted)"
        if structured {
            let tool = "Create it with create_reminder (title: the task only, never the date words \(quoted)); "
                + "local code sets the due from the owner's words and reads it back."
            switch due.kind {
            case .none: return nil
            case .timed(let date):
                return "Owner's due time, parsed from their words: \(display(date, now: now, calendar: calendar, locale: locale)) (timed). " + tool
            case .allDay(let date):
                return "Owner's due date, parsed from their words: \(day(date, now: now, calendar: calendar, locale: locale)) (all-day, no time). " + tool
            case .ambiguous(let reason):
                return "The owner's due time is unclear (\(reason), in \(quoted)). Before creating the reminder, ask the owner that one question "
                    + "with ask_owner; then " + tool.prefix(1).lowercased() + tool.dropFirst()
            }
        }
        switch due.kind {
        case .none:
            return nil
        case .timed(let date):
            return "Owner's due time, parsed from their words: \(display(date, now: now, calendar: calendar, locale: locale)) (timed). "
                + title + "; set the date with Edit > Mark Due Date As (Today/Tomorrow) or the Add Date field, then type the time "
                // E12 2026-10-21: set_value on "Add Time" came back adjustNotFound — it is a text field; type + submit
                // is the measured path (47304cf).
                + "\"\(clockTime(date, calendar: calendar))\" into the reminder's Add Time field with type_text and submit true "
                + "(set_value does not apply to it)."
        case .allDay(let date):
            return "Owner's due date, parsed from their words: \(day(date, now: now, calendar: calendar, locale: locale)) (all-day, no time). "
                + title + "; set only the date in the reminder's own Add Date field (Edit > Mark Due Date As for Today/Tomorrow), and no time."
        case .ambiguous(let reason):
            return "The owner's due time is unclear (\(reason), in \(quoted)). Before creating the reminder, ask the owner that one question "
                + "with ask_owner; then " + title.prefix(1).lowercased() + title.dropFirst()
                + ", and set what they answer in the reminder's own date and time fields."
        }
    }

    static func display(_ date: Date, now: Date, calendar: Calendar, locale: Locale = .current) -> String {
        day(date, now: now, calendar: calendar, locale: locale) + " " + clockTime(date, calendar: calendar)
    }

    /// "5:00 pm" — the form Reminders' Add Time field takes.
    static func clockTime(_ date: Date, calendar: Calendar) -> String {
        let clock = calendar.dateComponents([.hour, .minute], from: date)
        let hour = clock.hour ?? 0
        return String(format: "%d:%02d %@", (hour + 11) % 12 + 1, clock.minute ?? 0, hour < 12 ? "am" : "pm")
    }

    static func day(_ date: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) { return "Tomorrow" }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        formatter.dateFormat = "EEEE d MMMM"
        return formatter.string(from: date)
    }
}
