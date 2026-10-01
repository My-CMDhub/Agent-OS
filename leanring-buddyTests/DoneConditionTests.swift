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

    // MARK: The forModel listing never names a field by what is in it

    private let secret = "hunter2-SECRET"
    private let fieldFrame = CGRect(x: 0, y: 0, width: 100, height: 20)

    /// The one listed entry for `field` inside a window, and its JSON text.
    private func listed(_ field: AccessibilityElementNode) -> (entry: [String: Any], json: String) {
        let window = AccessibilityElementNode(role: "AXWindow", subrole: nil, title: "W", value: nil,
                                              frameInAppKitCoordinates: CGRect(x: 0, y: 0, width: 500, height: 500), depth: 0, children: [field])
        let entry = HarnessServer.namedElements(in: window).last ?? [:]
        let data = (try? JSONSerialization.data(withJSONObject: entry)) ?? Data()
        return (entry, String(decoding: data, as: UTF8.self))
    }

    private func field(_ role: String, subrole: String? = nil, title: String? = nil, placeholder: String? = nil,
                       subroleReadFailed: Bool = false, selected: Bool? = nil, valueLength: Int? = nil) -> AccessibilityElementNode {
        AccessibilityElementNode(role: role, subrole: subrole, title: title, value: secret, placeholder: placeholder,
                                 frameInAppKitCoordinates: fieldFrame, depth: 1, children: [],
                                 subroleReadFailed: subroleReadFailed, selected: selected, valueLength: valueLength)
    }

    @Test func aLabelledElementKeepsItsNameAndState() {
        let button = listed(AccessibilityElementNode(role: "AXButton", subrole: nil, title: "Post", value: nil,
                                                     frameInAppKitCoordinates: fieldFrame, depth: 1, children: []))
        #expect(button.entry["name"] as? String == "Post" && button.entry["nameSource"] as? String == "title")
        let titled = listed(field("AXTextArea", title: "Editor", valueLength: 14))
        #expect(titled.entry["name"] as? String == "Editor" && titled.entry["valueLength"] as? Int == 14)
        let searched = listed(field("AXTextField", placeholder: "Search people", valueLength: 14))
        #expect(searched.entry["name"] as? String == "Search people" && searched.entry["nameSource"] as? String == "placeholder")
        #expect(searched.entry["valueLength"] as? Int == 14 && !searched.json.contains("hunter2"))
        let tab = listed(AccessibilityElementNode(role: "AXRadioButton", subrole: "AXTabButton", title: "Posts", value: nil,
                                                  frameInAppKitCoordinates: fieldFrame, depth: 1, children: [], selected: true))
        #expect(tab.entry["selected"] as? Bool == true)
    }

    /// A label-less field is listed (counted hidden by its consumers) with a null
    /// name and its length; the typed text appears nowhere in the wire form.
    @Test func aLabelLessFieldIsListedWithANullNameAndALength() {
        let typed = listed(field("AXTextField", valueLength: 14))
        #expect(typed.entry["name"] is NSNull && typed.entry["nameSource"] as? String == "value")
        #expect(typed.entry["valueLength"] as? Int == 14)
        #expect(!typed.json.contains("hunter2") && !typed.json.contains("SECRET"))
    }

    /// Secure by role, secure by subrole, or a subrole that did not read: no
    /// name, no length — even when a hand-built node carries one — and no text.
    @Test func aSecureOrUnknownFieldHasNoNameNoLengthAndNoText() {
        for node in [field("AXSecureTextField", valueLength: 14),
                     field("AXTextField", subrole: "AXSecureTextField", valueLength: 14),
                     field("AXTextField", subroleReadFailed: true, valueLength: 14),
                     field("AXTextField", subrole: "AXSecureTextField", title: "Password", valueLength: 14)] {
            let (entry, json) = listed(node)
            #expect(entry["name"] is NSNull, "\(node.role) \(node.subrole ?? "-")")
            #expect(entry["valueLength"] == nil && !json.contains("hunter2"), "\(json)")
        }
        // A static text named by its value stays named: System Settings' sidebar labels.
        let label = listed(AccessibilityElementNode(role: "AXStaticText", subrole: nil, title: nil, value: "Wi-Fi",
                                                    frameInAppKitCoordinates: fieldFrame, depth: 1, children: []))
        #expect(label.entry["name"] as? String == "Wi-Fi")
    }

    @Test func noValueIsALengthOnlyForAReadableNonSecureTextInput() {
        #expect(state("AXTextField", subrole: "AXSecureTextField", valueError: .noValue).valueLength == nil)
        #expect(state("AXSecureTextField", valueError: .noValue).valueLength == nil)
        #expect(state("AXButton", valueError: .noValue).valueLength == nil)
        #expect(state("AXStaticText", valueError: .noValue).valueLength == nil)
        // A toggle whose AXValue failed still answers through AXSelected.
        #expect(state("AXCheckBox", valueError: .cannotComplete, selected: kCFBooleanTrue, selectedError: .success).selected == true)
    }

    /// The batch's AXValue and AXSelected entries are read at their names'
    /// positions: an index that drifts off its attribute fails here.
    @Test func batchedStateIsReadAtTheValueAndSelectedPositions() {
        var unsupported = AXError.attributeUnsupported
        let failed = AXValueCreate(.axError, &unsupported)!
        func batch(value: AnyObject, selected: AnyObject) -> [AnyObject] {
            AccessibilityTreeWalker.batchedAttributeNames.map { name in
                name == kAXValueAttribute ? value : name == kAXSelectedAttribute ? selected : NSNull()
            }
        }
        let field = AccessibilityTreeWalker.batchedStateReads(batch(value: "hunter2" as NSString, selected: failed))
        #expect(field.value as? String == "hunter2" && field.valueError == .success && field.selectedError == .attributeUnsupported)
        let row = AccessibilityTreeWalker.batchedStateReads(batch(value: failed, selected: kCFBooleanTrue))
        #expect(row.valueError == .attributeUnsupported && row.selectedError == .success && (row.selected as? Bool) == true)
    }
}
