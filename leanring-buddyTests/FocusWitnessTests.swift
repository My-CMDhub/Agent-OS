//
//  FocusWitnessTests.swift
//  leanring-buddyTests
//
//  G05 (Reminders, 2026-10-12): after File > New Reminder the app-level
//  kAXFocusedUIElement read AXWindow / AXOutline while the caret sat in the new
//  row's AXTextField. Which witness answers when the first one names no field.
//

import Foundation
import Testing
@testable import Clicky

struct FocusWitnessTests {
    typealias Witness = AccessibilityTypePerformer.FocusWitness
    let reminders: pid_t = 501

    func choose(app: String?, systemWide: Witness? = nil, walk: [String] = []) -> AccessibilityTypePerformer.FocusChoice? {
        AccessibilityTypePerformer.chooseFocus(appRole: app, applicationPid: reminders, systemWide: systemWide, walkRoles: { walk })
    }

    @Test func aTypeableAppReadWinsWithoutAskingAnyoneElse() {
        var walked = false
        let choice = AccessibilityTypePerformer.chooseFocus(
            appRole: "AXTextField", applicationPid: reminders,
            systemWide: Witness(role: "AXTextArea", pid: reminders), walkRoles: { walked = true; return [] })
        #expect(choice == .app)
        #expect(!walked)
    }

    @Test func aWindowReadDefersToTheSystemWideFieldInTheSameApp() {
        #expect(choose(app: "AXWindow", systemWide: Witness(role: "AXTextField", pid: reminders)) == .systemWide)
    }

    @Test func aSystemWideFieldInAnotherProcessIsIgnored() {
        #expect(choose(app: "AXWindow", systemWide: Witness(role: "AXTextField", pid: 999)) == .app)
    }

    @Test func exactlyOneFocusedFieldInTheWalkAnswers() {
        #expect(choose(app: "AXOutline", systemWide: Witness(role: "AXOutline", pid: reminders),
                       walk: ["AXOutline", "AXTextField"]) == .walk(index: 1))
    }

    @Test func twoFocusedFieldsInTheWalkAreNoAnswer() {
        #expect(choose(app: "AXWindow", walk: ["AXTextField", "AXTextArea"]) == .app)
    }

    @Test func nothingElseKeepsTheOriginalReadAndNoReadAtAllIsNil() {
        #expect(choose(app: "AXWindow") == .app)
        #expect(choose(app: nil) == nil)
        #expect(choose(app: nil, systemWide: Witness(role: "AXTextField", pid: reminders)) == .systemWide)
    }

    @Test func eachChoiceNamesItsSource() {
        #expect(AccessibilityTypePerformer.FocusChoice.app.source == "app")
        #expect(AccessibilityTypePerformer.FocusChoice.systemWide.source == "systemWide")
        #expect(AccessibilityTypePerformer.FocusChoice.walk(index: 0).source == "focusedAttributeWalk")
    }
}
