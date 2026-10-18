//
//  LaunchSuiteSlice5Tests.swift
//  leanring-buddyTests
//
//  Slice 5's pure checkers on hand-built readings. Whether Notes' editor shows the new
//  note, or Reminders writes "Tomorrow" in a row, is the live run's question.
//

import Foundation
import Testing
@testable import Clicky

struct LaunchSuiteSlice5Tests {
    typealias Suite = GeneralitySuite

    @Test func aTemperatureIsANumberBeforeAUnit() {
        #expect(Suite.saysTemperature("JARVIS weather\nSydney: 22°C, partly cloudy"))
        #expect(Suite.saysTemperature("about 18 degrees"))
        #expect(Suite.saysTemperature("-3 °F"))
        #expect(Suite.saysTemperature("21.5 Celsius"))
        #expect(!Suite.saysTemperature("JARVIS weather"))
        #expect(!Suite.saysTemperature("Sydney, 2026"))
        #expect(!Suite.saysTemperature("a few degrees warmer"))
    }

    /// An earlier run's note skips M01/M03 before the agent acts (10-11-01Z: count 1 -> 1, a false fail),
    /// and an unreadable count skips too — never read as "none there".
    @Test func aLeftoverNoteOrAnUnreadableCountSkipsTheTask() {
        #expect(Suite.noteSkipReason(existing: 0, title: "JARVIS weather") == nil)
        #expect(Suite.noteSkipReason(existing: 1, title: "JARVIS weather")?.contains("JARVIS weather") == true)
        #expect(Suite.noteSkipReason(existing: 3, title: "JARVIS lighthouse") != nil)
        #expect(Suite.noteSkipReason(existing: nil, title: "JARVIS lighthouse") != nil)
    }

    /// A note passes only when its count grew AND a text titled with it holds the content.
    @Test func aNoteMustBeNewAndHoldTheContent() {
        let grew: [String: Any] = ["passed": true, "countBefore": 0, "countAfter": 1], same: [String: Any] = ["passed": false, "countBefore": 1, "countAfter": 1]
        let holds = Suite.noteVerdict(created: grew, title: "JARVIS weather", texts: ["JARVIS weather\n19°C in Sydney"], holds: Suite.saysTemperature)
        #expect(holds["passed"] as? Bool == true)
        #expect(holds["leftForOwner"] as? String != nil)
        // An older note already holding a temperature proves nothing without a new one.
        #expect(Suite.noteVerdict(created: same, title: "JARVIS weather", texts: ["JARVIS weather 19°C"], holds: Suite.saysTemperature)["passed"] as? Bool == false)
        // A new note with only its title, or an unreadable Notes.
        #expect(Suite.noteVerdict(created: grew, title: "JARVIS weather", texts: ["JARVIS weather"], holds: Suite.saysTemperature)["passed"] as? Bool == false)
        #expect(Suite.noteVerdict(created: grew, title: "JARVIS weather", texts: nil, holds: Suite.saysTemperature)["passed"] as? Bool == false)
    }

    @Test func aLighthouseNoteNeedsTwoOfThePagesFacts() {
        let grew: [String: Any] = ["passed": true, "countBefore": 0, "countAfter": 1]
        let facts = { (text: String) in Suite.factsVerdict(spoken: text, facts: Suite.lighthouseFacts)["passed"] as? Bool == true }
        #expect(Suite.noteVerdict(created: grew, title: "JARVIS lighthouse", texts: ["JARVIS lighthouse\nBuilt 1887; keeper Ada Whitlock."], holds: facts)["passed"] as? Bool == true)
        #expect(Suite.noteVerdict(created: grew, title: "JARVIS lighthouse", texts: ["JARVIS lighthouse\nA lighthouse built in 1887."], holds: facts)["passed"] as? Bool == false)
    }

    @Test func tomorrowIsReadInWordsOrAsTomorrowsDate() {
        let now = DateComponents(calendar: .current, year: 2026, month: 10, day: 17, hour: 12).date!
        let au = Locale(identifier: "en_AU")
        #expect(Suite.saysTomorrow(", Tomorrow", now: now, locale: au))
        #expect(Suite.saysTomorrow(", Tomorrow at 9:00\u{202F}am", now: now, locale: au))
        #expect(Suite.saysTomorrow(", 18 October 2026", now: now, locale: au))
        #expect(Suite.saysTomorrow(", 18/10/2026", now: now, locale: au))
        #expect(!Suite.saysTomorrow(", Today", now: now, locale: au))
        #expect(!Suite.saysTomorrow(", 19/10/2026", now: now, locale: au))
        #expect(!Suite.saysTomorrow("", now: now, locale: au))
    }

    /// The Today count must load to be a reading; the due date is the row's, never the typed title's.
    @Test func aReviewReminderIsANewBigVideoRowDueTomorrow() {
        let now = DateComponents(calendar: .current, year: 2026, month: 10, day: 17, hour: 12).date!
        #expect(Suite.bigVideoDue(buttons: ["All, 7 reminders"], rows: []) == nil)
        let buttons = ["Today, 0 reminders"]
        let before = Suite.bigVideoDue(buttons: buttons, rows: [(description: "Incomplete, milk", title: "milk"),
                                                                (description: "Completed, review big-video.mov", title: "review big-video.mov")])
        #expect(before == [])
        #expect(Suite.reviewSkipReason(before: before) == nil)
        #expect(Suite.reviewSkipReason(before: nil) != nil)
        #expect(Suite.reviewSkipReason(before: [", Tomorrow"]) != nil)
        let made = Suite.bigVideoDue(buttons: buttons, rows: [(description: "Incomplete, Review big-video.mov, Tomorrow", title: "Review big-video.mov")])
        #expect(Suite.reviewVerdict(before: before, after: made, now: now)["passed"] as? Bool == true)
        // "tomorrow" typed into the title, no due date set.
        let titled = Suite.bigVideoDue(buttons: buttons, rows: [(description: "Incomplete, Review big video tomorrow", title: "Review big video tomorrow")])
        #expect(titled?.count == 1)
        #expect(Suite.reviewVerdict(before: before, after: titled, now: now)["passed"] as? Bool == false)
        #expect(Suite.reviewVerdict(before: nil, after: made, now: now)["passed"] as? Bool == false)
    }
}
