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

    @Test func aVisionTargetBecomesAVisionClickAndAPointerTargetCarriesTheOwnersPointer() throws {
        let press = RealtimeToolCall(callID: "p", name: "press_element", appName: "Google Chrome", elementName: "Launch demo", x: 0.24, y: 0.54)
        let seen = RealtimeScreenTarget(candidate: nil, point: CGPoint(x: 340, y: 410), app: nil, source: .vision)
        let line = object(try RealtimeOpenAppTool.harnessRequestLine(for: press, expectApp: "com.google.Chrome", screenTarget: seen).get())
        #expect(line["verb"] as? String == "visionClick")
        #expect(line["title"] as? String == "Launch demo")
        #expect((line["nearPoint"] as? [String: Double])?["x"] == 340)
        #expect(line["expectApp"] as? String == "com.google.Chrome")
        #expect(line["ownerPointed"] == nil)
        // "Click this one", nothing AX can name under the owner's pointer.
        let pointed = RealtimeToolCall(callID: "q", name: "press_element", appName: "Google Chrome", underPointer: true)
        let mouse = RealtimeScreenTarget(candidate: nil, point: CGPoint(x: 500, y: 300), app: nil, source: .underPointer)
        let owner = object(try RealtimeOpenAppTool.harnessRequestLine(for: pointed, expectApp: "com.google.Chrome", screenTarget: mouse).get())
        #expect(owner["verb"] as? String == "visionClick")
        #expect(owner["ownerPointed"] as? Bool == true)
        #expect(owner["title"] == nil)
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
        // AX names something there that it cannot press (a canvas's labelled group): sight, at the model's point.
        let group = RealtimeScreenCandidate(name: "Game area", role: "AXGroup", frame: CGRect(x: 200, y: 300, width: 400, height: 300),
                                            position: "centre", pressable: false)
        let overGroup = try await resolve(named, hit: .element(group, app: "com.google.Chrome")).get()
        #expect(overGroup.source == .vision && overGroup.point == CGPoint(x: 360, y: 450))
        // A pressable control there is AX's to press: never sight.
        let button = RealtimeScreenCandidate(name: "Start", role: "AXButton", frame: CGRect(x: 340, y: 440, width: 60, height: 20), position: "centre")
        #expect(try await resolve(named, hit: .element(button, app: "com.google.Chrome")).get().source == .screenshotPoint)
        // No name: nothing to read back, so nothing is clicked.
        let bare = RealtimeToolCall(callID: "b", name: "press_element", appName: "Google Chrome", x: 0.25, y: 0.5)
        if case .failure(let refusal) = await resolve(bare, hit: .nothing) { #expect(refusal.error == "nothingAtPoint") }
        else { Issue.record("a bare position was clicked") }
        // Typing never goes by sight.
        let type = RealtimeToolCall(callID: "c", name: "type_text", appName: "Google Chrome", elementName: "Launch demo", x: 0.25, y: 0.5, text: "hi")
        if case .failure(let refusal) = await resolve(type, hit: .nothing) { #expect(refusal.error == "noFieldAtPoint") }
        else { Issue.record("typed by sight") }
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
}
