//
//  AnnotateTests.swift
//  leanring-buddyTests
//
//  `annotate` (owner 2026-10-05: "a special feature for the agent to even draw
//  something meaningful while explaining to me"): boxes, circles, arrows,
//  underlines and short labels round elements named the way point_at names
//  them, or round the owner's pointer. Read-only: it draws on Clicky's own
//  click-through window and changes nothing in any app. Pure halves here; what
//  lands on screen is the live run's screenshot.
//

import CoreGraphics
import Foundation
import Testing
@testable import Clicky

struct AnnotateTests {

    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)

    private func frameJSON(_ frame: CGRect) -> [String: Any] {
        ["x": frame.minX, "y": frame.minY, "w": frame.width, "h": frame.height]
    }

    private func element(_ role: String, _ name: String, _ frame: CGRect) -> [String: Any] {
        ["role": role, "subrole": NSNull(), "name": name, "nameIsPlausibleLabel": true, "actions": ["AXPress"],
         "nameSource": "title", "parent": NSNull(), "frame": frameJSON(frame)]
    }

    private var snapshot: [String: Any] {
        ["ok": true, "bundleIdentifier": "com.apple.TextEdit", "walkStopReasons": [String](), "windowFrame": frameJSON(screen), "elements": [
            element("AXWindow", "Untitled", screen),
            element("AXButton", "Save", CGRect(x: 100, y: 800, width: 60, height: 24)),
            element("AXButton", "Share", CGRect(x: 180, y: 800, width: 60, height: 24)),
            element("AXButton", "Delete", CGRect(x: 300, y: 800, width: 60, height: 24)),
            element("AXButton", "Delete", CGRect(x: 300, y: 100, width: 60, height: 24))
        ]]
    }

    private func shape(_ kind: String, _ name: String? = nil, pointer: Bool = false, text: String? = nil) -> [String: Any] {
        var shape: [String: Any] = ["shape": kind]
        if let name { shape["name"] = name }
        if pointer { shape["underPointer"] = true }
        if let text { shape["text"] = text }
        return shape
    }

    @Test func shapesParseFromEitherProvidersArguments() {
        let call = RealtimeToolCall.parsed(callID: "a", name: "annotate",
                                           arguments: ["shapes": [shape("box", "Save"), shape("label", "Share", text: "posts it"),
                                                                  shape("circle", pointer: true)]])
        #expect(call.shapes == [RealtimeAnnotation(shape: "box", name: "Save", underPointer: false, text: nil),
                                RealtimeAnnotation(shape: "label", name: "Share", underPointer: false, text: "posts it"),
                                RealtimeAnnotation(shape: "circle", name: nil, underPointer: true, text: nil)])
        #expect(call.appName == nil)
    }

    @Test func shapesAreCappedNamedAndTheirLabelsPlain() {
        func error(_ shapes: [[String: Any]]) -> String? {
            let call = RealtimeToolCall.parsed(callID: "a", name: "annotate", arguments: ["shapes": shapes])
            if case .failure(let refusal) = RealtimeAnnotate.validated(call.shapes) { return refusal.error }
            return nil
        }
        #expect(error([shape("box", "Save")]) == nil)
        #expect(error([]) == "missingShapes")
        #expect(error(Array(repeating: shape("box", "Save"), count: RealtimeAnnotate.maximumShapes + 1)) == "tooManyShapes")
        #expect(error([shape("scribble", "Save")]) == "invalidShape")
        #expect(error([shape("box")]) == "missingTarget")
        #expect(error([shape("label", "Save", text: "line one\nline two")]) == "invalidLabel")
        #expect(error([shape("label", "Save", text: String(repeating: "a", count: RealtimeAnnotate.maximumLabelLength + 1))]) == "invalidLabel")
        // Every kind the owner asked for.
        #expect(RealtimeAnnotate.kinds == ["box", "circle", "arrow", "underline", "label"])
    }

    @Test func eachShapeResolvesLikePointAtOrSaysWhyNot() throws {
        let pointer = RealtimeScreenTarget(candidate: nil, point: CGPoint(x: 700, y: 400), app: nil, source: .underPointer)
        let shapes = [RealtimeAnnotation(shape: "box", name: "save", underPointer: false, text: nil),          // normalised, as point_at
                      RealtimeAnnotation(shape: "arrow", name: "Delete", underPointer: false, text: nil),      // two of them
                      RealtimeAnnotation(shape: "circle", name: "Publish", underPointer: false, text: nil),   // not there
                      RealtimeAnnotation(shape: "label", name: nil, underPointer: true, text: "this one")]
        let resolved = RealtimeAnnotate.resolve(shapes, snapshotResponse: snapshot, screens: [screen], pointer: pointer)
        // Never index past what was drawn: a red test must fail, not crash the host.
        try #require(resolved.drawn.map(\.kind) == ["box", "label"])
        #expect(resolved.drawn[0].frame == CGRect(x: 100, y: 800, width: 60, height: 24))
        #expect(resolved.drawn[0].described == "box round button \"Save\"")
        // The owner's pointer with nothing named under it: a small square round the point.
        #expect(resolved.drawn[1].frame.contains(CGPoint(x: 700, y: 400)) && resolved.drawn[1].label == "this one")
        #expect(resolved.notDrawn.count == 2)
        #expect(resolved.notDrawn.contains { $0.contains("2 visible") })
        #expect(resolved.notDrawn.contains { $0.contains("Publish") })
        // No pointer read at key-down: an underPointer shape is not drawn.
        let none = RealtimeAnnotate.resolve([shapes[3]], snapshotResponse: snapshot, screens: [screen], pointer: nil)
        #expect(none.drawn.isEmpty && none.notDrawn.count == 1)
    }

    @Test func anArrowStartsOnScreenOutsideItsTargetAndPointsAtIt() {
        let target = CGRect(x: 600, y: 400, width: 80, height: 24)
        let arrow = AnnotationGeometry.arrow(to: target, on: screen)
        #expect(screen.contains(arrow.start))
        #expect(!target.contains(arrow.start))
        #expect(hypot(arrow.tip.x - target.minX, arrow.tip.y - target.midY) < 8)
        // Against the left edge it comes from the right instead.
        let edge = AnnotationGeometry.arrow(to: CGRect(x: 4, y: 400, width: 80, height: 24), on: screen)
        #expect(screen.contains(edge.start) && edge.start.x > 84)
    }

    @Test func annotateIsAReadDeclaredOnEveryStack() throws {
        #expect(RealtimeVoiceVerbs.allToolNames.contains("annotate"))
        #expect(RealtimeVoiceVerbs.readOnlyToolNames.contains("annotate"))
        #expect(!RealtimeVoiceVerbs.isActingTool("annotate"))
        #expect(RealtimeVoiceVerbs.takesFrontmostApp("annotate"))
        let gemini = (RealtimeVoiceVerbs.geminiDeclaration["functionDeclarations"] as? [[String: Any]]) ?? []
        let declared = try #require(gemini.first { $0["name"] as? String == "annotate" })
        let shapes = try #require(((declared["parameters"] as? [String: Any])?["properties"] as? [String: Any])?["shapes"] as? [String: Any])
        #expect(shapes["type"] as? String == "ARRAY")
        let item = try #require(shapes["items"] as? [String: Any])
        #expect(item["type"] as? String == "OBJECT")
        #expect(((item["properties"] as? [String: Any])?["shape"] as? [String: Any])?["enum"] as? [String] == RealtimeAnnotate.kinds)
        #expect(RealtimeVoiceVerbs.openAIDeclarations.contains { $0["name"] as? String == "annotate" })
        #expect(RealtimeVoiceVerbs.anthropicDeclarations().contains { $0["name"] as? String == "annotate" })
        // Its request is the find_on_screen read: no kernel, no ticket.
        let call = RealtimeToolCall.parsed(callID: "a", name: "annotate", arguments: ["shapes": [shape("box", "Save")]])
        let line = try RealtimeOpenAppTool.harnessRequestLine(for: RealtimeToolCall(callID: "a", name: "annotate", appName: "com.apple.TextEdit",
                                                                                    shapes: call.shapes), expectApp: "com.apple.TextEdit").get()
        #expect(line.contains(#""verb":"snapshot""#) && line.contains(#""forModel":true"#))
        // "I've highlighted it" after a drawing has its receipt.
        #expect(!RealtimeOpenAppTool.claimedWithoutReceipt(transcript: "I've highlighted the save button.", okToolNames: ["annotate"]))
    }
}
