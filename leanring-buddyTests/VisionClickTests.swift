//
//  VisionClickTests.swift
//  leanring-buddyTests
//
//  The last rung (owner 2026-10-05: "click whatever is in the app's photo even
//  beyond its AX"): a press with a name and a position that AX cannot name goes
//  to the harness's `visionClick`, and the harness clicks only when Apple's
//  Vision OCR, an independent witness, reads the model's words at that point,
//  and the kernel judges those words as it judges an AX name. These tests prove
//  the pure half: the witness, the kernel's verdict on read words, the pixel
//  change verdict, the request shape and the routing. Whether a click lands is
//  the live run's question.
//

import CoreGraphics
import Foundation
import Testing
@testable import Clicky

struct VisionClickTests {

    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let window = CGRect(x: 100, y: 100, width: 1000, height: 700)

    private func word(_ text: String, _ x: CGFloat, _ width: CGFloat, y: CGFloat = 400) -> OCRWord {
        OCRWord(text: text, frame: CGRect(x: x, y: y, width: width, height: 20))
    }

    private func line(_ words: [OCRWord]) -> OCRLine {
        OCRLine(text: words.map(\.text).joined(separator: " "),
                frame: words.map(\.frame).reduce(words[0].frame) { $0.union($1) }, words: words)
    }

    // MARK: The witness

    @Test func theWordsAtThePointMustBeTheModelsLabel() {
        let launch = line([word("Launch", 300, 60), word("demo", 366, 50)])
        let point = CGPoint(x: 340, y: 410)
        // Case, spacing and punctuation dropped, as a spoken name is.
        guard case .matched(let text, let frame) = ScreenOCR.witness(lines: [launch], point: point, label: "launch  Demo!") else {
            Issue.record("the label was not read at the point"); return
        }
        #expect(text == "Launch demo")
        #expect(frame.contains(point))
        // Other words there: refused, and what was read is said.
        #expect(ScreenOCR.witness(lines: [launch], point: point, label: "Delete all") == .mismatch(textAtPoint: "Launch demo"))
        // The label's words elsewhere on the line do not count: the run must hold the point.
        let row = line([word("Settings", 300, 80), word("Launch", 600, 60)])
        if case .matched = ScreenOCR.witness(lines: [row], point: CGPoint(x: 330, y: 410), label: "Launch") {
            Issue.record("matched a word that is not at the point")
        }
        // Nothing read near the point.
        #expect(ScreenOCR.witness(lines: [launch], point: CGPoint(x: 900, y: 700), label: "Launch demo") == .noText)
        #expect(ScreenOCR.witness(lines: [], point: point, label: "Launch demo") == .noText)
        // A label that is part of a longer line still matches, and the WHOLE line is what is judged.
        let pay = line([word("Pay", 300, 40), word("now", 346, 40)])
        if case .matched(let judged, _) = ScreenOCR.witness(lines: [pay], point: CGPoint(x: 360, y: 410), label: "now") {
            #expect(judged == "Pay now")
        } else { Issue.record("the run inside the line was not found") }
    }

    @Test func theWordUnderAPointIsItsOwnBoxNeverTheNearestElsewhere() {
        let launch = line([word("Launch", 300, 60), word("demo", 366, 50)])
        #expect(ScreenOCR.wordBox(at: CGPoint(x: 380, y: 410), in: [launch])?.text == "demo")
        // Within a few points of the glyphs counts (a button's padding); far away does not.
        #expect(ScreenOCR.wordBox(at: CGPoint(x: 296, y: 410), in: [launch])?.text == "Launch")
        #expect(ScreenOCR.wordBox(at: CGPoint(x: 600, y: 410), in: [launch]) == nil)
    }

    // MARK: The kernel judges what was READ

