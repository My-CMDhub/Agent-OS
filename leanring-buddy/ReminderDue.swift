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
    static func parse(_ heard: String, now: Date = Date(), calendar: Calendar = .current) -> ReminderDue {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else {
            return ReminderDue(kind: .none, phrase: nil)
        }
        let matches = detector.matches(in: heard, range: NSRange(heard.startIndex..., in: heard)).filter { $0.date != nil }
        guard let match = matches.first, let found = match.date, let range = Range(match.range, in: heard) else {
            return ReminderDue(kind: .none, phrase: nil)
        }
        if matches.count > 1 { return ReminderDue(kind: .ambiguous("more than one date or time was heard"), phrase: range) }

        let words = heard[range].lowercased()
        func has(_ pattern: String) -> Bool { words.range(of: pattern, options: .regularExpression) != nil }
        let start = calendar.startOfDay(for: now)
        let offset = calendar.dateComponents([.day], from: calendar.startOfDay(for: Date()), to: calendar.startOfDay(for: found)).day ?? 0
        let day = calendar.date(byAdding: .day, value: offset, to: start) ?? start
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
    static func note(heard: String, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String? {
        let stems = RealtimeHeardCheck.builtInTaskNouns["Reminders.app"] ?? []
        guard RealtimeVoiceVerbs.foldedTokens(heard).contains(where: { token in stems.contains { token.hasPrefix($0) } }) else { return nil }
        let due = parse(heard, now: now, calendar: calendar)
        let quoted = due.phrase.map { "\"\(heard[$0])\"" } ?? ""
        let title = "Put only the task in the reminder's title, never the date words \(quoted)"
        switch due.kind {
        case .none:
            return nil
        case .timed(let date):
            return "Owner's due time, parsed from their words: \(display(date, now: now, calendar: calendar, locale: locale)) (timed). "
                + title + "; set the date and time in the reminder's own Add Date / Add Time fields (Edit > Mark Due Date As for Today/Tomorrow)."
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
        let clock = calendar.dateComponents([.hour, .minute], from: date)
        let hour = clock.hour ?? 0
        return day(date, now: now, calendar: calendar, locale: locale)
            + String(format: " %d:%02d %@", (hour + 11) % 12 + 1, clock.minute ?? 0, hour < 12 ? "am" : "pm")
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
