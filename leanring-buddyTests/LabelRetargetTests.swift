//
//  LabelRetargetTests.swift
//  leanring-buddyTests
//
//  Live 2026-10-02: a Google result's title is an AXHeading inside the AXLink,
//  the name resolved to the heading, and the kernel asked "unrecognised role
//  AXHeading" about an ordinary link. A label names the link or button it sits
//  in; the press goes to, and is judged on, that control. Pure; SYNTHETIC.
//

import ApplicationServices
import CoreGraphics
import Foundation
import Testing
@testable import Clicky

struct LabelRetargetTests {
    let bounds = CGRect(x: 0, y: 0, width: 1200, height: 900)

    func node(_ role: String, _ title: String? = nil, pressable: Bool = true) -> AccessibilityElementNode {
        AccessibilityElementNode(role: role, subrole: nil, title: title, value: nil,
                                 frameInAppKitCoordinates: CGRect(x: 170, y: 600, width: 587, height: 60), depth: 1,
                                 children: [], publishedActionNames: pressable ? [kAXPressAction, "AXShowMenu"] : [])
    }

    /// "AXLink Profile" for the control picked, nil for none (the node type is not Equatable).
    func picked(_ chain: [AccessibilityElementNode]) -> String? {
        HarnessPolicy.controlLabelled(byLastOf: chain).map { "\($0.role) \($0.displayName?.raw ?? "")" }
    }

