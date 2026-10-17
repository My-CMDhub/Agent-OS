//
//  HaikuGapTests.swift
//  leanring-buddyTests
//
//  Three gaps the first Haiku runs left (2026-10-16): Finder Get Info's anonymous
//  disclosure triangle (E14), a Help window in another app (G07), and a new
//  reminder's anonymous title field inside its named cell (E12).
//

import ApplicationServices
import CoreGraphics
import Foundation
import Testing
@testable import Clicky

struct HaikuGapTests {
    private func node(_ role: String, value: String? = nil, frame: CGRect, element: AXUIElement? = nil,
                      children: [AccessibilityElementNode] = []) -> AccessibilityElementNode {
        AccessibilityElementNode(role: role, subrole: nil, title: nil, value: value, frameInAppKitCoordinates: frame, depth: 1,
                                 children: children, accessibilityElement: element)
    }

    @Test func anAnonymousDisclosureTriangleTakesTheLabelJustRightOfIt() {
        // Get Info, measured: triangle (16, 731, 15, 15), "General:" (31, 730, 47, 16).
        let general = node("AXDisclosureTriangle", frame: CGRect(x: 16, y: 731, width: 15, height: 15))
        let label = node("AXStaticText", value: "General:", frame: CGRect(x: 31, y: 730, width: 47, height: 16))
        let kind = node("AXStaticText", value: "Kind:", frame: CGRect(x: 23, y: 709, width: 70, height: 16))
        // A triangle whose next sibling is a row below, not beside it, stays anonymous.
        let lone = node("AXDisclosureTriangle", frame: CGRect(x: 16, y: 664, width: 15, height: 15))
        let below = node("AXStaticText", value: "--", frame: CGRect(x: 21, y: 640, width: 13, height: 16))
        let named = AccessibilityElementNode.namingDisclosureTriangles([general, label, kind, lone, below], readActions: { _ in [] })
        #expect(named[0].displayName?.raw == "General:")
        #expect(named[1].displayName?.raw == "General:")
        #expect(named[3].displayName == nil)
        #expect(named.count == 5)
    }