    @Test func readWordsAreJudgedLikeAnAXName() {
        let frame = CGRect(x: 300, y: 400, width: 116, height: 20)
        #expect(HarnessHands.visionClickDecision(ocrText: "Launch demo", label: "Launch demo", frame: frame, windowFrame: window) == .allow)
        // Destructive: a card, answered once.
        if case .requireConfirmation(_, let destructive) = HarnessHands.visionClickDecision(ocrText: "Delete all", label: "Delete all",
                                                                                           frame: frame, windowFrame: window) {
            #expect(destructive)
        } else { Issue.record("a destructive word was not asked about") }
        // Irreversible: refused, even when the model's label is innocent.
        if case .refuse = HarnessHands.visionClickDecision(ocrText: "Buy now", label: "now", frame: frame, windowFrame: window) {} else {
            Issue.record("an irreversible word was not refused")
        }
        // Owner pointed with no label: the read words alone decide.
        if case .requireConfirmation = HarnessHands.visionClickDecision(ocrText: "Remove", label: nil, frame: frame, windowFrame: window) {} else {
            Issue.record("a destructive word under the owner's pointer was not asked about")
        }
        // A sentence of the page is no control.
        let sentence = String(repeating: "word ", count: 40)
        if case .refuse = HarnessHands.visionClickDecision(ocrText: sentence, label: nil, frame: frame, windowFrame: window) {} else {
            Issue.record("a document-length line was clicked")
        }
        // Outside the window: unreachable.
        if case .refuse = HarnessHands.visionClickDecision(ocrText: "Launch", label: "Launch", frame: frame.offsetBy(dx: 2000, dy: 0),
                                                           windowFrame: window) {} else {
            Issue.record("a box off the window was judged reachable")
        }
    }

    // MARK: Verification: the region changed

    @Test func aRegionChangedOnlyWhenEnoughPixelsMoved() {
        let before = [UInt8](repeating: 200, count: 96 * 32)
        #expect(!ScreenOCR.changed(before: before, after: before))
        var oneSpeck = before
        oneSpeck[10] = 0
        #expect(!ScreenOCR.changed(before: before, after: oneSpeck))
        var relabelled = before
        for index in 0..<200 { relabelled[index * 3] = 20 }
        #expect(ScreenOCR.changed(before: before, after: relabelled))
        // A capture that did not decode, or another size: never "changed".
        #expect(!ScreenOCR.changed(before: before, after: []))
    }

    // MARK: The request

