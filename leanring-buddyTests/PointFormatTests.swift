//
//  PointFormatTests.swift
//  leanring-buddyTests
//
//  The pointing format A/B (2026-10-01): F1 asks both realtime models for x, y
//  as 0-1 fractions of the screenshot (live); F2 asks each in the format it was
//  trained on — Gemini a [y, x] point normalised to 0-1000, OpenAI pixels of
//  the screenshot. Pure half only: the schema each format declares, how a call
//  in either format becomes the same fraction, and how `--point-format-probe`
//  scores a raw aim against AX ground truth. Which format aims better is the
//  probe's question, never a unit test's. Fixtures are SYNTHETIC.
//

import CoreGraphics
import Foundation
import Testing
@testable import Clicky

struct PointFormatTests {

    private func properties(_ declarations: [[String: Any]], _ tool: String) -> [String: Any] {
        let declaration = declarations.first { $0["name"] as? String == tool }
        return ((declaration?["parameters"] as? [String: Any])?["properties"] as? [String: Any]) ?? [:]
    }

    @Test func eachFormatDeclaresItsOwnAim() {
        // F1 (live) is unchanged: fractions on both stacks.
        #expect(RealtimePointFormat.live == .fractions)
        let fractions = properties(RealtimeVoiceVerbs.openAIDeclarations(pointFormat: .fractions), "point_at")
        #expect((fractions["x"] as? [String: Any])?["description"] as? String == (properties(RealtimeVoiceVerbs.openAIDeclarations, "point_at")["x"] as? [String: Any])?["description"] as? String)
        // F2, OpenAI: pixels of the screenshot.
        let pixels = properties(RealtimeVoiceVerbs.openAIDeclarations(pointFormat: .native), "point_at")
        #expect(((pixels["x"] as? [String: Any])?["description"] as? String)?.contains("pixels") == true)
        // F2, Gemini: one [y, x] point, 0-1000, and no x or y.
        let gemini = (RealtimeVoiceVerbs.geminiDeclaration(pointFormat: .native)["functionDeclarations"] as? [[String: Any]]) ?? []
        let point = properties(gemini, "press_element")
        #expect(point["x"] == nil && point["y"] == nil)
        #expect((point["point"] as? [String: Any])?["type"] as? String == "ARRAY")
        #expect(((point["point"] as? [String: Any])?["items"] as? [String: Any])?["type"] as? String == "NUMBER")
        #expect(((point["point"] as? [String: Any])?["description"] as? String)?.contains("1000") == true)
        // The prompt says the same as the schema.
        let nativeGemini = RealtimeOpenAppTool.systemPrompt(pointFormat: .native, stack: .geminiLive)
        let nativeOpenAI = RealtimeOpenAppTool.systemPrompt(pointFormat: .native, stack: .openAIRealtime)
        #expect(!nativeGemini.contains("fractions from 0 to 1") && nativeGemini.contains("0 to 1000"))
        #expect(!nativeOpenAI.contains("fractions from 0 to 1") && nativeOpenAI.contains("pixels"))
        #expect(RealtimeOpenAppTool.systemPrompt(pointFormat: .fractions, stack: .geminiLive) == RealtimeOpenAppTool.systemPrompt)
    }

    @Test func everyFormatBecomesTheSameFraction() {
        let gemini = RealtimeOpenAppTool.parseGemini(["toolCall": ["functionCalls": [
            ["id": "g", "name": "point_at", "args": ["point": [250, 500]]]
        ]]]).first
        #expect(gemini?.point == [250, 500])
        let fromGemini = gemini.map { RealtimePointFormat.normalised($0, format: .native, stack: .geminiLive, screenshotPixels: nil) }
        #expect(fromGemini?.x == 0.5 && fromGemini?.y == 0.25)
        let openAI = RealtimeToolCall(callID: "o", name: "press_element", appName: nil, x: 960, y: 300)
        let fromOpenAI = RealtimePointFormat.normalised(openAI, format: .native, stack: .openAIRealtime,
                                                        screenshotPixels: CGSize(width: 1920, height: 1200))
        #expect(fromOpenAI.x == 0.5 && fromOpenAI.y == 0.25)
        // Pixels with no known image size are no position at all.
        let unsized = RealtimePointFormat.normalised(openAI, format: .native, stack: .openAIRealtime, screenshotPixels: nil)
        #expect(unsized.x == nil && unsized.y == nil)
        // F1 is passed through untouched, and a malformed point is no position.
        let fraction = RealtimeToolCall(callID: "f", name: "point_at", appName: nil, x: 0.3, y: 0.7)
        #expect(RealtimePointFormat.normalised(fraction, format: .fractions, stack: .geminiLive, screenshotPixels: nil) == fraction)
        var bad = RealtimeToolCall(callID: "b", name: "point_at", appName: nil)
        bad.point = [500]
        #expect(RealtimePointFormat.normalised(bad, format: .native, stack: .geminiLive, screenshotPixels: nil).x == nil)
    }

    @MainActor @Test func theProbeScoresARawAimAgainstTheElementsFrame() {
        let frame = CGRect(x: 100, y: 100, width: 40, height: 20)
        let inside = PointFormatProbe.aim(CGPoint(x: 110, y: 110), at: frame)
        #expect(inside.inside && inside.toFramePt == 0 && abs(inside.toCentrePt - 10) < 0.001)
        let outside = PointFormatProbe.aim(CGPoint(x: 150, y: 110), at: frame)
        #expect(!outside.inside && abs(outside.toFramePt - 10) < 0.001)
        // Targets: short plain labels, one per name, small enough to be one control.
        let window = CGRect(x: 0, y: 0, width: 1440, height: 900)
        func element(_ name: String, _ frame: CGRect, role: String = "AXButton") -> RealtimeScreenVerbs.PoolElement {
            RealtimeScreenVerbs.PoolElement(name: name, role: role, subrole: nil, frame: frame, pressable: true, parent: nil)
        }
        let pool = [element("Models", CGRect(x: 10, y: 800, width: 80, height: 24)),
                    element("Models", CGRect(x: 10, y: 700, width: 80, height: 24)),
                    element("A very long label that reads like a sentence", CGRect(x: 10, y: 600, width: 300, height: 24)),
                    element("Main", CGRect(x: 0, y: 0, width: 1400, height: 880), role: "AXGroup"),
                    element("New Agent", CGRect(x: 1300, y: 860, width: 90, height: 24)),
                    element("General", CGRect(x: 10, y: 500, width: 120, height: 24), role: "AXRow")]
        #expect(PointFormatProbe.targets(from: pool, window: window, count: 8).map(\.name) == ["New Agent", "General"])
        // ABBA: each element's first format alternates, so neither always goes first.
        #expect(PointFormatProbe.order(forElement: 0) == [.fractions, .native])
        #expect(PointFormatProbe.order(forElement: 1) == [.native, .fractions])
    }
}
