//
//  HarnessAdjust.swift
//  leanring-buddy
//
//  `adjust`: step a control that publishes AXIncrement and AXDecrement (a slider,
//  a stepper, a picker wheel) to a whole number — or a picker GROUP of them, in
//  order, to "h:m:s". Measured 2026-10-14 on Clock (com.apple.clock, Catalyst),
//  Timers tab, launch suite E01 ("set a timer for 10 minutes"):
//    - The duration is an AXGroup described "Timer" (AXIdentifier TimePicker, value
//      "01:00:00", role description "Time Picker") over three AXSliders valued
//      "1 hour" / "0 minutes" / "0 seconds", each publishing AXPress, AXIncrement,
//      AXDecrement. (The coordinator's first read, 2026-10-13, saw the same identifier
//      as an AXTextField with no children: the Catalyst tree can arrive in that shape
//      first, so a target with nothing adjustable is re-read for up to 2 s.)
//    - Writing AXValue — on the group ("00:10:00") or a slider ("10 minutes", "10",
//      10): err 0 in 0 ms, nothing moved, 4 of 4. AXScrollUp/DownByPage on a slider
//      scrolls the whole PAGE, not the wheel. A posted line scroll-wheel event at a
//      slider's centre (hit-test: that slider): nothing moved after 1 s.
//    - AXIncrement with no segment selected: err 0, nothing moved (cold launch, 2 of 2).
//      AXPress on a slider SELECTS that segment (AXSelected 1, drawn highlighted);
//      then AXIncrement/AXDecrement on ANY slider moves the SELECTED segment by exactly
//      one, read back at once (1-23 ms a step; ten steps 82 ms).
//    - But AXSelected reads 1 at once while the app has not yet moved its selection: an
//      AXIncrement 0-25 ms after the press stepped the PREVIOUSLY selected wheel (8 of 8),
//      50-300 ms after it stepped the pressed one (8 of 8). So a press settles 150 ms,
//      and every step checks that no OTHER part moved.
//    - AXDecrement at 0 does nothing (no wrap), so a step that does not move is a stop.
//  So each control is pressed first, then stepped one at a time with its number read
//  back after every step. The pure half is unit-tested; the live half by running it.
//
//  A date-time picker is the other shape (Clock's add-alarm sheet, 2026-10-15): ONE
//  anonymous AXDateTimeArea whose AXValue is a settable CFDate (2000-01-01 at the shown
//  time) and whose AXIncrement steps the hour only. It is written, not stepped, from a
//  time of day ("6:45 AM"), and read back twice. Being anonymous, it stands in for an
//  unmatched name only when it is the window's one date-time picker.
//

import AppKit
import ApplicationServices
import Foundation

