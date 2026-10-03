//
//  RealtimeHandsVerbsTests.swift
//  leanring-buddyTests
//
//  scroll / type_text / close (owner's target level 2026-10-01: "its hands on
//  my keyboard and trackpad, with guardrails"): the harness `scroll` verb's
//  pure half (its request, which container, what came into view), and the
//  voice tools' arguments, harness lines, menu choice for a close, receipts
//  and captions. Whether a wheel event moves a real window is a live run's
//  question, never a unit test's. Fixtures are SYNTHETIC.
//

import CoreGraphics
import Foundation
import Testing
@testable import Clicky

struct RealtimeHandsVerbsTests {

    private let finder = "com.apple.finder"

    private func object(_ line: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]) ?? [:]
    }

    private func error(_ result: Result<String, RealtimeToolRefusal>) -> String? {
        if case .failure(let refusal) = result { return refusal.error }
        return nil
    }

    private func node(_ role: String, _ name: String?, _ frame: CGRect, children: [AccessibilityElementNode] = [],
                      actions: [String] = []) -> AccessibilityElementNode {
        AccessibilityElementNode(role: role, subrole: nil, title: name, value: nil, frameInAppKitCoordinates: frame, depth: 0,
                                 children: children, publishedActionNames: actions)
    }

    private func named(_ role: String, _ name: String, _ frame: CGRect, subrole: String? = nil, source: String = "title") -> [String: Any] {
        ["role": role, "subrole": subrole ?? NSNull(), "name": name, "nameIsPlausibleLabel": true, "actions": [String](),
         "nameSource": source, "parent": NSNull(), "frame": ["x": frame.minX, "y": frame.minY, "w": frame.width, "h": frame.height]]
    }

    // MARK: The harness's scroll verb

    @Test func theScrollVerbDecodesADirectionAndAnAmount() {
        guard case .success(let plain) = HarnessPolicy.decode(line: #"{"verb":"scroll","direction":"down"}"#) else {
            Issue.record("a bare scroll did not decode"); return
        }
        #expect(plain.verb == .scroll && plain.scrollDirection == .down && plain.scrollPages == 1)
        // It moves what the owner sees: the kill switch stops it and the policy file is read.
        #expect(plain.verb.isMutating)
        guard case .success(let aimed) = HarnessPolicy.decode(
            line: #"{"verb":"scroll","direction":"left","amount":2.5,"title":"Sidebar","nearPoint":{"x":10,"y":20}}"#) else {
            Issue.record("an aimed scroll did not decode"); return
        }
        #expect(aimed.scrollDirection == .left && aimed.scrollPages == 2.5 && aimed.title == "Sidebar" && aimed.nearPoint == CGPoint(x: 10, y: 20))
        #expect(HarnessPolicy.decode(line: #"{"verb":"scroll"}"#) == .failure(.missingField("direction")))
        #expect(HarnessPolicy.decode(line: #"{"verb":"scroll","direction":"sideways"}"#)
                == .failure(.invalidField(field: "direction", value: "sideways")))
        for amount in ["0", "-1", "11"] {
            guard case .failure(let refused) = HarnessPolicy.decode(line: #"{"verb":"scroll","direction":"down","amount":\#(amount)}"#) else {
                Issue.record("amount \(amount) was accepted"); continue
            }
            #expect(refused.code == "invalidField")
        }
        guard case .failure(let stray) = HarnessPolicy.decode(line: #"{"verb":"press","title":"x","direction":"down"}"#) else {
            Issue.record("a direction on a press was accepted"); return
        }
        #expect(stray.code == "invalidField")
        // type_text aims like press_element: the named field must be the one at the point.
        guard case .success(let type) = HarnessPolicy.decode(
            line: #"{"verb":"type","text":"hi","title":"Search","requireAtPoint":true,"nearPoint":{"x":1,"y":2}}"#) else {
            Issue.record("requireAtPoint on a type did not decode"); return
        }
        #expect(type.requireAtPoint)
    }

    @Test func scrollChoosesTheContainerByTargetThenPointThenSize() {
        let row = node("AXRow", "Downloads", CGRect(x: 0, y: 600, width: 200, height: 24))
        let sidebar = node("AXScrollArea", nil, CGRect(x: 0, y: 0, width: 200, height: 900), children: [row])
        let link = node("AXLink", "About", CGRect(x: 300, y: 400, width: 80, height: 20))
        let web = node("AXWebArea", "Profile", CGRect(x: 200, y: 0, width: 1240, height: 800), children: [link])
        let content = node("AXScrollArea", nil, CGRect(x: 200, y: 0, width: 1240, height: 800), children: [web])
        let window = node("AXWindow", "LinkedIn", CGRect(x: 0, y: 0, width: 1440, height: 900), children: [sidebar, content])
        // Aimed at a named element: its nearest scrolling ancestor.
        #expect(HarnessScroll.container(in: window, targetChain: [window, sidebar, row], point: nil)?.frameInAppKitCoordinates
                == sidebar.frameInAppKitCoordinates)
        // Aimed at a point: the innermost container holding it.
        #expect(HarnessScroll.container(in: window, targetChain: nil, point: CGPoint(x: 700, y: 400))?.role == "AXWebArea")
        #expect(HarnessScroll.container(in: window, targetChain: nil, point: CGPoint(x: 100, y: 400))?.role == "AXScrollArea")
        // Not aimed: the largest, outermost first.
        let largest = HarnessScroll.container(in: window, targetChain: nil, point: nil)
        #expect(largest?.role == "AXScrollArea" && largest?.frameInAppKitCoordinates == content.frameInAppKitCoordinates)
        // A window with nothing scrollable: none, and the verb falls back to the window itself.
        #expect(HarnessScroll.container(in: node("AXWindow", "W", window.frameInAppKitCoordinates, children: [row]), targetChain: nil,
                                        point: nil) == nil)
    }

    @Test func whatCameIntoViewIsTheNewNamesInsideTheContainer() {
        let bounds = CGRect(x: 200, y: 0, width: 1240, height: 800)
        let before = HarnessScroll.visibleNames(fromNamedElements: [
            named("AXStaticText", "Intro", CGRect(x: 300, y: 700, width: 200, height: 20)),
            named("AXLink", "About", CGRect(x: 300, y: 100, width: 100, height: 20)),
            named("AXRow", "Downloads", CGRect(x: 10, y: 500, width: 180, height: 24))
        ], within: bounds)
        #expect(before.map(\.name) == ["Intro", "About"], "outside the container is not in view")
        let after = HarnessScroll.visibleNames(fromNamedElements: [
            named("AXLink", "About", CGRect(x: 300, y: 600, width: 100, height: 20)),
            named("AXHeading", "Experience", CGRect(x: 300, y: 400, width: 200, height: 24)),
            named("AXStaticText", "Skills", CGRect(x: 300, y: 100, width: 200, height: 20)),
            named("AXTextField", "secret", CGRect(x: 300, y: 300, width: 200, height: 20), subrole: "AXSecureTextField"),
            named("AXTextField", "what the owner typed", CGRect(x: 300, y: 250, width: 200, height: 20), source: "value")
        ], within: bounds)
        let change = HarnessScroll.change(before: before, after: after, direction: .down)
        #expect(change.moved)
        #expect(change.newlyVisible == ["Experience", "Skills"], "never a password box or a typed value")
        #expect(!HarnessScroll.change(before: before, after: before, direction: .down).moved)
        // Only a frame moved: it scrolled, and nothing new came into view.
        let shifted = before.map { (name: $0.name, frame: $0.frame.offsetBy(dx: 0, dy: 40)) }
        let nudged = HarnessScroll.change(before: before, after: shifted, direction: .down)
        #expect(nudged.moved && nudged.newlyVisible.isEmpty)
    }

    @Test func wheelStepsCoverMostOfAPage() {
        #expect(HarnessScroll.wheelSteps(pages: 1, extent: 800) == 16)
        #expect(HarnessScroll.wheelSteps(pages: 0.1, extent: 100) == 1)
        #expect(HarnessScroll.wheelSteps(pages: 10, extent: 4000) == HarnessScroll.maximumWheelSteps)
    }

    // MARK: The voice tools

    @Test func theHandsToolsParseTheirArguments() {
        let gemini: [String: Any] = ["toolCall": ["functionCalls": [
            ["id": "g1", "name": "scroll", "args": ["direction": "down", "amount": 2, "x": 0.5, "y": 0.25]],
            ["id": "g2", "name": "close", "args": ["what": "tab"]]
        ]]]
        let calls = RealtimeOpenAppTool.parseGemini(gemini)
        #expect(calls.first?.direction == "down" && calls.first?.amount == 2 && calls.first?.x == 0.5 && calls.first?.appName == nil)
        #expect(calls.last?.what == "tab" && calls.last?.appName == nil)
        let openAI: [String: Any] = [
            "type": "response.output_item.done",
            "item": ["type": "function_call", "call_id": "t1", "name": "type_text",
                     "arguments": #"{"app":"Cursor","text":"hello there","mode":"replace","name":"Search"}"#]
        ]
        let type = RealtimeOpenAppTool.parseOpenAI(openAI)
        #expect(type?.text == "hello there" && type?.mode == "replace" && type?.elementName == "Search" && type?.appName == "Cursor")
    }

    @Test func scrollAndTypeBecomeTheirHarnessLines() throws {
        let field = RealtimeScreenCandidate(name: "Search", role: "AXTextField", frame: CGRect(x: 100, y: 800, width: 300, height: 24),
                                            position: "top left")
        let onField = RealtimeScreenTarget(candidate: field, point: CGPoint(x: 250, y: 812), app: finder, source: .thisTurn)
        let atPoint = RealtimeScreenTarget(candidate: nil, point: CGPoint(x: 700, y: 400), app: nil, source: .screenshotPoint)
        func line(_ call: RealtimeToolCall, _ target: RealtimeScreenTarget? = nil) -> Result<String, RealtimeToolRefusal> {
            RealtimeOpenAppTool.harnessRequestLine(for: call, expectApp: finder, screenTarget: target)
        }
        let scroll = RealtimeToolCall(callID: "s", name: "scroll", appName: finder, direction: "down")
        let plain = object(try line(scroll).get())
        #expect(plain["verb"] as? String == "scroll" && plain["direction"] as? String == "down" && plain["amount"] as? Double == 1)
        #expect(plain["expectApp"] as? String == finder && plain["title"] == nil && plain["nearPoint"] == nil)
        let aimed = object(try line(scroll, onField).get())
        #expect(aimed["title"] as? String == "Search" && aimed["role"] as? String == "AXTextField")
        #expect((aimed["nearPoint"] as? [String: Double])?["y"] == 812)
        let pointed = object(try line(scroll, atPoint).get())
        #expect(pointed["title"] == nil && (pointed["nearPoint"] as? [String: Double])?["x"] == 700)
        #expect(error(line(RealtimeToolCall(callID: "s", name: "scroll", appName: finder, direction: "sideways"))) == "invalidDirection")

        let type = RealtimeToolCall(callID: "t", name: "type_text", appName: finder, text: "hello")
        let focused = object(try line(type).get())
        #expect(focused["verb"] as? String == "type" && focused["target"] as? String == "focused")
        #expect(focused["text"] as? String == "hello" && focused["mode"] as? String == "insert")
        #expect(focused["thenConfirm"] == nil, "never presses Enter")
        let intoField = object(try line(type, onField).get())
        #expect(intoField["title"] as? String == "Search" && intoField["requireAtPoint"] as? Bool == true && intoField["target"] == nil)
        #expect(error(line(RealtimeToolCall(callID: "t", name: "type_text", appName: finder))) == "missingText")
        #expect(error(line(RealtimeToolCall(callID: "t", name: "type_text", appName: finder, text: "x", mode: "overwrite"))) == "invalidMode")
        // A position with nothing nameable there: scrolled at the point, never typed into.
        #expect(error(line(type, atPoint)) == "nothingAtPoint")
    }

    private func menuItem(_ path: [String], shortcut: String? = nil, enabled: Bool = true, submenu: Bool = false) -> [String: Any] {
        ["path": path, "enabled": enabled, "shortcut": shortcut ?? NSNull(), "hasSubmenu": submenu]
    }

    @Test func closePicksTheAppsOwnMenuItem() {
        let chrome = [menuItem(["Google Chrome", "Quit Google Chrome"], shortcut: "⌘Q"), menuItem(["File", "Close Window"], shortcut: "⇧⌘W"),
                      menuItem(["File", "Close Tab"], shortcut: "⌘W")]
        #expect(RealtimeHandsVerbs.closeMenuPath(what: "tab", items: chrome) == ["File", "Close Tab"])
        #expect(RealtimeHandsVerbs.closeMenuPath(what: "window", items: chrome) == ["File", "Close Window"])
        #expect(RealtimeHandsVerbs.closeMenuPath(what: "app", items: chrome) == ["Google Chrome", "Quit Google Chrome"])
        // Cursor has no Close Tab: its ⌘W closes the editor tab.
        let cursor = [menuItem(["File", "Close Editor"], shortcut: "⌘W"), menuItem(["File", "Close Folder"]),
                      menuItem(["File", "Close Window"], shortcut: "⇧⌘W")]
        #expect(RealtimeHandsVerbs.closeMenuPath(what: "tab", items: cursor) == ["File", "Close Editor"])
        // TextEdit's "Close" closes the window; it is no tab.
        let textEdit = [menuItem(["File", "Close"], shortcut: "⌘W"), menuItem(["File", "Close All"], enabled: false)]
        #expect(RealtimeHandsVerbs.closeMenuPath(what: "window", items: textEdit) == ["File", "Close"])
        #expect(RealtimeHandsVerbs.closeMenuPath(what: "tab", items: textEdit) == nil)
        // Disabled items and submenu parents are never chosen; nonsense is nothing.
        #expect(RealtimeHandsVerbs.closeMenuPath(what: "tab", items: [menuItem(["File", "Close Tab"], enabled: false)]) == nil)
        #expect(RealtimeHandsVerbs.closeMenuPath(what: "window", items: [menuItem(["File", "Close Window"], submenu: true)]) == nil)
        #expect(RealtimeHandsVerbs.closeMenuPath(what: "everything", items: chrome) == nil)
    }

    /// A fake harness: the menu listing, then the press of whatever path it is sent.
    private final class CloseHarness: @unchecked Sendable {
        let lock = NSLock()
        var lines: [[String: Any]] = []
        let quitAsks: Bool
        init(quitAsks: Bool = false) { self.quitAsks = quitAsks }

        func answer(_ line: String) -> String {
            let request = (try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]) ?? [:]
            lock.lock(); lines.append(request); lock.unlock()
            var response: [String: Any]
            switch request["verb"] as? String {
            case "menus":
                response = ["ok": true, "bundleIdentifier": "com.apple.finder", "items": [
                    ["path": ["Finder", "Quit Finder"], "enabled": true, "shortcut": "⌘Q", "hasSubmenu": false],
                    ["path": ["File", "Close Window"], "enabled": true, "shortcut": "⌘W", "hasSubmenu": false],
                    ["path": ["File", "Close Tab"], "enabled": true, "shortcut": NSNull(), "hasSubmenu": false]
                ]]
            case "menu" where quitAsks && request["ticket"] == nil:
                response = ["ok": false, "error": "confirmationRequired", "ticket": "T1", "bundleIdentifier": "com.apple.finder"]
            default:
                response = ["ok": true, "bundleIdentifier": "com.apple.finder", "performed": ["status": "sent"],
                            "verification": ["status": "confirmed"]]
            }
            let data = (try? JSONSerialization.data(withJSONObject: response)) ?? Data()
            return String(decoding: data, as: UTF8.self)
        }
    }

    @Test func aCloseReadsTheMenusThenPressesTheItemItFound() async {
        let harness = CloseHarness()
        let tab = RealtimeToolCall(callID: "c", name: "close", appName: "Finder", what: "tab")
        let closed = await RealtimeOpenAppTool.dispatch(tab, answer: { harness.answer($0) })
        #expect(closed.result["ok"] as? Bool == true)
        #expect(closed.result["closed"] as? String == "File \u{203A} Close Tab")
        #expect(harness.lines.map { $0["verb"] as? String } == ["menus", "menu"])
        #expect(harness.lines.last?["path"] as? [String] == ["File", "Close Tab"])
        #expect(harness.lines.last?["expectApp"] as? String == finder)
        #expect(closed.harnessResponse?["items"] == nil, "the listing never reaches the trace")
    }

    /// Quitting goes through the kernel ("quit" asks, on a card), and is proved
    /// by the app no longer running — Finder here never stops, so it says so.
    @Test func aQuitWaitsForTheCardAndIsProvedByTheAppStopping() async {
        let harness = CloseHarness(quitAsks: true)
        let quit = RealtimeToolCall(callID: "c", name: "close", appName: "Finder", what: "app")
        let answered = await RealtimeOpenAppTool.dispatch(quit, answer: { harness.answer($0) }, pollMilliseconds: 10)
        #expect(answered.waitedForConfirmation)
        #expect(harness.lines.last?["ticket"] as? String == "T1")
        #expect(harness.lines.last?["path"] as? [String] == ["Finder", "Quit Finder"])
        #expect(answered.result["ok"] as? Bool == false)
        #expect(answered.result["error"] as? String == "appStillRunning")
    }

    @Test func handsReceiptsCaptionsAndTheTrace() {
        func claimed(_ said: String, _ ok: Set<String>) -> Bool { RealtimeOpenAppTool.claimedWithoutReceipt(transcript: said, okToolNames: ok) }
        #expect(claimed("I scrolled down, sir.", []))
        #expect(!claimed("I scrolled down, sir.", ["scroll"]))
        #expect(claimed("Typed it in.", ["press_element"]))
        #expect(!claimed("Typed it in.", ["type_text"]))
        #expect(claimed("Closed the tab.", []))
        #expect(!claimed("Closed the tab.", ["close"]))
        #expect(RealtimeVoiceVerbs.intentTitle(for: RealtimeToolCall(callID: "c", name: "scroll", appName: nil, direction: "down")) == "Scrolling down\u{2026}")
        #expect(RealtimeVoiceVerbs.intentTitle(for: RealtimeToolCall(callID: "c", name: "type_text", appName: nil, text: "x")) == "Typing\u{2026}")
        #expect(RealtimeVoiceVerbs.intentTitle(for: RealtimeToolCall(callID: "c", name: "close", appName: nil, what: "tab")) == "Closing the tab\u{2026}")
        #expect(RealtimeVoiceVerbs.intentTitle(for: RealtimeToolCall(callID: "c", name: "close", appName: "Chrome", what: "app")) == "Quitting Chrome\u{2026}")
        // The owner's words are never in the counts-only trace.
        let logged = RealtimeDecisionTrace.loggedArguments(for: RealtimeToolCall(callID: "c", name: "type_text", appName: nil, text: "my secret plan"))
        #expect(logged["textLength"] as? Int == 14 && logged["text"] == nil)
        #expect(RealtimeVoiceVerbs.allToolNames.isSuperset(of: ["scroll", "type_text", "close"]))
        for code in ["appStillRunning", "noCloseItem", "missingText", "nothingAtPoint"] { #expect(JarvisNotchReason.byErrorCode[code] != nil, "\(code)") }
    }

    @Test func theModelIsToldItsHands() {
        let prompt = RealtimeOpenAppTool.systemPrompt
        #expect(!prompt.contains("say you can't yet"))
        for word in ["scroll", "type_text", "close", "never presses enter"] { #expect(prompt.lowercased().contains(word), "\(word)") }
        let declarations = RealtimeVoiceVerbs.openAIDeclarations
        func declaration(_ name: String) -> [String: Any]? { declarations.first { $0["name"] as? String == name } }
        let scroll = declaration("scroll")?["parameters"] as? [String: Any]
        #expect(scroll?["required"] as? [String] == ["direction"])
        #expect(((scroll?["properties"] as? [String: Any])?["direction"] as? [String: Any])?["enum"] as? [String] == ["up", "down", "left", "right"])
        #expect((declaration("type_text")?["parameters"] as? [String: Any])?["required"] as? [String] == ["text"])
        #expect((declaration("close")?["parameters"] as? [String: Any])?["required"] as? [String] == ["what"])
        let gemini = (RealtimeVoiceVerbs.geminiDeclaration["functionDeclarations"] as? [[String: Any]])?.first { $0["name"] as? String == "close" }
        let what = ((gemini?["parameters"] as? [String: Any])?["properties"] as? [String: Any])?["what"] as? [String: Any]
        #expect(what?["type"] as? String == "STRING" && what?["enum"] as? [String] == ["tab", "window", "app"])
    }
}
