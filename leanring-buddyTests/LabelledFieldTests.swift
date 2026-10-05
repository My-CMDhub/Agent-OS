//
//  LabelledFieldTests.swift
//  leanring-buddyTests
//
//  Generality suite 2026-10-06 (G15, G12, G13): type_text aimed at "Save As:"
//  or Font Book's "Search" resolved to the LABEL and the kernel refused it;
//  typing at a position answered noFieldAtPoint three times. A label leads to
//  its field, and a position types into the focused field that holds it.
//

import CoreGraphics
import Foundation
import Testing
@testable import Clicky

struct LabelledFieldTests {
    private func node(_ role: String, _ title: String?, placeholder: String? = nil, frame: CGRect,
                      children: [AccessibilityElementNode] = []) -> AccessibilityElementNode {
        AccessibilityElementNode(role: role, subrole: nil, title: title, value: nil, placeholder: placeholder,
                                 frameInAppKitCoordinates: frame, depth: 0, children: children)
    }

    @Test func aLabelLeadsToTheFieldBesideOrBelowItOrNamedLikeIt() {
        // A save sheet: "Save As:" with its field to the right, "Tags:" with its own below that.
        let saveAs = node("AXStaticText", "Save As:", frame: CGRect(x: 100, y: 500, width: 60, height: 20))
        let nameField = node("AXTextField", nil, frame: CGRect(x: 170, y: 498, width: 200, height: 24))
        let tags = node("AXStaticText", "Tags:", frame: CGRect(x: 100, y: 460, width: 60, height: 20))
        let tagsField = node("AXTextField", nil, frame: CGRect(x: 170, y: 458, width: 200, height: 24))
        let sheet = node("AXSheet", nil, frame: CGRect(x: 0, y: 300, width: 500, height: 300), children: [saveAs, nameField, tags, tagsField])
        let window = node("AXWindow", "Untitled", frame: CGRect(x: 0, y: 0, width: 800, height: 700), children: [sheet])
        func field(_ label: AccessibilityElementNode, _ chain: [AccessibilityElementNode], linked: @escaping (AccessibilityElementNode) -> Bool = { _ in false })
            -> CGRect? {
            HarnessPolicy.fieldLabelled(by: label, chain: chain, name: label.displayName?.raw ?? "", linked: linked)?.frameInAppKitCoordinates
        }
        #expect(field(saveAs, [window, sheet, saveAs]) == nameField.frameInAppKitCoordinates)
        #expect(field(tags, [window, sheet, tags]) == tagsField.frameInAppKitCoordinates)
        // The app's own link wins over geometry.
        #expect(field(saveAs, [window, sheet, saveAs], linked: { $0.frameInAppKitCoordinates == tagsField.frameInAppKitCoordinates })
            == tagsField.frameInAppKitCoordinates)

        // A label ABOVE its field (a form): the field below.
        let email = node("AXStaticText", "Email", frame: CGRect(x: 100, y: 400, width: 60, height: 20))
        let emailField = node("AXTextField", nil, frame: CGRect(x: 100, y: 370, width: 250, height: 24))
        let form = node("AXGroup", nil, frame: CGRect(x: 0, y: 300, width: 500, height: 200), children: [email, emailField])
        #expect(field(email, [window, form, email]) == emailField.frameInAppKitCoordinates)

        // Font Book: the toolbar's "Search" label sits BELOW its field; the field's placeholder says "Search".
        let searchField = node("AXSearchField", nil, placeholder: "Search", frame: CGRect(x: 600, y: 650, width: 150, height: 22))
        let searchLabel = node("AXStaticText", "Search", frame: CGRect(x: 650, y: 632, width: 40, height: 14))
        let toolbar = node("AXToolbar", nil, frame: CGRect(x: 0, y: 620, width: 800, height: 60), children: [searchField, searchLabel])
        let fontBook = node("AXWindow", "Font Book", frame: CGRect(x: 0, y: 0, width: 800, height: 700), children: [toolbar])
        #expect(field(searchLabel, [fontBook, toolbar, searchLabel]) == searchField.frameInAppKitCoordinates)

        // Two fields equally near: no guess.
        let label = node("AXStaticText", "Name", frame: CGRect(x: 100, y: 200, width: 40, height: 20))
        let left = node("AXTextField", nil, frame: CGRect(x: 150, y: 198, width: 100, height: 24))
        let under = node("AXTextField", nil, frame: CGRect(x: 100, y: 166, width: 100, height: 24))
        let tied = node("AXGroup", nil, frame: CGRect(x: 0, y: 100, width: 500, height: 200), children: [label, left, under])
        #expect(field(label, [window, tied, label]) == nil)
        // Review of 5ceefcf: "Password:" is the secure field's label, never the plain hint below it
        // (the kernel then refuses the secure field).
        let passwordLabel = node("AXStaticText", "Password:", frame: CGRect(x: 100, y: 300, width: 70, height: 20))
        let secure = node("AXSecureTextField", nil, frame: CGRect(x: 180, y: 298, width: 200, height: 24))
        let hint = node("AXTextField", nil, frame: CGRect(x: 100, y: 260, width: 200, height: 24))
        let login = node("AXGroup", nil, frame: CGRect(x: 0, y: 200, width: 500, height: 200), children: [passwordLabel, secure, hint])
        #expect(field(passwordLabel, [window, login, passwordLabel]) == secure.frameInAppKitCoordinates)
        // A label with no field anywhere: nothing.
        let lone = node("AXStaticText", "Hello", frame: CGRect(x: 10, y: 10, width: 40, height: 20))
        let empty = node("AXGroup", nil, frame: CGRect(x: 0, y: 0, width: 100, height: 100), children: [lone])
        #expect(field(lone, [window, empty, lone]) == nil)
    }

    /// A position with no nameable field types only into the FOCUSED field, and
    /// only if the point lies inside it (`requireAtPoint` on the focused frame).
    @Test func aPositionTypesIntoTheFocusedFieldThatHoldsIt() throws {
        let line = RealtimeOpenAppTool.harnessRequestLine(
            for: RealtimeToolCall(callID: "t", name: "type_text", appName: "TextEdit", text: "JARVIS test 3"),
            screenTarget: RealtimeScreenTarget(candidate: nil, point: CGPoint(x: 400, y: 300), app: nil, source: .screenshotPoint))
        let request = try JSONSerialization.jsonObject(with: Data(try line.get().utf8)) as? [String: Any] ?? [:]
        #expect(request["verb"] as? String == "type")
        #expect(request["target"] as? String == "focused")
        #expect(request["requireAtPoint"] as? Bool == true)
        #expect((request["nearPoint"] as? [String: Double])?["x"] == 400)
    }
}