    @Test func aLabelInsideALinkOrButtonPressesThatControl() {
        let window = node("AXWebArea", pressable: false)
        let link = node("AXLink", "Superloop - Fast and Reliable Internet Service Provider in ... superloop.com")
        // Chromium gives the heading AXPress too (click-ancestor): role, not the press, says label.
        let heading = node("AXHeading", "Superloop - Fast and Reliable Internet Service Provider in ...")
        let wrapper = node("AXGroup")
        #expect(picked([window, link, heading]) == "AXLink \(link.displayName!.raw)")
        #expect(picked([window, link, wrapper, heading]) == "AXLink \(link.displayName!.raw)")
        #expect(picked([window, link, heading, node("AXStaticText", "Superloop")]) == "AXLink \(link.displayName!.raw)")
        #expect(picked([window, node("AXButton", "Log In"), node("AXImage", "Arrow")]) == "AXButton Log In")
        // Measured on the hands probe 2026-10-03: Chrome published no AXPress anywhere; the role still says link.
        #expect(picked([window, node("AXLink", "Probe result title example.com › probe", pressable: false),
                        node("AXHeading", "Probe result title", pressable: false)]) == "AXLink Probe result title example.com › probe")
    }

    @Test func nothingElseIsRetargeted() {
        let window = node("AXWebArea", pressable: false)
        let link = node("AXLink", "Profile")
        // A control named directly is itself.
        #expect(picked([window, node("AXButton", "Buy"), link]) == nil)
        // A named group between them is a thing of its own ("Order #42"), so is any other control.
        #expect(picked([window, link, node("AXGroup", "Order #42"), node("AXHeading", "Order")]) == nil)
        #expect(picked([window, link, node("AXCheckBox", "Agree"), node("AXStaticText", "Agree")]) == nil)
        // Not a link or button, no name, or too far up.
        #expect(picked([window, node("AXRow", "Mail"), node("AXStaticText", "Mail")]) == nil)
        #expect(picked([window, node("AXLink"), node("AXHeading", "Me")]) == nil)
        let deep = [window, link, node("AXGroup"), node("AXGroup"), node("AXGroup"), node("AXHeading", "Me")]
        #expect(picked(deep) == nil)
        #expect(picked([node("AXHeading", "Me")]) == nil)
    }

    // Live 2026-10-08 (S1, runs F47F8E44, 0B3305D7): Meet's "Create a meeting for later" is a web
    // AXMenuItem with no AXPress; it was carded, then sent to select. It is clicked; its words still decide.
    @Test func aWebMenuItemIsClickedAsNavigationAndItsWordsStillDecide() {
        func click(_ name: String) -> SafetyDecision {
            ActionSafetyKernel.evaluate(intent: ElementActionIntent(role: "AXMenuItem", title: name, action: .click),
                                        resolvedNode: node("AXMenuItem", name, pressable: false), matchCount: 1, visibleBounds: bounds)
        }
        #expect(click("Create a meeting for later") == .allow)
        #expect(click("Delete meeting") == .requireConfirmation(reason: "title suggests a destructive action: delete", destructive: true))
        if case .refuse = click("Erase all") {} else { Issue.record("an irreversible word must still refuse") }
        // press_element now clicks it rather than selecting it.
        let item = RealtimeScreenCandidate(name: "Create a meeting for later", role: "AXMenuItem", frame: .zero, position: "", pressable: false)
        #expect(item.clickTarget?.role == "AXMenuItem")
    }

    @Test func theControlIsJudgedAndTheLabelsWordsStillDecide() {
        func decide(control: String, role: String = "AXLink", label: String) -> SafetyDecision {
            ActionSafetyKernel.evaluate(intent: ElementActionIntent(role: "AXHeading", title: label, action: .click),
                                        resolvedNode: node(role, control), matchCount: 1, visibleBounds: bounds, labelTitle: label)
        }
        // The live case: the heading asked "unrecognised role"; the link it names is navigation.
        #expect(ActionSafetyKernel.evaluate(intent: ElementActionIntent(role: "AXHeading", title: "Superloop", action: .click),
                                            resolvedNode: node("AXHeading", "Superloop"), matchCount: 1, visibleBounds: bounds)
                == .requireConfirmation(reason: "unrecognised role AXHeading"))
        #expect(decide(control: "Superloop superloop.com", label: "Superloop") == .allow)
        #expect(decide(control: "Account", role: "AXButton", label: "Account") == .allow)
        // Destructive or irreversible words on either the heading or the link still escalate or refuse.
        #expect(decide(control: "Settings", label: "Delete account")
                == .requireConfirmation(reason: "title suggests a destructive action: delete", destructive: true))
        #expect(decide(control: "Remove this post", label: "Post title")
                == .requireConfirmation(reason: "title suggests a destructive action: remove", destructive: true))
        #expect(decide(control: "Checkout", label: "Buy now") == .refuse(reason: ActionSafetyKernel.irreversibleRefusalReason(keyword: "buy")))
        #expect(decide(control: "Empty Trash", role: "AXButton", label: "Bin")
                == .refuse(reason: ActionSafetyKernel.irreversibleRefusalReason(keyword: "empty trash")))
    }

    // Launch suite U02 2026-10-13 (run 4206F2B3): "turn off Wi-Fi" aimed at the AXStaticText
    // "Wi‑Fi" BESIDE the switch (the switch's AXTitleUIElement), the harness selected it
    // (`alreadySelected`), and the switch's card never fired. The label now reaches its control.
    func row(label: String = "Wi\u{2011}Fi", claimants: [String?]) -> (window: AccessibilityElementNode, label: AccessibilityElementNode) {
        let labelNode = AccessibilityElementNode(role: "AXStaticText", subrole: nil, title: nil, value: label,
                                                 frameInAppKitCoordinates: CGRect(x: 400, y: 700, width: 60, height: 20), depth: 3, children: [])
        let switches = claimants.enumerated().map { index, claimed in
            AccessibilityElementNode(role: "AXCheckBox", subrole: "AXSwitch", title: nil, value: nil, labelledBy: claimed,
                                     frameInAppKitCoordinates: CGRect(x: 900, y: 699 - CGFloat(index) * 40, width: 38, height: 22), depth: 3,
                                     children: [], publishedActionNames: [kAXPressAction])
        }
        let group = AccessibilityElementNode(role: "AXGroup", subrole: nil, title: nil, value: nil,
                                             frameInAppKitCoordinates: CGRect(x: 380, y: 600, width: 600, height: 140), depth: 2,
                                             children: [labelNode] + switches)
        let window = AccessibilityElementNode(role: "AXWindow", subrole: nil, title: "Wi\u{2011}Fi", value: nil,
                                              frameInAppKitCoordinates: bounds, depth: 0, children: [group])
        return (window, labelNode)
    }

    @Test func aLabelBesideTheSwitchItNamesPressesThatSwitchAndIsCarded() {
        let wifi = "Wi\u{2011}Fi"
        let (window, label) = row(claimants: [wifi])
        let control = HarnessPolicy.controlNamed(byLabel: label, inWindow: window, linked: nil)
        #expect(control?.role == "AXCheckBox")
        guard let control else { return }
        // Judged as a click on the switch (a select would go uncarded), the label's words checked too.
        guard case .requireConfirmation = ActionSafetyKernel.evaluate(
            intent: ElementActionIntent(role: "AXStaticText", title: wifi, action: .click), resolvedNode: control, matchCount: 1,
            visibleBounds: bounds, labelTitle: wifi) else { Issue.record("the Wi-Fi switch reached by its label was not carded"); return }
        #expect(HarnessPolicy.verbAfterLabelRetarget(.select) == .click)
        #expect(HarnessPolicy.verbAfterLabelRetarget(.press) == .press)
    }

    @Test func aLabelWithNoOrTwoClaimantsIsLeftAlone() {
        let wifi = "Wi\u{2011}Fi"
        let none = row(claimants: [])
        #expect(HarnessPolicy.controlNamed(byLabel: none.label, inWindow: none.window, linked: nil) == nil)
        let other = row(claimants: ["Ask to join networks"])
        #expect(HarnessPolicy.controlNamed(byLabel: other.label, inWindow: other.window, linked: nil) == nil)
        // Two controls claim the same label: never guess.
        let two = row(claimants: [wifi, wifi])
        #expect(HarnessPolicy.controlNamed(byLabel: two.label, inWindow: two.window, linked: nil) == nil)
        // Live identity decides when it can be read: a label that is not the switch's (the sidebar's "Wi‑Fi") stays.
        let one = row(claimants: [wifi])
        #expect(HarnessPolicy.controlNamed(byLabel: one.label, inWindow: one.window, linked: { _ in false }) == nil)
        #expect(HarnessPolicy.controlNamed(byLabel: two.label, inWindow: two.window, linked: { $0.frameInAppKitCoordinates.minY < 690 })?
            .frameInAppKitCoordinates.minY == 659)
        // Without identity, a claimant off the label's row is no answer.
        let far = row(claimants: [nil, wifi])
        #expect(HarnessPolicy.controlNamed(byLabel: far.label, inWindow: far.window, linked: nil) == nil)
    }
}
