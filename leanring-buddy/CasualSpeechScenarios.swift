//
//  CasualSpeechScenarios.swift
//  leanring-buddy
//
//  Section K: the suite's other fixtures are clean sentences, and the owner says the real thing "feels like an
//  interview: I have to speak crisply, loudly, and perfectly". These are spoken the way a person talks to a colleague
//  (fillers, restarts, indirect asks, pronouns across turns) and then made worse (quiet, fast, room noise, a mumbled
//  tail): scripts/scenarios/make-fixtures.sh. `say` is a floor, never the owner's voice.
//
//  Every verdict is the outcome read independently, plus what the voice claimed beside it: `questions`,
//  `clarifyingQuestions`, `claim` and `disagreement` go in the report. Only windows and apps the scenario made are
//  touched; an app already running is the owner's, and the scenario skips. Asked for by id only.
//

import AppKit
import ApplicationServices
import Foundation

/// What the voice said, judged apart from what happened.
nonisolated enum CasualSpeechClaim {
    enum Claim: String { case success, failure, none }

    private static let failureWords = ["can't", "cannot", "can not", "couldn't", "could not", "unable", "not able", "failed", "didn't", "did not",
                                       "wasn't able", "afraid", "won't", "beyond my", "still open", "still there", "no such", "not found", "hasn't", "not been"]
    private static let successWords = ["done", "minimi", "hidden", "tucked", "put away", "closed", "gone", "opened", "is open", "are open", "open now",
                                       "in front", "is up", "is ready", "full screen", "fullscreen", "there you go", "has been", "away now"]
    /// An intent, not a result: "Opening Safari now", "I'll close it".
    private static let promiseStarts = ["i'll", "i will", "i'm", "i am going", "on it", "let me", "certainly", "of course", "right away", "looking", "one moment"]

    static func sentences(_ transcript: String) -> [String] {
        var sentences: [String] = []
        var current = ""
        for character in transcript {
            current.append(character)
            if ".!?".contains(character) {
                sentences.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                current = ""
            }
        }
        let rest = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !rest.isEmpty { sentences.append(rest) }
        return sentences
    }

    static func questions(_ transcript: String) -> [String] { sentences(transcript).filter { $0.hasSuffix("?") } }

    /// A question left when nothing happened is a clarification, whatever its words; after a done task only one that
    /// asks which ("What will you be needing?" is manners, not a clarification).
    static func clarifying(_ transcript: String, done: Bool) -> Int {
        questions(transcript).filter { question in
            let lower = question.lowercased()
            return !done || ["which", "do you mean", "did you mean", " or "].contains { lower.contains($0) }
        }.count
    }

    /// The last sentence that claims anything wins: a task's report comes after its promise.
    /// ponytail: a word list, so a flag is for a person to read, not a verdict. The verdict is the outcome read.
    static func claim(_ transcript: String) -> Claim {
        for sentence in sentences(transcript).reversed() where !sentence.hasSuffix("?") {
            let lower = sentence.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
            if failureWords.contains(where: lower.contains) { return .failure }
            let firstWord = lower.split(separator: " ").first.map(String.init) ?? ""
            if firstWord.hasSuffix("ing") || promiseStarts.contains(where: lower.hasPrefix) { continue }
            if successWords.contains(where: lower.contains) { return .success }
        }
        return .none
    }

    /// Said done and it is not, or said it failed and it is done. A read's answer has no claim of doing.
    static func disagrees(_ claim: Claim, done: Bool) -> Bool {
        (claim == .success && !done) || (claim == .failure && done)
    }

    /// Out of the way, by any route a person would accept: minimised, hidden, closed, or the app quit.
    /// `windowOpen` is the scenario's own window by identity; nil is a failed read, never "closed".
    static func outOfTheWay(windowOpen: Bool?, minimised: Bool, hidden: Bool, running: Bool) -> Bool {
        !running || hidden || minimised || windowOpen == false
    }
}

@MainActor
extension ScenarioCatalog {
    static let calculatorApp = "com.apple.calculator"
    static let calendar = "com.apple.iCal"
    static let notes = "com.apple.Notes"
    static let xcode = "com.apple.dt.Xcode"

    struct WindowState {
        let running: Bool
        let hidden: Bool
        /// nil: the read failed, which is never "no windows".
        let windows: Int?
        /// Of the window `target` names, by identity. A force-quit TextEdit relaunches with its earlier windows, minimised ones
        /// included: a count called K04 done 80 ms after the release, before anything was asked of the machine.
        let targetOpen: Bool?
        let targetMinimised: Bool
        let targetFullScreen: Bool
    }

