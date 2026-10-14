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
    static let walkNodeLimit = 3000
    static let walkDepthLimit = 40

    // MARK: Pure

    /// Why `text` may not be a value to adjust to, nil when it may: whole numbers,
    /// one per control, joined by ":" ("10", "0:10:00").
    static func valueProblem(_ text: String) -> String? {
        if text.count > maximumValueLength { return "longer than \(maximumValueLength) characters" }
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
            guard let target = matches.first else {
                return .failure(Failure(code: "adjustNotFound",
                                        message: "nothing in the window in front is named \(UntrustedText(name).forDisplay); nothing was changed"))
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

    /// Presses each control (Clock steps the SELECTED wheel), then steps it one at a
    /// time, reading its number back after every step.
    static func adjust(_ plan: Plan) -> Run {
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
