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
}