    nonisolated static func windowState(_ bundleIdentifier: String, target: AXUIElement?) -> WindowState {
        guard let application = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first else {
            return WindowState(running: false, hidden: false, windows: 0, targetOpen: false, targetMinimised: false, targetFullScreen: false)
        }
        let element = AXUIElementCreateApplication(application.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.5)
        func flag(_ of: AXUIElement, _ attribute: String) -> Bool {
            var value: AnyObject?
            return AXUIElementCopyAttributeValue(of, attribute as CFString, &value) == .success && value as? Bool == true
        }
        let hidden = flag(element, kAXHiddenAttribute)
        var value: AnyObject?
        let read = AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value)
        guard read == .success || read == .noValue else {
            return WindowState(running: true, hidden: hidden, windows: nil, targetOpen: nil, targetMinimised: false, targetFullScreen: false)
        }
        let windows = value as? [AXUIElement] ?? []
        let open = target.map { target in windows.contains { CFEqual($0, target) } }
        return WindowState(running: true, hidden: hidden, windows: windows.count, targetOpen: open,
                           targetMinimised: target.map { flag($0, kAXMinimizedAttribute) } ?? false,
                           targetFullScreen: target.map { flag($0, "AXFullScreen") } ?? false)
    }

    static func state(_ bundleIdentifier: String, _ context: ScenarioContext? = nil) async -> WindowState {
        let target = context?.notes["target"].map { $0 as! AXUIElement }
        return await Task.detached { [target] in windowState(bundleIdentifier, target: target) }.value
    }

    static func isFront(_ bundleIdentifier: String) -> Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleIdentifier
    }

    /// The app's focused window: what "this" and "it" mean, and all the checkers look at.
    static func noteTarget(_ bundleIdentifier: String, _ context: ScenarioContext) async {
        let found = await Task.detached { () -> AXUIElement? in
            guard let application = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first else { return nil }
            var window: AnyObject?
            guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(application.processIdentifier), kAXFocusedWindowAttribute as CFString, &window) == .success,
                  let window, CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
            return (window as! AXUIElement)
        }.value
        if let found { context.notes["target"] = found }
        context.baseline["targetWindowFound"] = found != nil
    }

    /// TextEdit launched by the run, with `documents` new empty documents, the last in front.
    static func textEditOpen(documents: Int = 1) -> @MainActor (ScenarioContext) async -> Void {
        { context in
            _ = await VoiceToolProbe.ask(["verb": "launch", "app": textEdit], context.harnessAnswer)
            for _ in 0..<documents { _ = await VoiceToolProbe.ask(["verb": "menu", "path": ["File", "New"], "expectApp": textEdit], context.harnessAnswer) }
            try? await Task.sleep(for: .milliseconds(600))
            await noteTarget(textEdit, context)
            context.baseline["textEditWindows"] = await state(textEdit).windows ?? NSNull()
            parkPointer(on: textEdit, context)
        }
    }

    /// "this" may be what the owner's pointer rests on, and in a run that is wherever they left it: K06 2026-11-03, "make this take up the
    /// whole screen" with the pointer over the owner's own Xcode put Xcode in full screen. So the pointer waits on the test's window, and
    /// goes back at the check. Moved without an event, so it counts as no owner input.
    static func parkPointer(on bundleIdentifier: String, _ context: ScenarioContext) {
        guard let application = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first else { return }
        var window: AnyObject?, position: AnyObject?, size: AnyObject?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(application.processIdentifier), kAXFocusedWindowAttribute as CFString, &window) == .success,
              let window, CFGetTypeID(window) == AXUIElementGetTypeID(),
              AXUIElementCopyAttributeValue(window as! AXUIElement, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(window as! AXUIElement, kAXSizeAttribute as CFString, &size) == .success else { return }
        var origin = CGPoint.zero, extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin), AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return }
        context.notes["pointerBefore"] = CGEvent(source: nil)?.location
        CGWarpMouseCursorPosition(CGPoint(x: origin.x + extent.width / 2, y: origin.y + extent.height / 2))
    }

    static func calculatorOpen() -> @MainActor (ScenarioContext) async -> Void {
        { context in
            _ = await VoiceToolProbe.ask(["verb": "launch", "app": calculatorApp], context.harnessAnswer)
            try? await Task.sleep(for: .milliseconds(400))
            await noteTarget(calculatorApp, context)
            parkPointer(on: calculatorApp, context)
        }
    }

    static func gone(_ context: ScenarioContext, _ bundleIdentifier: String) async -> Bool {
        let now = await state(bundleIdentifier, context)
        return CasualSpeechClaim.outOfTheWay(windowOpen: now.targetOpen, minimised: now.targetMinimised, hidden: now.hidden, running: now.running)
    }

    /// A force-quit TextEdit relaunches with every window it had, and K's windows reached 20 (K16 then judged a machine nobody has). Pressing their
    /// close buttons alone did not stop it: "closed 13, left 0", then the next launch read 14, because the runner's force-quit came before TextEdit wrote
    /// its state. So: its empty Untitled windows close, a window holding text is left alone, and only an app with no windows left quits normally here.
    /// The run's own document from a fixture (B4's list, B13's order number): nothing else's text is ever emptied, and an emptied Untitled closes as an empty one does.
    nonisolated static func heldOnlyRunText(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return lowered.count < 200 && ((lowered.contains("milk") && lowered.contains("eggs")) || lowered.contains("a7-48213"))
    }

    static func closeEmptyTextEditWindows(_: ScenarioContext) async -> [String: Any] {
        await closeRunTextEditWindows()
    }

    static func closeRunTextEditWindows() async -> [String: Any] {
        await Task.detached { () -> [String: Any] in
            guard let application = NSRunningApplication.runningApplications(withBundleIdentifier: textEdit).first else { return [:] }
            application.unhide()
            Thread.sleep(forTimeInterval: 0.3)
            let element = AXUIElementCreateApplication(application.processIdentifier)
            var value: AnyObject?
            guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value) == .success else { return ["closed": 0, "note": "windows unread"] }
            var closed = 0, left = 0
            for window in value as? [AXUIElement] ?? [] {
                let area = ScenarioRunnerAX.nodes(window, processIdentifier: application.processIdentifier).first { $0.role == "AXTextArea" }
                var text = area?.value?.raw
                let untitled = ScenarioRunnerAX.windowTitle(window)?.hasPrefix("Untitled") == true
                if untitled, let held = text, heldOnlyRunText(held), let element = area?.accessibilityElement,
                   AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, "" as CFString) == .success {
                    Thread.sleep(forTimeInterval: 0.2)
                    text = ""
                }
                guard untitled, text?.isEmpty != false else { left += 1; continue }
                AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                var button: AnyObject?
                guard AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute as CFString, &button) == .success, let button,
                      CFGetTypeID(button) == AXUIElementGetTypeID() else { left += 1; continue }
                let press = AccessibilityActionPerformer.perform(kAXPressAction, on: button as! AXUIElement)
                HarnessServer.auditDirectClose(tool: "CasualSpeech.closeEmptyTextEditWindows", processIdentifier: application.processIdentifier, windowNumber: nil,
                                               why: "run cleanup: an empty Untitled window, before the quit", closed: press.error == .success)
                closed += 1
            }
            let empty = HarnessHands.waitUntil(seconds: 5) { windowState(textEdit, target: nil).windows == 0 }
            guard left == 0, empty else { return ["closed": closed, "left": left, "windowsNow": windowState(textEdit, target: nil).windows ?? -1] }
            application.terminate()
            return ["closed": closed, "left": 0, "windowsNow": 0, "quitNormally": HarnessHands.waitUntil(seconds: 3) { application.isTerminated }]
        }.value
    }

    /// One scenario: `done` reads the machine, polled like a person glancing back; `answer` judges a read's words.
    static func casual(_ id: String, start: RunnerScenario.Start, earlier: [String] = [], quit: [String] = [], prepare: (@MainActor (ScenarioContext) async -> Void)? = nil,
                       done: (@MainActor (ScenarioContext) async -> Bool)? = nil, answer: (@MainActor (ScenarioContext, ScenarioOutcome) async -> Bool)? = nil,
                       never: [ScenarioNever] = [], undo: (@MainActor (ScenarioContext) async -> [String: Any])? = nil) -> RunnerScenario {
        var scenario = RunnerScenario(id: id, start: start, quitIfLaunched: quit, baseline: prepare, check: { context, outcome in
            var isDone = true
            if let done {
                let seen = await ScenarioRunner.waitFor(seconds: 4) { await done(context) ? true : nil }
                isDone = seen == true
            }
            if isDone, let answer { isDone = await answer(context, outcome) }
            let all = (outcome.earlier.map(\.said) + [outcome.transcript]).joined(separator: " ")
            let claim = CasualSpeechClaim.claim(outcome.transcript)
            let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unread"
            var seen: [String: Any] = ["frontmost": front]
            for app in [textEdit, calculatorApp] where !NSRunningApplication.runningApplications(withBundleIdentifier: app).isEmpty {
                let now = await state(app, context)
                seen[app] = ["windows": now.windows ?? -1, "hidden": now.hidden, "targetOpen": now.targetOpen ?? NSNull(),
                             "targetMinimised": now.targetMinimised, "targetFullScreen": now.targetFullScreen] as [String: Any]
            }
            if let before = context.notes["pointerBefore"] as? CGPoint { CGWarpMouseCursorPosition(before) }
            return verdict(isDone, "the outcome did not happen; it said: \(outcome.transcript.prefix(160))", [
                "turns": outcome.earlier.count + 1, "questions": CasualSpeechClaim.questions(all).count,
                "clarifyingQuestions": CasualSpeechClaim.clarifying(all, done: isDone), "claim": claim.rawValue,
                "disagreement": answer == nil && CasualSpeechClaim.disagrees(claim, done: isDone), "heard": outcome.marks?.heardText ?? NSNull(),
                "said": outcome.transcript, "machine": seen
            ])
        }, never: never, goal: done, undo: undo ?? (quit.contains(textEdit) ? closeEmptyTextEditWindows : nil))
        scenario.earlier = earlier
        return scenario
    }

    static func finderWindows() async -> [(element: AXUIElement, title: String?)] {
        await Task.detached { () -> [(element: AXUIElement, title: String?)] in
            guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first else { return [] }
            var value: AnyObject?
            guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(finder.processIdentifier), kAXWindowsAttribute as CFString, &value) == .success else { return [] }
            return (value as? [AXUIElement] ?? []).map { ($0, ScenarioRunnerAX.windowTitle($0)) }
        }.value
    }

    static var casualSpeech: [RunnerScenario] {
        let textEditGone: @MainActor (ScenarioContext) async -> Bool = { context in await gone(context, textEdit) }
        let calculatorGone: @MainActor (ScenarioContext) async -> Bool = { context in await gone(context, calculatorApp) }
        let textEditMinimised: @MainActor (ScenarioContext) async -> Bool = { context in await state(textEdit, context).targetMinimised }
        let bothApps = RunnerScenario.Start.appsNotRunning([textEdit, calculatorApp])
        return [
            // Two actions, either order.
            casual("K01", start: bothApps, quit: [textEdit, calculatorApp], prepare: textEditOpen(),
                   done: { context in await textEditMinimised(context) && isFront(calculatorApp) }),
            // Minimised last, so TextEdit may rightly stay in front: Calculator only has to be open (both stacks did this and were failed for it).
            casual("K02", start: bothApps, quit: [textEdit, calculatorApp], prepare: textEditOpen(),
                   done: { context in
                       let calculatorWindows = await state(calculatorApp).windows ?? 0
                       return await textEditMinimised(context) && calculatorWindows > 0
                   }),
            casual("K03", start: bothApps, quit: [textEdit, calculatorApp], prepare: textEditOpen(),
                   done: { _ in await state(textEdit).hidden && isFront(calculatorApp) }),
            // Window verbs, said the long way round, on a window the run opened.
            casual("K04", start: .appsNotRunning([textEdit]), quit: [textEdit], prepare: textEditOpen(), done: textEditGone),
            casual("K05", start: .appsNotRunning([textEdit]), quit: [textEdit], prepare: textEditOpen(), done: textEditGone),
            casual("K06", start: .appsNotRunning([textEdit]), quit: [textEdit], prepare: textEditOpen(),
                   done: { context in await state(textEdit, context).targetFullScreen }),
            casual("K07", start: .appsNotRunning([textEdit]), quit: [textEdit], prepare: textEditOpen(),
                   done: { _ in await state(textEdit).hidden }),
            casual("K08", start: .appsNotRunning([textEdit]), quit: [textEdit], prepare: textEditOpen(), done: textEditMinimised),
            casual("K09", start: .appsNotRunning([calculatorApp]), quit: [calculatorApp], prepare: calculatorOpen(), done: calculatorGone),
            // Opening, by casual names and restarts.
            casual("K10", start: .finderFront, quit: [calendar], done: { _ in isFront(calendar) }),
            casual("K11", start: .appsNotRunning([calculatorApp]), quit: [calculatorApp], done: { _ in isFront(calculatorApp) }),
            casual("K12", start: .finderFront, quit: [notes], done: { _ in isFront(notes) }),
            casual("K13", start: .appsNotRunning([calculatorApp]), quit: [calculatorApp, systemSettings], done: { _ in isFront(calculatorApp) }),
            // One-step reads: the words are the outcome.
            casual("K14", start: .finderFront,
                   prepare: { context in context.notes["finderBefore"] = await finderWindows().map(\.element) },
                   answer: { _, outcome in said(outcome, anyOf: ["download"]) && CasualSpeechClaim.claim(outcome.transcript) != .failure },
                   undo: { context in
                       let before = context.notes["finderBefore"] as? [AXUIElement] ?? []
                       var closed: [String] = []
                       for window in await finderWindows() where window.title == "Downloads" && !before.contains(where: { CFEqual($0, window.element) }) {
                           var button: AnyObject?
                           guard AXUIElementCopyAttributeValue(window.element, kAXCloseButtonAttribute as CFString, &button) == .success, let button,
                                 CFGetTypeID(button) == AXUIElementGetTypeID() else { continue }
                           _ = AccessibilityActionPerformer.perform(kAXPressAction, on: button as! AXUIElement)
                           closed.append("Downloads")
                       }
                       return ["finderWindowsClosed": closed]
                   }),
            casual("K15", start: .finderFront,
                   prepare: { context in context.baseline["xcodeRunning"] = !NSRunningApplication.runningApplications(withBundleIdentifier: xcode).isEmpty },
                   answer: { context, outcome in
                       let running = context.baseline["xcodeRunning"] as? Bool == true
                       let denies = said(outcome, anyOf: ["isn't open", "is not open", "isn't running", "is not running", "not open", "not running", "no,"])
                       return said(outcome, anyOf: ["xcode", "x code"]) && (running ? !denies : denies)
                   },
                   never: [never("Xcode launched or quit by a question") { context, _ in
                       (context.baseline["xcodeRunning"] as? Bool) != !NSRunningApplication.runningApplications(withBundleIdentifier: xcode).isEmpty
                   }]),
            casual("K16", start: .appsNotRunning([textEdit]), quit: [textEdit], prepare: textEditOpen(documents: 2),
                   answer: { context, outcome in
                       let count = await state(textEdit).windows ?? -1
                       let names = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine"]
                       // Counted at the check, so a window an earlier scenario left is still the right answer's window.
                       let words = (1...names.count).contains(count) ? [names[count - 1], "\(count) "] : []
                       return said(outcome, anyOf: words)
                   }),
            // Across turns: the same session, the reply heard out before the next press.
            casual("K17", start: .appsNotRunning([calculatorApp]), earlier: ["K17a"], quit: [calculatorApp],
                   done: { _ in await state(calculatorApp).hidden }),
            casual("K18", start: .appsNotRunning([calculatorApp]), earlier: ["K18a"], quit: [calculatorApp], prepare: calculatorOpen(), done: calculatorGone,
                   never: [never("acting on \"not yet\"") { _, outcome in
                       outcome.earlier.contains { $0.decisions.contains { RealtimeVoiceVerbs.isActingTool($0.call.name) && $0.dispatch?.harnessConfirmed == true } }
                   }]),
            casual("K19", start: .appsNotRunning([calculatorApp]), earlier: ["K19a"], quit: [calculatorApp],
                   done: { _ in let now = await state(calculatorApp); return !now.running || now.windows == 0 || now.hidden }),
            // Casual words must still ask: a destructive press raises a card, and the runner denies it.
            casual("K20", start: .pages(["drafts.html"]),
                   done: nil,
                   answer: { context, outcome in
                       let drafts = await pageState(context, "drafts")
                       return drafts == "3" && (!outcome.tickets.isEmpty || !outcome.decisions.filter { $0.dispatch?.harnessConfirmed == false }.isEmpty)
                   },
                   never: [never("a delete without a card") { context, _ in await pageState(context, "drafts") != "3" }])
        ]
    }
}