nonisolated enum HarnessAdjust {
    static let incrementAction = "AXIncrement"
    static let decrementAction = "AXDecrement"
    /// A 0-59 wheel needs at most 59; a 0-100 slider 100. Past this, something is wrong.
    static let maximumSteps = 120
    static let maximumValueLength = 16
    static let readTimeoutSeconds: Float = 0.5
    static let writeTimeoutSeconds: Float = 1.0
    /// How long one step may take to show in the read-back (Clock: at once).
    static let stepDeadlineSeconds = 0.3
    /// After pressing a part, before its first step (measured: 25 ms too soon, 50 ms enough).
    static let pressSettleSeconds = 0.15
    /// How long a target with nothing adjustable is re-read (a Catalyst tree still building).
    static let shapeDeadlineSeconds = 2.0
    static let pollIntervalSeconds = 0.05
    /// A date write is read back at once and again this much later.
    static let writeRecheckSeconds = 0.3
    static let walkNodeLimit = 3000
    static let walkDepthLimit = 40

    // MARK: Pure

    /// Why `text` may not be a value to adjust to, nil when it may: whole numbers,
    /// one per control, joined by ":" ("10", "0:10:00"), or a time of day ("6:45 AM").
    static func valueProblem(_ text: String) -> String? {
        if text.count > maximumValueLength { return "longer than \(maximumValueLength) characters" }
        if clockTime(text) != nil || level(text) != nil { return nil }
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.allSatisfy({ !$0.isEmpty && $0.count <= 4 && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }) else {
            return "not whole numbers joined by \":\""
        }
        return nil
    }

    /// The target number for each of `slots` controls, nil when the value does not
    /// name exactly one per control ("10:00" is not guessed into three wheels).
    static func targets(_ text: String, slots: Int) -> [Int]? {
        guard valueProblem(text) == nil else { return nil }
        let numbers = text.split(separator: ":").compactMap { Int($0) }
        return numbers.count == slots ? numbers : nil
    }

    /// The first whole number in a control's value: "10 minutes" -> 10, "-3" -> -3.
    static func number(in value: String?) -> Int? {
        guard let value else { return nil }
        let scalars = Array(value.unicodeScalars)
        guard let start = scalars.firstIndex(where: { CharacterSet.decimalDigits.contains($0) && $0.isASCII }) else { return nil }
        var end = start
        while end < scalars.count, scalars[end].isASCII, CharacterSet.decimalDigits.contains(scalars[end]) { end += 1 }
        guard let magnitude = Int(String(String.UnicodeScalarView(scalars[start..<end]))) else { return nil }
        return start > 0 && scalars[start - 1] == "-" ? -magnitude : magnitude
    }

    /// The action that moves `current` toward `target`, nil when it is there.
    static func step(from current: Int, to target: Int) -> String? {
        current < target ? incrementAction : current > target ? decrementAction : nil
    }

    static func isAdjustable(actions: [String]) -> Bool {
        actions.contains(incrementAction) && actions.contains(decrementAction)
    }

    // MARK: Pure — a time of day, for a date-time picker

    /// A time of day asked for. `second` nil when not given (written as 0, not checked).
    struct ClockTime: Equatable {
        let hour: Int
        let minute: Int
        let second: Int?
    }

    /// "6:45 AM", "6:45pm", "6:45 a.m.", "18:45", "06:45", "6:45:30" — nil for anything
    /// else ("0645", "13:00 PM", "6:5"). Without am/pm the hour is 24-hour.
    static func clockTime(_ text: String) -> ClockTime? {
        var body = text.lowercased().replacingOccurrences(of: ".", with: "").trimmingCharacters(in: .whitespaces)
        var meridiem: String?
        if let suffix = ["am", "pm"].first(where: body.hasSuffix) {
            meridiem = suffix
            body = String(body.dropLast(2)).trimmingCharacters(in: .whitespaces)
        }
        let parts = body.split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count),
              parts.allSatisfy({ (1...2).contains($0.count) && $0.allSatisfy { $0.isASCII && $0.isNumber } }),
              parts.dropFirst().allSatisfy({ $0.count == 2 }) else { return nil }
        let numbers = parts.compactMap { Int($0) }
        var hour = numbers[0]
        if let meridiem {
            guard (1...12).contains(hour) else { return nil }
            hour = hour % 12 + (meridiem == "pm" ? 12 : 0)
        }
        guard hour < 24, numbers[1] < 60, numbers.count < 3 || numbers[2] < 60 else { return nil }
        return ClockTime(hour: hour, minute: numbers[1], second: numbers.count == 3 ? numbers[2] : nil)
    }

    /// `old`'s day at `time` in `calendar` — the day is kept (Clock's alarm picker holds
    /// 2000-01-01), only the time of day is replaced; seconds 0 unless given.
    static func date(_ old: Date, at time: ClockTime, in calendar: Calendar) -> Date? {
        var parts = calendar.dateComponents([.era, .year, .month, .day], from: old)
        parts.hour = time.hour
        parts.minute = time.minute
        parts.second = time.second ?? 0
        return calendar.date(from: parts)
    }

    /// Whether `date` shows `time` in `calendar` (seconds only when they were asked for).
    static func shows(_ date: Date, _ time: ClockTime, in calendar: Calendar) -> Bool {
        let parts = calendar.dateComponents([.hour, .minute, .second], from: date)
        return parts.hour == time.hour && parts.minute == time.minute && (time.second == nil || parts.second == time.second)
    }

    static func timeText(_ date: Date, in calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.hour, .minute, .second], from: date)
        return String(format: "%02d:%02d:%02d", parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
    }

    /// When nothing carries the asked name, the window's ONE date-time picker stands in
    /// (Clock's alarm picker is anonymous) — never a pick among two.
    static func onlyOne<T>(_ candidates: [T]) -> T? {
        candidates.count == 1 ? candidates[0] : nil
    }

    static let dateTimeRoles: Set<String> = ["AXDateTimeArea", kAXDateFieldRole as String, kAXTimeFieldRole as String]

    // MARK: Pure — a level on a number-valued slider

    /// Roles whose AXValue may be a NUMBER on a range (Settings › Sound "Output volume":
    /// AXSlider, 0.392 on 0...1, 2026-10-15). A checkbox's 0/1 is a number too, so the role gates it.
    static let levelRoles: Set<String> = [kAXSliderRole as String, kAXIncrementorRole as String]

    /// "30", "30%", "30 percent", "30 per cent" — a whole number, and whether it was a percent.
    static func level(_ text: String) -> (amount: Double, percent: Bool)? {
        var body = text.lowercased().trimmingCharacters(in: .whitespaces)
        let suffix = ["%", "percent", "per cent"].first(where: body.hasSuffix)
        if let suffix { body = String(body.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces) }
        guard (1...4).contains(body.count), body.allSatisfy({ $0.isASCII && $0.isNumber }), let amount = Double(body) else { return nil }
        return (amount, suffix != nil)
    }

    /// The control's range: AXMinValue...AXMaxValue, or 0...1 when both are missing and the value
    /// lies in it; nil otherwise (no range is guessed for a value outside 0...1).
    static func range(min: Double?, max: Double?, current: Double) -> ClosedRange<Double>? {
        if let min, let max { return min < max ? min...max : nil }
        return min == nil && max == nil && (0...1).contains(current) ? 0...1 : nil
    }

    /// The number `text` asks for on `range`, nil when it lies outside. A percent is that share
    /// of the range; on 0...1 a bare number is a percent too ("set volume to 30" means 0.30, and
    /// on 0...100 the two readings agree); elsewhere a bare number is absolute and must lie inside.
    static func levelTarget(_ text: String, range: ClosedRange<Double>) -> Double? {
        guard let (amount, percent) = level(text) else { return nil }
        if percent || range == 0...1 {
            return (0...100).contains(amount) ? range.lowerBound + amount / 100 * (range.upperBound - range.lowerBound) : nil
        }
        return range.contains(amount) ? amount : nil
    }

    /// A written level counts as there within half a percent of its range.
    static func levelTolerance(_ range: ClosedRange<Double>) -> Double {
        (range.upperBound - range.lowerBound) * 0.005
    }

    /// The action that moves a level toward `target`, nil when it is there: within `tolerance`,
    /// or within half the step it last moved (the step cannot get closer).
    static func levelStep(from current: Double, to target: Double, tolerance: Double, lastStep: Double?) -> String? {
        let gap = abs(target - current)
        if gap <= tolerance || lastStep.map({ gap <= $0 / 2 + 1e-9 }) == true { return nil }
        return current < target ? incrementAction : decrementAction
    }

    // MARK: Live

    typealias Failure = HarnessRenameItem.Failure

    /// What an adjust acts on, read before anything is pressed.
    struct Plan {
        let name: String
        /// The named element itself, or its adjustable children in order.
        let controls: [AXUIElement]
        let targets: [Int]
        let before: [String?]
        /// The named element when it is a group over the controls, read again after.
        let group: AXUIElement?
        /// Set when the one control is a date-time picker: its date is WRITTEN, not stepped.
        var time: ClockTime? = nil
        /// Set when the one control is a number-valued slider: written or stepped to a level.
        var level: Level? = nil
        /// "name", "label" (the control the named text labels), or "onlyDateTimeControl" when nothing carried the name.
        var resolvedBy = "name"
    }

    struct Level {
        let target: Double
        let range: ClosedRange<Double>
        /// AXIsAttributeSettable said yes: written, else stepped (asked, never trusted — read back).
        let settable: Bool
    }

    /// Resolves `name` in the app's focused window to one adjustable control, or a
    /// group of them, and pairs each with its number from `value`. Reads only.
    /// `items` narrowed to the single one that `qualifies`, when several match and exactly one qualifies; else unchanged.
    static func preferringTheOne<T>(_ items: [T], qualifies: (T) -> Bool) -> [T] {
        guard items.count > 1 else { return items }
        let qualifying = items.filter(qualifies)
        return qualifying.count == 1 ? qualifying : items
    }

    static func plan(name: String, value: String, processIdentifier: pid_t) -> Result<Plan, Failure> {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), readTimeoutSeconds)
        let application = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(application, readTimeoutSeconds)
        let deadline = Date().addingTimeInterval(shapeDeadlineSeconds)
        var identifier: String?
        while true {
            guard let window = HarnessRenameItem.element(application, kAXFocusedWindowAttribute)
                    ?? HarnessRenameItem.element(application, kAXMainWindowAttribute) else {
                return .failure(Failure(code: "adjustNotFound", message: "the app in front has no window to read; nothing was changed"))
            }
            // A label and the slider it names share the name (Displays' Brightness, unseen H21 2026-10-25: ambiguous x5, then
            // clicks on the track moved it to 24%): the one adjustable control among them is meant.
            let matches = preferringTheOne(find(under: window) { element in
                displayName(element) == name || (identifier != nil && HarnessRenameItem.string(element, kAXIdentifierAttribute) == identifier)
            }) { element in
                levelRoles.contains(HarnessRenameItem.string(element, kAXRoleAttribute) ?? "") || isAdjustable(actions: actionNames(element))
                    || isDateTimeControl(element)
            }
            guard matches.count <= 1 else {
                return .failure(Failure(code: "ambiguous", message: "\(matches.count) elements are named \(UntrustedText(name).forDisplay); nothing was changed"))
            }
            let clock = clockTime(value)
            guard let named = matches.first else {
                // Clock's alarm picker (2026-10-15) has no title, description or help, so a
                // name the model chose ("time") matches nothing: a time stands in for the name
                // only when the window holds exactly one date-time picker.
                let pickers = clock == nil ? [] : find(under: window, where: isDateTimeControl)
                guard let clock, let picker = onlyOne(pickers) else {
                    return .failure(Failure(code: "adjustNotFound",
                                            message: "nothing in the window in front is named \(UntrustedText(name).forDisplay)"
                                                + (pickers.count > 1 ? " and it has \(pickers.count) time pickers, so none was guessed" : "")
                                                + "; nothing was changed"))
                }
                return .success(timePlan(name: name, control: picker, time: clock, resolvedBy: "onlyDateTimeControl"))
            }
            // A name on a label is the control that names itself by it (AXTitleUIElement): Settings ›
            // Sound's "Output volume" is an AXStaticText; the slider beside it is described "Output
            // volume, Output volume" (2026-10-15), so E11 matched the label and read notAdjustable. The
            // mute AXCheckBox names itself by the same label, so only an adjustable one counts.
            let labelled = HarnessRenameItem.string(named, kAXRoleAttribute) == kAXStaticTextRole as String
                ? onlyOne(find(under: window) { element in
                    (HarnessRenameItem.element(element, kAXTitleUIElementAttribute).map { CFEqual($0, named) } ?? false)
                        && (levelRoles.contains(HarnessRenameItem.string(element, kAXRoleAttribute) ?? "")
                            || isAdjustable(actions: actionNames(element)) || isDateTimeControl(element))
                })
                : nil
            let target = labelled ?? named
            let resolvedBy = labelled == nil ? "name" : "label"
            if let role = HarnessRenameItem.string(target, kAXRoleAttribute), levelRoles.contains(role),
               let current = numberAttribute(target, kAXValueAttribute) {
                return levelPlan(name: name, control: target, current: current, value: value, resolvedBy: resolvedBy)
            }
            if isDateTimeControl(target) {
                guard let clock else {
                    return .failure(Failure(code: "adjustValueMismatch", message: "\(UntrustedText(name).forDisplay) is a time picker; give a time "
                                            + "such as \"6:45 AM\" or \"18:45\"; nothing was changed"))
                }
                return .success(timePlan(name: name, control: target, time: clock, resolvedBy: resolvedBy))
            }
            let controls = isAdjustable(actions: actionNames(target)) ? [target]
                : HarnessRenameItem.elements(target, kAXChildrenAttribute).filter { isAdjustable(actions: actionNames($0)) }
            if controls.isEmpty {
                identifier = identifier ?? HarnessRenameItem.string(target, kAXIdentifierAttribute)
                guard Date() < deadline else {
                    return .failure(Failure(code: "notAdjustable", message: "\(UntrustedText(name).forDisplay) publishes no AXIncrement/AXDecrement, "
                                            + "nor do its children; nothing was changed"))
                }
                Thread.sleep(forTimeInterval: 0.25)
                continue
            }
            guard let numbers = targets(value, slots: controls.count) else {
                return .failure(Failure(code: "adjustValueMismatch",
                                        message: "\(UntrustedText(name).forDisplay) has \(controls.count) adjustable part\(controls.count == 1 ? "" : "s"); "
                                            + "give one whole number for each, joined by \":\" (for example \(controls.count == 3 ? "0:10:00" : "10")); nothing was changed"))
            }
            let before = controls.map { HarnessRenameItem.string($0, kAXValueAttribute) }
            if let unreadable = before.firstIndex(where: { number(in: $0) == nil }) {
                return .failure(Failure(code: "notAdjustable", message: "part \(unreadable + 1) of \(UntrustedText(name).forDisplay) shows no number to step; nothing was changed"))
            }
            return .success(Plan(name: name, controls: controls, targets: numbers, before: before, group: controls.count > 1 || !CFEqual(controls[0], target) ? target : nil,
                                 resolvedBy: resolvedBy))
        }
    }

    struct Run {
        var report: [String: Any] = [:]
        /// nil when every control reads its target number afterwards.
        var failure: Failure?
    }

    private static func timePlan(name: String, control: AXUIElement, time: ClockTime, resolvedBy: String) -> Plan {
        Plan(name: name, controls: [control], targets: [time.hour, time.minute] + (time.second.map { [$0] } ?? []),
             before: [dateValue(control).map { timeText($0, in: .current) }], group: nil, time: time, resolvedBy: resolvedBy)
    }

    private static func levelPlan(name: String, control: AXUIElement, current: Double, value: String, resolvedBy: String) -> Result<Plan, Failure> {
        let display = UntrustedText(name).forDisplay
        var settable: DarwinBoolean = false
        let writable = AXUIElementIsAttributeSettable(control, kAXValueAttribute as CFString, &settable) == .success && settable.boolValue
        guard writable || isAdjustable(actions: actionNames(control)) else {
            return .failure(Failure(code: "notAdjustable", message: "\(display) can neither be written nor stepped; nothing was changed"))
        }
        guard let range = range(min: numberAttribute(control, kAXMinValueAttribute), max: numberAttribute(control, kAXMaxValueAttribute), current: current) else {
            return .failure(Failure(code: "notAdjustable", message: "\(display) reads \(current) and publishes no range (AXMinValue/AXMaxValue), "
                                    + "so no level was guessed; nothing was changed"))
        }
        guard let target = levelTarget(value, range: range) else {
            return .failure(Failure(code: "adjustValueMismatch", message: "\(display) runs \(levelText(range.lowerBound))-\(levelText(range.upperBound)); "
                                    + "give a percent such as \"30%\"\(range == 0...1 ? "" : " or a number inside that range"); nothing was changed"))
        }
        return .success(Plan(name: name, controls: [control], targets: [], before: [levelText(current)], group: nil,
                             level: Level(target: target, range: range, settable: writable), resolvedBy: resolvedBy))
    }

    static func levelText(_ value: Double) -> String { String(format: "%.3f", value) }

    /// Writes a level when the app says AXValue is settable, else steps it with AXIncrement /
    /// AXDecrement — Settings › Sound "Output volume", 2026-10-15: settable false, a write
    /// answered -25200 and moved nothing; each step moved exactly 0.100, read back at once
    /// (66 ms, 15 ms). A step can only land on current ± k·step, so it stops at the nearest and
    /// says so. Either way the level is read again `writeRecheckSeconds` later.
    static func setLevel(_ control: AXUIElement, _ level: Level) -> Run {
        var run = Run()
        let started = Date()
        let tolerance = levelTolerance(level.range)
        AXUIElementSetMessagingTimeout(control, writeTimeoutSeconds)
        func read() -> Double? { numberAttribute(control, kAXValueAttribute) }
        func finish(mode: String, settled: Double?, extra: [String: Any]) -> Run {
            Thread.sleep(forTimeInterval: writeRecheckSeconds)
            let later = read()
            run.report = extra.merging(["mode": mode, "target": levelText(level.target),
                                        "after": [settled, later].map { $0.map(levelText) ?? "unread" },
                                        "milliseconds": Int(Date().timeIntervalSince(started) * 1000)]) { _, new in new }
            return run
        }
        if level.settable {
            let error = AXUIElementSetAttributeValue(control, kAXValueAttribute as CFString, NSNumber(value: level.target))
            let first = read()
            run = finish(mode: "write", settled: first, extra: ["write": Int(error.rawValue)])
            let reads = [first, read()]
            if !reads.allSatisfy({ $0.map { abs($0 - level.target) <= tolerance } ?? false }) {
                run.failure = Failure(code: "adjustNotObserved", message: "the control does not read \(levelText(level.target)) after the write "
                                      + "(the write answered \(error.rawValue)); it reads \(reads.last.flatMap { $0.map(levelText) } ?? "nothing")")
            }
            return run
        }
        guard var current = read() else {
            run.failure = Failure(code: "notAdjustable", message: "the control stopped showing a number; it was left where it is")
            return run
        }
        var steps = 0
        var lastStep: Double?
        func stepped(_ action: String, from: Double) -> Double? {
            _ = AXUIElementPerformAction(control, action as CFString)
            steps += 1
            let deadline = Date().addingTimeInterval(stepDeadlineSeconds)
            repeat {
                if let now = read(), now != from { return now }
                Thread.sleep(forTimeInterval: pollIntervalSeconds)
            } while Date() < deadline
            return nil
        }
        while let action = levelStep(from: current, to: level.target, tolerance: tolerance, lastStep: lastStep) {
            guard steps < maximumSteps, let now = stepped(action, from: current) else {
                run = finish(mode: "steps", settled: current, extra: ["steps": steps])
                run.failure = Failure(code: steps < maximumSteps ? "adjustStuck" : "adjustTooFar",
                                      message: "the control did not move from \(levelText(current)) toward \(levelText(level.target)) "
                                          + "(\(action)); it is at its limit, or the app ignores the step")
                return run
            }
            lastStep = abs(now - current)
            // A step that lands farther away than where it started went past: one step back, and stop
            // (live: 0.330 toward 0.300 read 0.230, stepped back to 0.330).
            if abs(level.target - now) > abs(level.target - current) {
                current = stepped(action == incrementAction ? decrementAction : incrementAction, from: now) ?? now
                break
            }
            current = now
        }
        run = finish(mode: "steps", settled: current, extra: ["steps": steps, "step": lastStep.map(levelText) ?? NSNull()])
        let later = read()
        if later.map({ abs($0 - current) > tolerance }) ?? true {
            run.failure = Failure(code: "adjustNotObserved", message: "the control read \(levelText(current)) after stepping and "
                                  + "\(later.map(levelText) ?? "nothing") \(Int(writeRecheckSeconds * 1000)) ms later")
        } else if abs(current - level.target) > tolerance {
            run.report["note"] = "the control moves in steps of \(lastStep.map(levelText) ?? "an unknown size"); "
                + "\(levelText(current)) is the nearest it reaches to \(levelText(level.target))"
        }
        return run
    }

    /// Writes a date-time picker's date with the asked time of day, then reads it back at
    /// once and again `writeRecheckSeconds` later — an AX write can answer success and be
    /// ignored (CLAUDE.md, three tiers of evidence). Clock's alarm picker, 2026-10-15: a
    /// write of 06:45 read back 06:45, and an AXIncrement after it read 07:45.
    static func writeTime(_ control: AXUIElement, _ time: ClockTime) -> Run {
        var run = Run()
        let started = Date()
        let calendar = Calendar.current
        AXUIElementSetMessagingTimeout(control, writeTimeoutSeconds)
        guard let old = dateValue(control), let new = date(old, at: time, in: calendar) else {
            run.failure = Failure(code: "notAdjustable", message: "the time picker stopped showing a date; it was left where it is")
            return run
        }
        let error = AXUIElementSetAttributeValue(control, kAXValueAttribute as CFString, new as NSDate)
        let first = dateValue(control)
        Thread.sleep(forTimeInterval: writeRecheckSeconds)
        let second = dateValue(control)
        run.report = ["write": Int(error.rawValue), "after": [first, second].map { $0.map { timeText($0, in: calendar) } ?? "unread" },
                      "milliseconds": Int(Date().timeIntervalSince(started) * 1000)]
        let held = [first, second].allSatisfy { $0.map { shows($0, time, in: calendar) } ?? false }
        if !held {
            run.failure = Failure(code: "adjustNotObserved", message: "the time picker does not read \(timeText(new, in: calendar)) after the write "
                                  + "(the write answered \(error.rawValue)); it reads \(second.map { timeText($0, in: calendar) } ?? "nothing")")
        }
        return run
    }

    /// Presses each control (Clock steps the SELECTED wheel), then steps it one at a
    /// time, reading its number back after every step — or writes a time picker's date.
    static func adjust(_ plan: Plan) -> Run {
        if let time = plan.time, let control = plan.controls.first { return writeTime(control, time) }
        if let level = plan.level, let control = plan.controls.first { return setLevel(control, level) }
        var run = Run()
        let started = Date()
        var steps: [Int] = []
        func stop(_ code: String, _ message: String) -> Run {
            run.report["after"] = plan.controls.map { HarnessRenameItem.string($0, kAXValueAttribute).map { UntrustedText($0).forDisplay } ?? "unread" }
            run.report["steps"] = steps
            run.report["milliseconds"] = Int(Date().timeIntervalSince(started) * 1000)
            run.failure = Failure(code: code, message: message)
            return run
        }
        for (index, control) in plan.controls.enumerated() {
            let target = plan.targets[index]
            AXUIElementSetMessagingTimeout(control, writeTimeoutSeconds)
            guard var current = number(in: HarnessRenameItem.string(control, kAXValueAttribute)) else {
                return stop("notAdjustable", "part \(index + 1) stopped showing a number; it was left where it is")
            }
            steps.append(0)
            guard let firstAction = step(from: current, to: target) else { continue }
            if actionNames(control).contains(kAXPressAction as String), bool(control, kAXSelectedAttribute) != true {
                _ = AXUIElementPerformAction(control, kAXPressAction as CFString)
                Thread.sleep(forTimeInterval: pressSettleSeconds)
            }
            let others = plan.controls.indices.filter { $0 != index }
            let othersBefore = others.map { number(in: HarnessRenameItem.string(plan.controls[$0], kAXValueAttribute)) }
            while let action = step(from: current, to: target) {
                guard action == firstAction else {
                    return stop("adjustOvershot", "part \(index + 1) jumped past \(target) (it moves by more than one); it reads \(current)")
                }
                guard steps[index] < maximumSteps else {
                    return stop("adjustTooFar", "part \(index + 1) was still \(current) after \(maximumSteps) steps toward \(target); it was left there")
                }
                let error = AXUIElementPerformAction(control, action as CFString)
                steps[index] += 1
                let stepDeadline = Date().addingTimeInterval(stepDeadlineSeconds)
                var moved: Int?
                repeat {
                    if let now = number(in: HarnessRenameItem.string(control, kAXValueAttribute)), now != current { moved = now; break }
                    Thread.sleep(forTimeInterval: pollIntervalSeconds)
                } while Date() < stepDeadline
                let othersNow = others.map { number(in: HarnessRenameItem.string(plan.controls[$0], kAXValueAttribute)) }
                guard othersNow == othersBefore else {
                    return stop("adjustWrongPart", "a step for part \(index + 1) moved another part (the app had not moved its selection); "
                                + "the control was left where it is")
                }
                guard let now = moved else {
                    return stop("adjustStuck", "part \(index + 1) did not move from \(current) toward \(target) (\(action) answered \(error.rawValue)); "
                                + "it is at its limit, or the app ignores the step")
                }
                current = now
            }
        }
        let after = plan.controls.map { HarnessRenameItem.string($0, kAXValueAttribute) }
        run.report["after"] = after.map { $0.map { UntrustedText($0).forDisplay } ?? "unread" }
        run.report["steps"] = steps
        run.report["milliseconds"] = Int(Date().timeIntervalSince(started) * 1000)
        if let group = plan.group { run.report["groupAfter"] = HarnessRenameItem.string(group, kAXValueAttribute).map { UntrustedText($0).forDisplay } ?? "unread" }
        if after.map(number(in:)) != plan.targets.map(Optional.some) {
            run.failure = Failure(code: "notObserved", message: "the control does not read \(plan.targets.map(String.init).joined(separator: ":")) afterwards")
        }
        return run
    }

    // MARK: Reads

    /// `AccessibilityElementNode.displayName`'s order: title, description, value —
    /// never the value of what is or may be a password box.
    static func displayName(_ element: AXUIElement) -> String? {
        let secure = ActionSafetyKernel.secureFieldSubrole
        let mayHoldSecret = HarnessRenameItem.string(element, kAXRoleAttribute) == secure
            || HarnessRenameItem.string(element, kAXSubroleAttribute) == secure
        for attribute in [kAXTitleAttribute, kAXDescriptionAttribute] + (mayHoldSecret ? [] : [kAXValueAttribute]) {
            if let text = HarnessRenameItem.string(element, attribute), !text.isEmpty { return text }
        }
        return nil
    }

    static func actionNames(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        return AXUIElementCopyActionNames(element, &names) == .success ? (names as? [String]) ?? [] : []
    }

    /// The element's AXValue when it is a date (CFDate), nil otherwise.
    static func dateValue(_ element: AXUIElement) -> Date? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == CFDateGetTypeID() else { return nil }
        return value as? Date
    }

    /// The attribute when it is a number (CFNumber), nil otherwise.
    static func numberAttribute(_ element: AXUIElement, _ attribute: String) -> Double? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == CFNumberGetTypeID() else { return nil }
        return (value as? NSNumber)?.doubleValue
    }

    /// A date-time role whose AXValue is a date the app says is settable.
    static func isDateTimeControl(_ element: AXUIElement) -> Bool {
        guard let role = HarnessRenameItem.string(element, kAXRoleAttribute), dateTimeRoles.contains(role), dateValue(element) != nil else { return false }
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success && settable.boolValue
    }

    private static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return (value as? NSNumber)?.boolValue
    }

    /// Breadth-first under `root`, bounded by node count and depth.
    private static func find(under root: AXUIElement, where matches: (AXUIElement) -> Bool) -> [AXUIElement] {
        var queue: [(AXUIElement, Int)] = [(root, 0)], found: [AXUIElement] = [], visited = 0
        while !queue.isEmpty, visited < walkNodeLimit {
            let (element, depth) = queue.removeFirst()
            visited += 1
            if matches(element) { found.append(element) }
            if depth < walkDepthLimit { queue += HarnessRenameItem.elements(element, kAXChildrenAttribute).map { ($0, depth + 1) } }
        }
        return found
    }
}
