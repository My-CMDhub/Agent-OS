import ApplicationServices
import CoreGraphics
import Foundation
import Testing
@testable import Clicky

@Suite struct DoneConditionTests {
    let profile = DoneSnapshot(windowTitle: "Dhruv Patel | LinkedIn - Google Chrome", elements: [
        DoneElement(role: "AXRadioButton", name: "Posts", selected: true, valueLength: nil),
        DoneElement(role: "AXTextArea", name: "Text editor for creating content", selected: nil, valueLength: 42)])

    @Test func conditionsReadOnlyStructure() {
        #expect(DoneCondition.holds(.windowTitleContains("LinkedIn"), in: profile))
        #expect(DoneCondition.holds(.elementSelected(role: "AXRadioButton", name: "Posts"), in: profile))
        #expect(DoneCondition.holds(.textFieldNonEmpty(label: "Text editor for creating content"), in: profile))
        #expect(!DoneCondition.holds(.elementPresent(role: "AXButton", name: "Post"), in: profile))
        #expect(DoneCondition.holds(.elementAbsent(role: "AXDialog", name: "Create a post"), in: profile))
    }

    private func state(_ role: String, subrole: String? = nil, subroleReadFailed: Bool = false,
                       value: AnyObject? = nil, valueError: AXError = .success,
                       selected: AnyObject? = nil, selectedError: AXError = .attributeUnsupported) -> (selected: Bool?, valueLength: Int?) {
        AccessibilityElementNode.observedState(role: role, subrole: subrole, subroleReadFailed: subroleReadFailed,
                                               value: value, valueError: valueError, selected: selected, selectedError: selectedError)
    }

    /// Counts only: a field's length, never on a secure, unknown-subrole or non-text value.
    @Test func valueLengthIsACountOfATextInputOnly() {
        #expect(state("AXTextArea", value: "hello" as NSString).valueLength == 5)
        #expect(state("AXTextField", value: "" as NSString).valueLength == 0)
        #expect(state("AXTextField", valueError: .noValue).valueLength == 0)
        #expect(state("AXTextField", subrole: "AXSecureTextField", value: "hunter2" as NSString).valueLength == nil)
        #expect(state("AXTextField", subroleReadFailed: true, value: "maybe a password" as NSString).valueLength == nil)
        #expect(state("AXTextField", value: NSNumber(value: 3)).valueLength == nil)
        #expect(state("AXStaticText", value: "page text" as NSString).valueLength == nil)
    }

    /// A failed read omits the key — never false, never 0.
    @Test func aFailedReadIsOmittedNotFalseOrZero() {
        let failed = state("AXTextField", valueError: .cannotComplete, selectedError: .cannotComplete)
        #expect(failed.selected == nil && failed.valueLength == nil)
        #expect(state("AXRow", selected: kCFBooleanTrue, selectedError: .failure).selected == nil)
        #expect(state("AXRow", selectedError: .attributeUnsupported).selected == nil)
    }

    /// AXSelected where answered; a radio button's / checkbox's 0/1 AXValue first (Chromium tabs).
    @Test func selectedFromAXSelectedOrAToggleValue() {
        #expect(state("AXRow", selected: kCFBooleanTrue, selectedError: .success).selected == true)
        #expect(state("AXRow", selected: kCFBooleanFalse, selectedError: .success).selected == false)
        #expect(state("AXRadioButton", value: NSNumber(value: 1)).selected == true)
        #expect(state("AXRadioButton", value: NSNumber(value: 0), selected: kCFBooleanTrue, selectedError: .success).selected == false)
        #expect(state("AXCheckBox", value: NSNumber(value: 2)).selected == nil)
        #expect(state("AXRadioButton", value: "1" as NSString).selected == nil)
        #expect(state("AXButton", value: NSNumber(value: 1)).selected == nil)
    }

    /// The forModel listing carries both keys only when read.
    @Test func namedElementsCarrySelectedAndValueLengthOnlyWhenRead() {
        let frame = CGRect(x: 0, y: 0, width: 100, height: 20)
        let window = AccessibilityElementNode(role: "AXWindow", subrole: nil, title: "W", value: nil,
                                              frameInAppKitCoordinates: CGRect(x: 0, y: 0, width: 500, height: 500), depth: 0, children: [
            AccessibilityElementNode(role: "AXRadioButton", subrole: nil, title: "Posts", value: nil,
                                     frameInAppKitCoordinates: frame, depth: 1, children: [], selected: true),
            AccessibilityElementNode(role: "AXTextArea", subrole: nil, title: "Editor", value: "draft",
                                     frameInAppKitCoordinates: frame, depth: 1, children: [], valueLength: 5)
        ])
        let listed = HarnessServer.namedElements(in: window)
        #expect(listed[0]["selected"] == nil && listed[0]["valueLength"] == nil)
        #expect(listed[1]["selected"] as? Bool == true && listed[1]["valueLength"] == nil)
        #expect(listed[2]["valueLength"] as? Int == 5 && listed[2]["selected"] == nil)
    }
}
