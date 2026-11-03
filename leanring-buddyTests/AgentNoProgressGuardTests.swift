//
//  AgentNoProgressGuardTests.swift
//  leanring-buddyTests
//
//  The no-progress guard against call sequences taken from real suite runs
//  (~/Library/Logs/Clicky/{launch,generality}/<stamp>/results.json). Logic only: that the harness's verification
//  says what happened on screen is proven by the live runs.
//

import Testing
@testable import Clicky

private typealias Verdict = AgentNoProgressGuard.Verdict

private func replay(_ calls: [(key: String, ok: Bool, error: String?, verification: String?)]) -> [Verdict] {
    var guardState = AgentNoProgressGuard()
    return calls.map { guardState.record(key: $0.key, ok: $0.ok, error: $0.error, verification: $0.verification) }
}

private func isHint(_ verdict: Verdict) -> Bool { if case .hint = verdict { return true } else { return false } }
private func isEnd(_ verdict: Verdict) -> Bool { if case .end = verdict { return true } else { return false } }

struct AgentNoProgressGuardTests {

    /// launch 2026-10-14T23-16-36Z E12: "Add Reminder" pressed five times, each notVerified.
    @Test func theSamePressThatShowsNoChangeEndsOnTheThird() {
        let press = (key: "press_element|Add Reminder", ok: false, error: Optional("notVerified"), verification: Optional("notObserved"))
        let verdicts = replay([press, press, press])
        #expect(verdicts[0] == .carryOn)
        #expect(isHint(verdicts[1]))
        #expect(isEnd(verdicts[2]))
    }

    /// Reads between tries do not reach the guard at all, and a different call between them does not clear the count:
    /// launch 2026-10-14T08-33-49Z E08, rename_item failing with press_menu ok between, until the step cap.
    @Test func aCycleWithADeadMemberIsCaughtWithoutACycleRule() {
        let rename = (key: "rename_item|untitled folder", ok: false, error: Optional("renameNotCommitted"), verification: String?.none)
        let menu = (key: "press_menu|File > New Folder", ok: true, error: String?.none, verification: Optional("confirmed"))
        let verdicts = replay([rename, menu, rename, menu, rename, menu, rename, menu, rename])
        #expect(verdicts.filter(isEnd).count == 1)
        #expect(isEnd(verdicts[8]))
        #expect(isHint(verdicts[2]))
    }

    /// launch 2026-10-13T09-36-52Z E03 PASSED: a day cell's performFailed four times, then the model changed route.
    /// It gets the hint, never the end.
    @Test func aFailureRepeatedFourTimesThenAnotherRouteIsNotEnded() {
        let cell = (key: "press_element|Monday", ok: false, error: Optional("performFailed"), verification: String?.none)
        let typed = (key: "type_text|New Quick Event", ok: true, error: String?.none, verification: Optional("confirmed"))
        let verdicts = replay([cell, cell, cell, cell, typed])
        #expect(!verdicts.contains(where: isEnd))
        #expect(verdicts.filter(isHint).count == 3)
    }

    /// The same words, three different places: launch 2026-10-31T03-57-29Z U04's clicks by position stayed separate.
    @Test func differentTargetsCountApart() {
        let verdicts = replay(["a", "b", "c", "d"].map { (key: "press_element|\($0)", ok: false, error: "notVerified", verification: "notObserved") })
        #expect(verdicts.allSatisfy { $0 == .carryOn })
    }

    @Test func repeatsThatShowAChangeNeverCount() {
        // Scrolling down a page: B1, A3. Each answer says elements moved.
        let scroll = (key: "scroll|down", ok: true, error: String?.none, verification: Optional("confirmed"))
        #expect(replay(Array(repeating: scroll, count: 12)).allSatisfy { $0 == .carryOn })
        // Pressing Next through a wizard, the screen changing each time.
        let next = (key: "press_element|Next", ok: true, error: String?.none, verification: Optional("confirmed"))
        #expect(replay(Array(repeating: next, count: 8)).allSatisfy { $0 == .carryOn })
        // Field after field: G15's To, Subject, body are different text, so different calls even when one shows no change.
        let fields = ["To", "Subject", "Body"].map { (key: "type_text|\($0)", ok: true, error: String?.none, verification: Optional("notObserved")) }
        #expect(replay(fields).allSatisfy { $0 == .carryOn })
    }

    /// A key's ok means posted, and its witnesses cannot see a selection move: Down through a list is not a dead key.
    @Test func aPostedKeyWithNoChangeSeenIsNotEvidence() {
        let down = (key: "press_keys|down", ok: true, error: String?.none, verification: Optional("noChangeSeen"))
        #expect(replay(Array(repeating: down, count: 10)).allSatisfy { $0 == .carryOn })
    }

    /// `ok` with verification notObserved: the same text typed into the same field, the window not moving.
    @Test func anOkThatShowedNoChangeCountsToo() {
        let type = (key: "type_text|Search|memory", ok: true, error: String?.none, verification: Optional("notObserved"))
        let verdicts = replay([type, type, type])
        #expect(isHint(verdicts[1]) && isEnd(verdicts[2]))
    }

    @Test func theKeySeparatesAimAndIgnoresTheCallID() {
        func press(_ id: String, _ name: String?, x: Double? = nil, y: Double? = nil) -> RealtimeToolCall {
            RealtimeToolCall(callID: id, name: RealtimeVoiceVerbs.pressElementName, appName: nil, elementName: name, x: x, y: y)
        }
        #expect(AgentNoProgressGuard.key(for: press("1", "Save")) == AgentNoProgressGuard.key(for: press("2", "Save")))
        #expect(AgentNoProgressGuard.key(for: press("1", "Save")) != AgentNoProgressGuard.key(for: press("1", "Cancel")))
        #expect(AgentNoProgressGuard.key(for: press("1", nil, x: 0.5, y: 0.5)) == AgentNoProgressGuard.key(for: press("2", nil, x: 0.501, y: 0.499)))
        #expect(AgentNoProgressGuard.key(for: press("1", nil, x: 0.5, y: 0.5)) != AgentNoProgressGuard.key(for: press("1", nil, x: 0.6, y: 0.5)))
    }
}