    @Test func visionClickDecodesOnlyWithAPointAndALabelOrTheOwnersPointer() {
        func decoded(_ line: String) -> Result<HarnessRequest, HarnessRequestError> { HarnessPolicy.decode(line: line) }
        guard case .success(let request) = decoded(#"{"verb":"visionClick","title":"Launch demo","nearPoint":{"x":340,"y":410},"expectApp":"com.google.Chrome"}"#) else {
            Issue.record("a vision click did not decode"); return
        }
        #expect(request.verb == .visionClick && request.verb.isMutating)
        #expect(request.title == "Launch demo" && request.nearPoint == CGPoint(x: 340, y: 410))
        if case .failure(let error) = decoded(#"{"verb":"visionClick","title":"Launch demo"}"#) { #expect(error == .missingField("nearPoint")) }
        else { Issue.record("a vision click without a point decoded") }
        if case .failure(let error) = decoded(#"{"verb":"visionClick","nearPoint":{"x":1,"y":2}}"#) { #expect(error == .missingField("title")) }
        else { Issue.record("a vision click with no words and no owner pointer decoded") }
        guard case .success(let pointed) = decoded(#"{"verb":"visionClick","ownerPointed":true,"nearPoint":{"x":1,"y":2}}"#) else {
            Issue.record("the owner's pointer did not decode"); return
        }
        #expect(pointed.ownerPointed)
        // The model's words go on a card and into the audit: a plain label only.
        if case .failure(let error) = decoded(#"{"verb":"visionClick","title":"a\nb","nearPoint":{"x":1,"y":2}}"#) { #expect(error.code == "invalidField") }
        else { Issue.record("a label with a newline decoded") }
        // ownerPointed is the vision click's alone.
        if case .failure(let error) = decoded(#"{"verb":"click","title":"Go","ownerPointed":true}"#) { #expect(error.code == "invalidField") }
        else { Issue.record("ownerPointed decoded on another verb") }
    }

    private func object(_ line: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]) ?? [:]
    }

    /// Owner's ruling 2026-10-31 (universal screen hands) changed this: a press with nothing AX names at the point
    /// was `visionClick` (words read back, front window only); it is now the harness's `pointer` click at the point,
    /// judged there by what is drawn, the model's words as its label.
    @Test func aVisionTargetBecomesAPointerClickAndAPointerTargetToo() throws {
        let press = RealtimeToolCall(callID: "p", name: "press_element", appName: "Google Chrome", elementName: "Launch demo", x: 0.24, y: 0.54)
        let seen = RealtimeScreenTarget(candidate: nil, point: CGPoint(x: 340, y: 410), app: nil, source: .vision)
        let line = object(try RealtimeOpenAppTool.harnessRequestLine(for: press, expectApp: "com.google.Chrome", screenTarget: seen).get())
        #expect(line["verb"] as? String == "pointer" && line["action"] as? String == "click")
        #expect(line["label"] as? String == "Launch demo")
        #expect((line["nearPoint"] as? [String: Double])?["x"] == 340)
        // "Click this one", nothing AX can name under the owner's pointer: the pointer, at their pointer.
        let pointed = RealtimeToolCall(callID: "q", name: "press_element", appName: "Google Chrome", underPointer: true)
        let mouse = RealtimeScreenTarget(candidate: nil, point: CGPoint(x: 500, y: 300), app: nil, source: .underPointer)
        let owner = object(try RealtimeOpenAppTool.harnessRequestLine(for: pointed, expectApp: "com.google.Chrome", screenTarget: mouse).get())
        #expect(owner["verb"] as? String == "pointer")
        #expect((owner["nearPoint"] as? [String: Double]) == ["x": 500, "y": 300])
        #expect(owner["label"] == nil)
        // A vision target is a press's alone: pointing at it is the approximate ring, as before.
        let point = RealtimeToolCall(callID: "r", name: "point_at", appName: "Google Chrome", elementName: "Launch demo", x: 0.24, y: 0.54)
        #expect(object(try RealtimeOpenAppTool.harnessRequestLine(for: point, expectApp: "com.google.Chrome", screenTarget: seen).get())["verb"] as? String
                == "highlight")
    }

    @Test func aNamedPressThatAXCannotPressFallsToSightNeverABarePosition() async throws {
        func resolve(_ call: RealtimeToolCall, hit: RealtimeScreenHit) async -> Result<RealtimeScreenTarget, RealtimeToolRefusal> {
            await RealtimeOpenAppTool.resolveScreenTarget(
                call: call, thisTurn: nil, previousTurn: nil, followUpConfirmed: nil, confirmedByYes: false, now: 0,
                screenshotDisplay: screen, keyDownPointer: nil,
                lookUp: { _ in .success(RealtimeScreenLookup(candidates: [], app: "com.google.Chrome")) },
                hitTest: { _ in hit })
        }
        let named = RealtimeToolCall(callID: "a", name: "press_element", appName: "Google Chrome", elementName: "Launch demo", x: 0.25, y: 0.5)
        let target = try await resolve(named, hit: .nothing).get()
        #expect(target.source == .vision && target.candidate == nil && target.point == CGPoint(x: 360, y: 450))
        // Owner's ruling 2026-10-31: these `.vision` targets go to the harness's `pointer`, not `visionClick`.
        // AX names something there that it cannot press (a canvas's labelled group): sight, at the model's point.
        let group = RealtimeScreenCandidate(name: "Game area", role: "AXGroup", frame: CGRect(x: 200, y: 300, width: 400, height: 300),
                                            position: "centre", pressable: false)
        let overGroup = try await resolve(named, hit: .element(group, app: "com.google.Chrome")).get()
        #expect(overGroup.source == .vision && overGroup.point == CGPoint(x: 360, y: 450))
        // A pressable control there is AX's to press: never sight.
        let button = RealtimeScreenCandidate(name: "Start", role: "AXButton", frame: CGRect(x: 340, y: 440, width: 60, height: 20), position: "centre")
        #expect(try await resolve(named, hit: .element(button, app: "com.google.Chrome")).get().source == .screenshotPoint)
        // No name (owner's ruling 2026-10-31, was nothingAtPoint): the point itself, for the pointer, which judges what is there.
        let bare = RealtimeToolCall(callID: "b", name: "press_element", appName: "Google Chrome", x: 0.25, y: 0.5)
        #expect(try await resolve(bare, hit: .nothing).get().source == .vision)
        // Typing never goes by sight.
        let type = RealtimeToolCall(callID: "c", name: "type_text", appName: "Google Chrome", elementName: "Launch demo", x: 0.25, y: 0.5, text: "hi")
        // Generality suite 2026-10-06: an anonymous field at the point is the FOCUSED field's,
        // checked by the harness against the point — still never a vision target.
        if case .success(let target) = await resolve(type, hit: .nothing) { #expect(target.source != .vision && target.candidate == nil) }
        else { Issue.record("an anonymous field at the point was refused") }
    }

    @Test func theReceiptSaysItWasDoneBySightAndWhatWasRead() {
        let call = RealtimeToolCall(callID: "p", name: "press_element", appName: "Google Chrome", elementName: "Launch demo", x: 0.2, y: 0.5)
        let target = RealtimeScreenTarget(candidate: nil, point: CGPoint(x: 340, y: 410), app: nil, source: .vision)
        let response: [String: Any] = ["ok": true, "method": "vision", "ocrText": "Launch demo\nnow", "verification": ["status": "confirmed"]]
        let result = RealtimeOpenAppTool.pressedResult(RealtimeOpenAppTool.toolResult(fromHarnessResponse: response), call: call,
                                                       target: target, response: response)
        #expect(result["method"] as? String == "vision")
        // App-drawn words, quoted and escaped: never a line of their own.
        #expect((result["ocrText"] as? String)?.contains("\n") == false)
        #expect((result["ocrText"] as? String)?.hasPrefix("\"") == true)
        #expect((result["target"] as? String)?.contains("Launch demo") == true)
    }

    /// Reminders' "Add Date" suggestions open in a second window of the same app
    /// (2026-10-19, E12/M02): a popup touching the focused window is clickable;
    /// a second document window, or one far away, is still refused.
    @Test func aTransientPopupOverTheFocusedWindowIsClickableAndNothingElseIs() {
        let popup = CGRect(x: 600, y: 300, width: 180, height: 140)
        #expect(HarnessHands.transientPopupOverFocusedWindow(subrole: "AXUnknown", frame: popup, focusedWindowFrame: window))
        #expect(HarnessHands.transientPopupOverFocusedWindow(subrole: "AXDialog", frame: popup, focusedWindowFrame: window))
        #expect(HarnessHands.transientPopupOverFocusedWindow(subrole: "AXSystemDialog", frame: popup, focusedWindowFrame: window))
        // Adjoining just below the window's edge still counts; well clear of it does not.
        #expect(HarnessHands.transientPopupOverFocusedWindow(subrole: "AXUnknown",
                                                             frame: CGRect(x: 600, y: 84, width: 180, height: 12), focusedWindowFrame: window))
        #expect(!HarnessHands.transientPopupOverFocusedWindow(subrole: "AXUnknown",
                                                              frame: CGRect(x: 1200, y: 100, width: 180, height: 140), focusedWindowFrame: window))
        // A second document window, an unread subrole, or a zero-area frame: refused.
        #expect(!HarnessHands.transientPopupOverFocusedWindow(subrole: "AXStandardWindow", frame: popup, focusedWindowFrame: window))
        #expect(!HarnessHands.transientPopupOverFocusedWindow(subrole: nil, frame: popup, focusedWindowFrame: window))
        #expect(!HarnessHands.transientPopupOverFocusedWindow(subrole: "AXUnknown", frame: CGRect(x: 600, y: 300, width: 0, height: 0),
                                                              focusedWindowFrame: window))
    }

    /// The walk's window choice for names: only the same app's transient popups, never the
    /// focused window twice, a second document window, or a popup far away (2026-10-19, M02).
    @Test func onlyTransientPopupsOverTheFocusedWindowJoinTheNameWalk() {
        let popup = CGRect(x: 600, y: 300, width: 180, height: 140)
        let windows: [(isFocused: Bool, subrole: String?, frame: CGRect)] = [
            (true, "AXStandardWindow", window),                                   // the focused window itself
            (false, "AXDialog", popup),                                           // Add Date's suggestions
            (false, "AXStandardWindow", popup),                                   // a second document window
            (false, "AXUnknown", CGRect(x: 1200, y: 100, width: 180, height: 140)), // far from the window
            (false, nil, popup),                                                   // subrole unread
            (false, "AXUnknown", .zero)                                            // frame unread
        ]
        #expect(HarnessHands.transientPopupIndices(among: windows, focusedWindowFrame: window) == [1])
        // Its elements join the one list with parents shifted past the focused window's, marked popup.
        let shifted = HarnessServer.popupElements([["name": "Suggestions", "parent": NSNull()], ["name": "Tomorrow", "parent": 0]], offset: 5)
        #expect(shifted[1]["parent"] as? Int == 5 && shifted[0]["parent"] is NSNull && shifted.allSatisfy { $0["popup"] as? Bool == true })
    }

    /// A popup's row is found by name and pressed by sight at its own centre, its name read back there.
    @Test func aPopupRowFoundByNameIsPressedBySightAtItsCentre() throws {
        let frame = { (rect: CGRect) -> [String: Any] in ["x": rect.minX, "y": rect.minY, "w": rect.width, "h": rect.height] }
        let row = CGRect(x: 620, y: 400, width: 120, height: 20)
        let response: [String: Any] = ["ok": true, "bundleIdentifier": "com.apple.reminders", "windowFrame": frame(window), "elements": [
            ["name": "Add Date", "role": "AXTextField", "frame": frame(CGRect(x: 300, y: 500, width: 100, height: 20)), "parent": NSNull()],
            ["name": "Tomorrow", "role": "AXStaticText", "frame": frame(row), "parent": NSNull(), "popup": true]
        ]]
        let found = RealtimeScreenVerbs.liveCandidates(named: "Tomorrow", fromSnapshotResponse: response, screens: [screen])
        #expect(found.count == 1 && found.first?.inPopup == true)
        #expect(RealtimeScreenVerbs.liveCandidates(named: "Add Date", fromSnapshotResponse: response, screens: [screen]).first?.inPopup == false)
        let target = try #require(found.first)
        let call = RealtimeToolCall(callID: "p", name: "press_element", appName: "com.apple.reminders", elementName: "Tomorrow")
        let line = try RealtimeOpenAppTool.harnessRequestLine(for: call, expectApp: "com.apple.reminders", screenTarget:
            RealtimeScreenTarget(candidate: target, point: CGPoint(x: row.midX, y: row.midY), app: "com.apple.reminders", source: .liveName)).get()
        let request = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        #expect(request["verb"] as? String == "visionClick" && request["title"] as? String == "Tomorrow")
        let point = request["nearPoint"] as? [String: Double]
        #expect(point?["x"] == Double(row.midX) && point?["y"] == Double(row.midY))
    }

    /// OCR wraps a label over two lines ("Today" above "19/10/2026", E12 2026-10-19): the line break
    /// is a space. Each word must still be read exactly, and the run must still hold the point.
    @Test func aLabelWrappedOverTwoLinesIsOneRunOfWords() {
        let today = line([word("Today", 620, 50, y: 410)])
        let date = line([word("19/10/2026", 620, 90, y: 390)])
        let point = CGPoint(x: 650, y: 410)
        guard case .matched(let text, _) = ScreenOCR.witness(lines: [date, today], point: point, label: "Today 19/10/2026") else {
            Issue.record("the wrapped label was not read at the point"); return
        }
        #expect(text == "Today 19/10/2026", "read top to bottom, whatever order OCR listed the lines in")
        #expect(ScreenOCR.witness(lines: [date, today], point: point, label: "Today 20/10/2026")
            == .mismatch(textAtPoint: "19/10/2026\nToday"), "a different date is still a mismatch")
        #expect(ScreenOCR.witness(lines: [date, today], point: point, label: "19/10/2026 Today")
            == .mismatch(textAtPoint: "19/10/2026\nToday"), "out of reading order is not the label")
    }
}
