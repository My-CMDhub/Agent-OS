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

    // MARK: One predicate behind every answer (review 2026-10-02, round 2)

    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let bullets = String(repeating: "\u{2022}", count: 8)

    /// The forModel answer a consumer receives for `children` inside a 500 pt window.
    private func snapshot(_ children: [AccessibilityElementNode]) -> [String: Any] {
        let frame = CGRect(x: 0, y: 0, width: 500, height: 500)
        let window = AccessibilityElementNode(role: "AXWindow", subrole: nil, title: "W", value: nil,
                                              frameInAppKitCoordinates: frame, depth: 0, children: children)
        return ["ok": true, "walkStopReasons": [String](), "elements": HarnessServer.namedElements(in: window),
                "windowFrame": ["x": frame.minX, "y": frame.minY, "w": frame.width, "h": frame.height]]
    }

    private func node(_ role: String, subrole: String? = nil, title: String? = nil, value: String? = nil, frame: CGRect? = nil,
                      actions: [String] = [], subroleReadFailed: Bool = false,
                      children: [AccessibilityElementNode] = []) -> AccessibilityElementNode {
        AccessibilityElementNode(role: role, subrole: subrole, title: title, value: value,
                                 frameInAppKitCoordinates: frame ?? fieldFrame, depth: 1, children: children,
                                 publishedActionNames: actions, subroleReadFailed: subroleReadFailed)
    }

    /// A null-named secure entry and a null-named typed field are COUNTED hidden,
    /// not skipped as nameless, and neither reaches the pool.
    @Test func withheldEntriesAreCountedHiddenAndNeverOffered() {
        let response = snapshot([
            node("AXSecureTextField", value: bullets, frame: CGRect(x: 10, y: 10, width: 100, height: 20)),
            node("AXTextField", value: secret, frame: CGRect(x: 10, y: 40, width: 100, height: 20)),
            node("AXButton", title: "Post", frame: CGRect(x: 10, y: 70, width: 60, height: 20), actions: ["AXPress"])
        ])
        let (pool, hidden) = RealtimeScreenVerbs.visiblePool(fromSnapshotResponse: response, screens: [screen])
        #expect(hidden == 2 && pool.map(\.name) == ["Post"])
        let offer = RealtimeScreenVerbs.screenOffer(fromSnapshotResponse: response, words: "hunter2 secret post", screens: [screen])
        #expect(offer.privacyDroppedCount == 2 && offer.candidates.map(\.name) == ["Post"])
    }

    /// The unknown-role clause is narrow: a static text whose subrole timed out
    /// keeps its value name; an AXUnknown one named by value does not; a TITLED
    /// text field whose subrole did not read may still be a password box.
    @Test func aFailedSubroleWithholdsOnlyWhatMightBeAPasswordBox() {
        #expect(listed(field("AXUnknown", subroleReadFailed: true)).entry["name"] is NSNull)
        #expect(listed(field("AXStaticText", subroleReadFailed: true)).entry["name"] as? String == secret)
        #expect(listed(field("AXTextField", title: "Search", subroleReadFailed: true)).entry["name"] is NSNull)
    }

    @Test func nothingInsideAFieldSecureByRoleOnlyIsListed() {
        let box = node("AXSecureTextField", title: "Password", children: [node("AXStaticText", value: secret)])
        let entries = snapshot([box])["elements"] as? [[String: Any]] ?? []
        #expect(entries.count == 2 && entries[1]["name"] is NSNull)
        let json = String(decoding: (try? JSONSerialization.data(withJSONObject: entries)) ?? Data(), as: UTF8.self)
        #expect(!json.contains("hunter2"))
    }

    /// `summarise` is what `actionable`, `resolved` and `candidates` all send:
    /// an anonymous field (Chromium publishes AXShowMenu, so it is actionable)
    /// goes out with no name, never its text or its bullets.
    @Test func summariseNeverSendsAFieldsContents() {
        let typed = node("AXTextField", value: secret, actions: ["AXShowMenu"])
        let password = node("AXSecureTextField", value: bullets, actions: ["AXShowMenu"])
        let titledSecure = node("AXTextField", subrole: "AXSecureTextField", value: bullets, actions: ["AXShowMenu"])
        let window = node("AXWindow", title: "W", frame: CGRect(x: 0, y: 0, width: 500, height: 500), children: [typed, password, titledSecure])
        // The snapshot answer's own expression for the non-forModel list.
        let actionable = window.flattenedDescendants().filter(\.isActionable).map(HarnessServer.summarise)
        #expect(actionable.count == 3 && actionable.allSatisfy { $0["name"] is NSNull })
        let json = String(decoding: (try? JSONSerialization.data(withJSONObject: actionable)) ?? Data(), as: UTF8.self)
        #expect(!json.contains("hunter2") && !json.contains("SECRET") && !json.contains("\u{2022}\u{2022}"), "\(json)")
        // A placeholder-labelled field goes out by its label, as the resolver matches it.
        let search = AccessibilityElementNode(role: "AXSearchField", subrole: nil, title: nil, value: secret, placeholder: "Search people",
                                              frameInAppKitCoordinates: fieldFrame, depth: 1, children: [])
        #expect(HarnessServer.summarise(search)["name"] as? String == "Search people")
    }

    /// An ambiguous answer's `suggestedWithinNamed` is a container's wire name,
    /// never the draft of a contenteditable the match sits inside.
    @Test func aSuggestedContainerIsNeverAFieldsContents() {
        let send = { (y: CGFloat) in self.node("AXButton", title: "Send", frame: CGRect(x: 10, y: y, width: 40, height: 20), actions: ["AXPress"]) }
        let window = node("AXWindow", title: "W", frame: CGRect(x: 0, y: 0, width: 500, height: 500), children: [
            node("AXTextArea", value: secret, children: [send(10)]),
            node("AXGroup", title: "Toolbar", children: [send(100)])
        ])
        let suggestions = ElementActionIntentResolver.containerSuggestions(
            for: ElementActionIntent(role: nil, title: "Send", action: .press), inTreeRootedAt: window)
        #expect(suggestions.count == 2)
        #expect(suggestions.map(\.suggestedWithinNamed) == [nil, "Toolbar"])
    }

    /// The pointer and a position in the screenshot both refuse a password box
    /// that is one by ROLE alone (no AXSecureTextField subrole).
    @Test func aPointOverAFieldSecureByRoleIsRefused() {
        let response = snapshot([
            node("AXGroup", title: "Login", frame: CGRect(x: 0, y: 0, width: 200, height: 100), children: [
                node("AXSecureTextField", title: "Password", frame: CGRect(x: 10, y: 10, width: 100, height: 20))
            ])
        ])
        #expect(RealtimeScreenVerbs.structuralHit(at: CGPoint(x: 50, y: 20), snapshotResponse: response, screens: [screen])
            == .refused(error: "secureField"))
        #expect(HarnessPolicy.pointerRefusal(resolvedFrame: fieldFrame, nearPoint: CGPoint(x: 5, y: 5), role: "AXSecureTextField",
                                             subrole: nil, subroleReadFailed: false)?.code == "secureField")
        let snapped = RealtimeSnapNode(name: "Password", role: "AXSecureTextField", subrole: nil, frame: fieldFrame)
        #expect(RealtimeScreenVerbs.snap([snapped], windowFrame: CGRect(x: 0, y: 0, width: 500, height: 500)) == .secure)
    }

    /// The node form and the wire-entry form are one predicate: every listed
    /// entry answers both questions as the node it came from does.
    @Test func theNodeAndWireFormsOfThePredicateAgree() {
        var nodes: [AccessibilityElementNode] = []
        for role in ["AXTextField", "AXTextArea", "AXSecureTextField", "AXStaticText", "AXUnknown", "AXButton"] {
            for subrole in [nil, "AXSecureTextField"] {
                for failed in [false, true] {
                    nodes.append(node(role, subrole: subrole, value: secret, subroleReadFailed: failed))
                    nodes.append(node(role, subrole: subrole, title: "Label", value: secret, subroleReadFailed: failed))
                }
            }
        }
        for item in nodes {
            let entry = listed(item).entry
            let label = "\(item.role) \(item.subrole ?? "-") failed=\(item.subroleReadFailed) title=\(item.title != nil)"
            #expect(AccessibilityElementNode.withholdsName(entry: entry) == item.withholdsName, "\(label)")
            #expect(AccessibilityElementNode.mightBeSecure(entry: entry) == item.mightBeSecure, "\(label)")
            #expect((entry["name"] is NSNull) == item.withholdsName, "\(label)")
        }
    }
}
