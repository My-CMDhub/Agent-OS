//
//  HarnessAdjustTests.swift
//  leanring-buddyTests
//
//  `adjust` / `set_value`: step a picker, slider or stepper to whole numbers
//  (measured 2026-10-14 on Clock's timer). Pure parts only — the value's numbers,
//  a control's number, the step direction, the kernel's words and the wire.
//  Whether Clock moves its selected wheel on AXIncrement is a live fact.
//

import Foundation
import Testing
@testable import Clicky

private func line(_ object: [String: Any]) -> String {
    String(decoding: (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data(), as: UTF8.self)
}

struct HarnessAdjustTests {

    // MARK: The value

    @Test func aValueIsOneWholeNumberPerPart() {
        #expect(HarnessAdjust.targets("0:10:00", slots: 3) == [0, 10, 0])
        #expect(HarnessAdjust.targets("75", slots: 1) == [75])
        #expect(HarnessAdjust.targets("10:00", slots: 3) == nil, "two numbers for three wheels is not guessed")
        #expect(HarnessAdjust.targets("10", slots: 3) == nil)
        for bad in ["", "10 minutes", "-1", "1.5", "1e3", "0::10", ":10", "\u{0663}", "12345", String(repeating: "1:", count: 9) + "1"] {
            #expect(HarnessAdjust.valueProblem(bad) != nil, "\(bad) must be refused")
        }
        #expect(HarnessAdjust.valueProblem("00:10:00") == nil)
    }

    // MARK: A time of day (Clock's alarm picker, 2026-10-15)

    @Test func aTimeOfDayIsTwelveOrTwentyFourHour() {
        typealias T = HarnessAdjust.ClockTime
        #expect(HarnessAdjust.clockTime("6:45 AM") == T(hour: 6, minute: 45, second: nil))
        #expect(HarnessAdjust.clockTime("6:45pm") == T(hour: 18, minute: 45, second: nil))
        #expect(HarnessAdjust.clockTime("6:45 p.m.") == T(hour: 18, minute: 45, second: nil))
        #expect(HarnessAdjust.clockTime("18:45") == T(hour: 18, minute: 45, second: nil))
        #expect(HarnessAdjust.clockTime("6:45") == T(hour: 6, minute: 45, second: nil), "no am/pm is 24-hour")
        #expect(HarnessAdjust.clockTime("06:45:30") == T(hour: 6, minute: 45, second: 30))
        #expect(HarnessAdjust.clockTime("12:00 AM") == T(hour: 0, minute: 0, second: nil), "midnight")
        #expect(HarnessAdjust.clockTime("12:30 PM") == T(hour: 12, minute: 30, second: nil), "noon")
        for bad in ["0645", "13:00 PM", "0:30 am", "24:00", "6:60", "6:5", "6:45 xm", "6 AM", "", "6::45", "\u{0666}:45"] {
            #expect(HarnessAdjust.clockTime(bad) == nil, "\(bad) is not a time")
        }
        #expect(HarnessAdjust.valueProblem("6:45 AM") == nil, "the wire takes a time")
        #expect(HarnessAdjust.valueProblem("6:45 tomorrow") != nil)
    }

    @Test func theNewDateKeepsThePickersDayAndReplacesTheTimeOfDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Australia/Sydney"))
        // As read 2026-10-15 05:46 AEDT: the alarm picker holds 2000-01-01 18:41:42 UTC = 05:41:42 local.
        let old = Date(timeIntervalSinceReferenceDate: 18 * 3600 + 41 * 60 + 42)
        #expect(HarnessAdjust.timeText(old, in: calendar) == "05:41:42")
        let time = try #require(HarnessAdjust.clockTime("6:45 AM"))
        let new = try #require(HarnessAdjust.date(old, at: time, in: calendar))
        #expect(HarnessAdjust.timeText(new, in: calendar) == "06:45:00", "seconds 0 when not given")
        #expect(calendar.isDate(new, inSameDayAs: old), "the day is kept")
        #expect(HarnessAdjust.shows(new, time, in: calendar))
        #expect(!HarnessAdjust.shows(old, time, in: calendar))
        // An AXIncrement after the write read 07:45 (the hour only): not 6:45.
        #expect(!HarnessAdjust.shows(new.addingTimeInterval(3600), time, in: calendar))
        // Seconds count only when asked for.
        #expect(HarnessAdjust.shows(new.addingTimeInterval(5), time, in: calendar))
        #expect(!HarnessAdjust.shows(new.addingTimeInterval(5), try #require(HarnessAdjust.clockTime("6:45:00")), in: calendar))
    }

    @Test func anUnnamedTimePickerStandsInOnlyWhenItIsTheOnlyOne() {
        #expect(HarnessAdjust.onlyOne(["picker"]) == "picker")
        #expect(HarnessAdjust.onlyOne(["start", "end"]) == nil, "never a guess among two")
        #expect(HarnessAdjust.onlyOne([String]()) == nil)
        #expect(HarnessAdjust.dateTimeRoles.contains("AXDateTimeArea"))
    }

    // MARK: A level on a number-valued slider (Settings › Sound "Output volume", 2026-10-15)

    @Test func aLevelIsAPercentOfTheRangeOrANumberInsideIt() throws {
        #expect(HarnessAdjust.level("30%")! == (30, true))
        #expect(HarnessAdjust.level("30 percent")! == (30, true))
        #expect(HarnessAdjust.level("30 Per Cent")! == (30, true))
        #expect(HarnessAdjust.level("30")! == (30, false))
        for bad in ["", "%", "30.5%", "-30%", "thirty", "12345%", "\u{0663}0%"] { #expect(HarnessAdjust.level(bad) == nil, "\(bad) is not a level") }
        #expect(HarnessAdjust.valueProblem("30%") == nil && HarnessAdjust.valueProblem("30 percent") == nil, "the wire takes a percent")
        // The volume slider: 0...1, so "30" and "30%" both mean 0.30.
        let unit = 0.0...1.0
        #expect(try #require(HarnessAdjust.levelTarget("30%", range: unit)) == 0.3)
        #expect(try #require(HarnessAdjust.levelTarget("30", range: unit)) == 0.3)
        #expect(HarnessAdjust.levelTarget("130%", range: unit) == nil)
        // 0...100: the two readings agree. Elsewhere a bare number is absolute and must lie inside.
        #expect(HarnessAdjust.levelTarget("30", range: 0...100) == 30 && HarnessAdjust.levelTarget("30%", range: 0...100) == 30)
        #expect(HarnessAdjust.levelTarget("25%", range: 10...50) == 20)
        #expect(HarnessAdjust.levelTarget("30", range: 10...50) == 30)
        #expect(HarnessAdjust.levelTarget("60", range: 10...50) == nil)
        // No range is guessed for a value outside 0...1.
        #expect(HarnessAdjust.range(min: 0, max: 1, current: 0.392) == 0...1)
        #expect(HarnessAdjust.range(min: nil, max: nil, current: 0.392) == 0...1)
        #expect(HarnessAdjust.range(min: nil, max: nil, current: 7) == nil)
        #expect(HarnessAdjust.range(min: 0, max: nil, current: 0.5) == nil)
        #expect(HarnessAdjust.range(min: 1, max: 1, current: 1) == nil)
        #expect(HarnessAdjust.levelRoles.contains("AXSlider") && !HarnessAdjust.levelRoles.contains("AXCheckBox"), "a checkbox's 0/1 is not a level")
    }

    @Test func steppingALevelStopsAtTheNearestItCanReach() {
        let tolerance = HarnessAdjust.levelTolerance(0...1)
        #expect(abs(tolerance - 0.005) < 1e-12)
        // Measured: 0.392 (osascript 39), each step 0.100. One step down reads 0.292, within half a step of 0.30: stop.
        #expect(HarnessAdjust.levelStep(from: 0.392, to: 0.3, tolerance: tolerance, lastStep: nil) == "AXDecrement")
        #expect(HarnessAdjust.levelStep(from: 0.292, to: 0.3, tolerance: tolerance, lastStep: 0.1) == nil)
        #expect(HarnessAdjust.levelStep(from: 0.9, to: 0.3, tolerance: tolerance, lastStep: 0.1) == "AXDecrement")
        #expect(HarnessAdjust.levelStep(from: 0.1, to: 0.3, tolerance: tolerance, lastStep: 0.1) == "AXIncrement")
        #expect(HarnessAdjust.levelStep(from: 0.302, to: 0.3, tolerance: tolerance, lastStep: nil) == nil, "within half a percent is there")
    }

    // MARK: A control's number

    @Test func aControlsNumberIsTheFirstWholeNumberInItsValue() {
        // Clock's three timer sliders, as read 2026-10-14.
        #expect(HarnessAdjust.number(in: "1 hour") == 1)
        #expect(HarnessAdjust.number(in: "10 minutes") == 10)
        #expect(HarnessAdjust.number(in: "0 seconds") == 0)
        #expect(HarnessAdjust.number(in: "Volume 75%") == 75)
        #expect(HarnessAdjust.number(in: "-3") == -3)
        #expect(HarnessAdjust.number(in: "none") == nil)
        #expect(HarnessAdjust.number(in: nil) == nil)
    }

    @Test func eachStepMovesTowardTheTargetAndStopsThere() {
        #expect(HarnessAdjust.step(from: 0, to: 10) == "AXIncrement")
        #expect(HarnessAdjust.step(from: 1, to: 0) == "AXDecrement")
        #expect(HarnessAdjust.step(from: 5, to: 5) == nil)
        // A 10-minute timer from Clock's 1:00:00 default: 1 step down, 10 up, none.
        let from = ["1 hour", "0 minutes", "0 seconds"].compactMap(HarnessAdjust.number(in:))
        let to = HarnessAdjust.targets("0:10:00", slots: 3) ?? []
        #expect(zip(from, to).map { abs($0 - $1) } == [1, 10, 0])
        #expect(zip(from, to).map { HarnessAdjust.step(from: $0, to: $1) } == ["AXDecrement", "AXIncrement", nil])
    }

    @Test func onlyAControlPublishingBothStepsIsAdjustable() {
        // Clock's slider, as published (the custom-action strings included).
        #expect(HarnessAdjust.isAdjustable(actions: ["AXPress", "AXScrollToVisible", "AXIncrement", "AXDecrement", "AXCancel",
                                                     "AXScrollDownByPage", "AXScrollUpByPage", "AXShowMenu"]))
        #expect(!HarnessAdjust.isAdjustable(actions: ["AXPress", "AXIncrement"]))
        #expect(!HarnessAdjust.isAdjustable(actions: ["AXScrollToVisible", "AXCancel", "AXShowMenu"]), "the Timer group itself")
    }

    // MARK: The kernel

    @Test func adjustingIsNavigationAfterTheNamesWords() {
        #expect(ActionSafetyKernel.evaluateAdjust(name: "Timer") == .allow)
        #expect(ActionSafetyKernel.evaluateAdjust(name: "0 minutes") == .allow)
        guard case .requireConfirmation(_, true) = ActionSafetyKernel.evaluateAdjust(name: "Delete after (days)") else {
            Issue.record("a destructive word asks"); return
        }
        guard case .refuse = ActionSafetyKernel.evaluateAdjust(name: "Pay amount") else { Issue.record("an irreversible word refuses"); return }
    }

    // MARK: The wire

    @Test func theVerbNeedsTheControlItsNumbersAndTheApp() throws {
        let ok = try HarnessPolicy.decode(line: line(["verb": "adjust", "title": "Timer", "text": "0:10:00", "expectApp": "com.apple.clock"])).get()
        #expect(ok.verb == .adjust)
        #expect(ok.title == "Timer")
        #expect(ok.text == "0:10:00")
        for (raw, field) in [(["verb": "adjust", "text": "10", "expectApp": "Clock"] as [String: Any], "title"),
                             (["verb": "adjust", "title": "Timer", "expectApp": "Clock"], "text"),
                             (["verb": "adjust", "title": "Timer", "text": "10"], "expectApp")] {
            guard case .failure(.missingField(field)) = HarnessPolicy.decode(line: line(raw)) else { Issue.record("no \(field) must refuse"); continue }
        }
        guard case .failure(.invalidField(field: "text", _)) = HarnessPolicy.decode(
            line: line(["verb": "adjust", "title": "Timer", "text": "10 minutes", "expectApp": "Clock"])) else {
            Issue.record("words are not a value"); return
        }
        #expect(HarnessVerb.adjust.isMutating)
        #expect(HarnessVerb.adjust.elementAction == nil)
        #expect(HarnessPolicy.killSwitchRefusal(verb: .adjust, killSwitchPresent: true) != nil)
        #expect(AgentLoop.readOnlyRefusal(["verb": "adjust", "title": "Timer", "text": "0:10:00"], focusedField: { nil }) != nil)
        #expect(HarnessServer.confirmationShape(for: ok, bundleIdentifier: "com.apple.clock").text == "0:10:00", "a ticket binds the value")
    }

    @Test func theToolCarriesTheControlAndValueToTheHarness() throws {
        let call = RealtimeToolCall.parsed(callID: "c", name: "set_value", arguments: ["app": "Clock", "name": "Timer", "value": "0:10:00"])
        #expect(call.appName == "Clock")
        #expect(call.elementName == "Timer")
        #expect(call.text == "0:10:00")
        let request = try RealtimeOpenAppTool.harnessRequestLine(for: call, expectApp: "com.apple.clock").get()
        let decoded = try HarnessPolicy.decode(line: request).get()
        #expect(decoded.verb == .adjust && decoded.title == "Timer" && decoded.text == "0:10:00" && decoded.expectApp == "com.apple.clock")
        #expect(RealtimeVoiceVerbs.takesFrontmostApp("set_value"), "the app in front when none is named")
        #expect(RealtimeHeardCheck.refusesWithoutTranscript(toolName: "set_value", namedAppIsRunning: true))
        let declaration = try #require(RealtimeVoiceVerbs.openAIDeclarations.first { $0["name"] as? String == "set_value" })
        #expect((declaration["description"] as? String)?.contains("press_element \"Start\"") == true)
        #expect((declaration["description"] as? String)?.contains("\"6:45 AM\"") == true, "an alarm's time goes in value")
        #expect((declaration["description"] as? String)?.contains("\"Output volume\" value \"30%\"") == true, "a level goes in as a percent")
        #expect(AgentPlan.requiredArguments["set_value"] == [["name", "value"]])
    }

    /// Unseen H21 2026-10-25: Displays' "Brightness" label and slider share the name; the slider is meant.
    @Test func theOneAdjustableAmongSameNamedMatchesIsMeant() {
        #expect(HarnessAdjust.preferringTheOne(["label", "slider"]) { $0 == "slider" } == ["slider"])
        #expect(HarnessAdjust.preferringTheOne(["slider", "slider"]) { $0 == "slider" } == ["slider", "slider"], "two sliders stay ambiguous")
        #expect(HarnessAdjust.preferringTheOne(["label", "text"]) { $0 == "slider" } == ["label", "text"])
        #expect(HarnessAdjust.preferringTheOne(["label"]) { $0 == "slider" } == ["label"])
    }
}
