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
        if clockTime(text) != nil { return nil }
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
        /// "name", or "onlyDateTimeControl" when nothing carried the name.
        var resolvedBy = "name"
    }

    /// Resolves `name` in the app's focused window to one adjustable control, or a
    /// group of them, and pairs each with its number from `value`. Reads only.
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
            let matches = find(under: window) { element in
                displayName(element) == name || (identifier != nil && HarnessRenameItem.string(element, kAXIdentifierAttribute) == identifier)
            }
            guard matches.count <= 1 else {
                return .failure(Failure(code: "ambiguous", message: "\(matches.count) elements are named \(UntrustedText(name).forDisplay); nothing was changed"))
            }
            let clock = clockTime(value)
            guard let target = matches.first else {
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
            if isDateTimeControl(target) {
                guard let clock else {
                    return .failure(Failure(code: "adjustValueMismatch", message: "\(UntrustedText(name).forDisplay) is a time picker; give a time "
                                            + "such as \"6:45 AM\" or \"18:45\"; nothing was changed"))
                }
                return .success(timePlan(name: name, control: target, time: clock, resolvedBy: "name"))
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
            return .success(Plan(name: name, controls: controls, targets: numbers, before: before, group: controls.count > 1 || !CFEqual(controls[0], target) ? target : nil))
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
