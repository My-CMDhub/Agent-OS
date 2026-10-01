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
}
