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
        #expect(AgentPlan.requiredArguments["set_value"] == [["name", "value"]])
    }
}