    @Test func aHelpMenuPressMayHandTheTaskTheHelpApp() {
        let press = RealtimeVoiceVerbs.pressMenuName
        #expect(AgentLoop.helpMenuMayOpenAnotherApp(tool: press, confirmed: true, response: ["path": ["Help", "Calculator Help"]]))
        #expect(!AgentLoop.helpMenuMayOpenAnotherApp(tool: press, confirmed: false, response: ["path": ["Help", "Calculator Help"]]))
        #expect(!AgentLoop.helpMenuMayOpenAnotherApp(tool: press, confirmed: true, response: ["path": ["File", "Open…"]]))
        #expect(!AgentLoop.helpMenuMayOpenAnotherApp(tool: RealtimeVoiceVerbs.findMenuItemsName, confirmed: true,
                                                     response: ["path": ["Help", "Calculator Help"]]))
        // Ownership still asks whether the app ran before the task.
        #expect(AgentLoop.ownership(afterOpening: press, bundle: "com.apple.tips", runningAtStart: []) == .app)
        #expect(AgentLoop.ownership(afterOpening: press, bundle: "com.apple.tips", runningAtStart: ["com.apple.tips"]) == .none)
    }

    @Test func typingAtACellGoesToTheFocusedFieldOnlyWhenTheCellHoldsIt() {
        // Distinct identities without IPC: an application element per pid.
        let titleElement = AXUIElementCreateApplication(90001)
        let notesElement = AXUIElementCreateApplication(90002)
        let title = node("AXTextField", frame: CGRect(x: 492, y: 716, width: 391, height: 20), element: titleElement)
        let notes = node("AXTextField", frame: CGRect(x: 492, y: 700, width: 426, height: 18), element: notesElement)
        let group = node("AXGroup", frame: CGRect(x: 460, y: 646, width: 466, height: 98), children: [title, notes])
        let cell = node("AXCell", frame: CGRect(x: 445, y: 646, width: 487, height: 98), children: [group])
        let elsewhere = node("AXCell", frame: CGRect(x: 445, y: 500, width: 487, height: 98))
        let focusedTitle = node("AXTextField", frame: title.frameInAppKitCoordinates, element: AXUIElementCreateApplication(90001))
        #expect(HarnessPolicy.focusedFieldHeld(by: cell, focused: focusedTitle)?.frameInAppKitCoordinates == title.frameInAppKitCoordinates)
        #expect(HarnessPolicy.focusedFieldHeld(by: elsewhere, focused: focusedTitle) == nil)
        // Focus on something that takes no text is never a typing target.
        let focusedButton = node("AXButton", frame: title.frameInAppKitCoordinates, element: AXUIElementCreateApplication(90001))
        #expect(HarnessPolicy.focusedFieldHeld(by: cell, focused: focusedButton) == nil)
    }

    // Slice 5 (2026-10-17): multi-app workflows.

    @Test func makingVerbsEndReadOnlyAndQuestionsStayReadOnly() {
        for words in ["find the biggest file in my JARVIS-sandbox folder and remind me to review it tomorrow",
                      "look up the current temperature in Sydney and put it in a new note titled JARVIS weather",
                      "jot down the tracking number"] {
            #expect(!AgentLoop.isReadOnlyTask(words: words), "\(words)")
        }
        for words in ["what does my shopping note say?", "find the biggest file in my Downloads folder",
                      "what's the record temperature in Sydney?", "where is my copy of the lease?", "check the App Store for updates"] {
            #expect(AgentLoop.isReadOnlyTask(words: words), "\(words)")
        }
    }

    @Test func anAgentStepActsInAnAppTheOwnersWordsAlsoName() {
        func app(_ name: String, _ path: String) -> RealtimeVoiceVerbs.AppName {
            RealtimeVoiceVerbs.AppName(name: name, url: URL(fileURLWithPath: path), isFileName: true)
        }
        let names = [app("Notes", "/System/Applications/Notes.app"), app("Safari", "/Applications/Safari.app"),
                     app("Weather", "/System/Applications/Weather.app"), app("Reminders", "/System/Applications/Reminders.app")]
        let m03 = "summarise the lighthouse page I have open in Safari into a new note titled JARVIS lighthouse"
        // R1 already names Notes by "a new note"; no task noun is needed.
        #expect(RealtimeHeardCheck.wordsNameTheApp(transcript: m03, named: "Notes", among: names))
        #expect(RealtimeHeardCheck.wordsNameTheApp(transcript: "look up the temperature in Sydney and put it in a new note", named: "Notes", among: names))
        #expect(RealtimeHeardCheck.decide(transcript: m03, named: "Notes", among: names, toolName: RealtimeVoiceVerbs.pressMenuName).outcome
            == .heardNamedMismatch)
        #expect(RealtimeVoiceConnection.agentStepNamedByOwnersWords(outcome: .heardNamedMismatch, wordsNameTheApp: true))
        #expect(RealtimeVoiceConnection.agentStepNamedByOwnersWords(outcome: .appNameUnclear, wordsNameTheApp: true))
        // Words that do not name the app, ambiguity and an unconfirmed retry still refuse.
        #expect(!RealtimeVoiceConnection.agentStepNamedByOwnersWords(outcome: .heardNamedMismatch, wordsNameTheApp: false))
        #expect(!RealtimeVoiceConnection.agentStepNamedByOwnersWords(outcome: .ambiguousApp, wordsNameTheApp: true))
        #expect(!RealtimeVoiceConnection.agentStepNamedByOwnersWords(outcome: .unconfirmedRetry, wordsNameTheApp: true))
        #expect(!RealtimeHeardCheck.wordsNameTheApp(transcript: m03, named: "Reminders", among: names))
    }
}
