//
//  UniversalHandsWiringTests.swift
//  leanring-buddyTests
//
//  Slice B of universal screen hands (owner's ruling 2026-10-31): the voice tools and
//  the agent loop's computer actions wired onto the harness's `pointer` / `key` /
//  `look` tier `screen`. Pure parts only — coordinate mapping (a non-zero display
//  origin included), member -> voice call -> harness request, the toolset echo, the
//  toolset declaration and its configs, and the guards on the requests the members
//  make. That a click lands is the live checks' (`--agent-loop-probe`), not this file's.
//

import CoreGraphics
import Foundation
import Testing
@testable import Clicky

/// What a fake harness or model saw, shared with its @Sendable closure.
private final class Seen: @unchecked Sendable {
    var lines: [String] = []
    var calls: [RealtimeToolCall] = []
    var bodies: [[String: Any]] = []
    var replies = 0
}

struct UniversalHandsWiringTests {

    private func object(_ line: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]) ?? [:]
    }

    private func call(_ mapped: AgentComputer.Mapped) -> (RealtimeToolCall, Int)? {
        if case .call(let call, let repeats) = mapped { return (call, repeats) }
        return nil
    }

    private func refusal(_ mapped: AgentComputer.Mapped) -> String? {
        if case .refused(let error, _) = mapped { return error }
        return nil
    }

    // MARK: Coordinates

    /// A second display LEFT of and above the primary: image pixel (px, py) is AppKit (x + px*w/W, y + h - py*h/H).
    @Test func pixelsMapOntoAppKitWithANonZeroDisplayOrigin() throws {
        let region = CGRect(x: -1440, y: 200, width: 1440, height: 900)
        let pixels = CGSize(width: 1440, height: 900)
        #expect(AgentComputer.appKitPoint(pixel: CGPoint(x: 0, y: 0), region: region, imagePixels: pixels) == CGPoint(x: -1440, y: 1100))
        #expect(AgentComputer.appKitPoint(pixel: CGPoint(x: 1440, y: 900), region: region, imagePixels: pixels) == CGPoint(x: 0, y: 200))
        #expect(AgentComputer.appKitPoint(pixel: CGPoint(x: 720, y: 450), region: region, imagePixels: pixels) == CGPoint(x: -720, y: 650))
        // A downscaled picture of a big display: half the pixels, twice the points each.
        let big = CGRect(x: 0, y: 0, width: 2880, height: 1800)
        #expect(AgentComputer.appKitPoint(pixel: CGPoint(x: 960, y: 600), region: big, imagePixels: CGSize(width: 1920, height: 1200))
                == CGPoint(x: 1440, y: 900))
        // Off the image: nothing, never a clamp.
        #expect(AgentComputer.appKitPoint(pixel: CGPoint(x: 1441, y: 10), region: region, imagePixels: pixels) == nil)
        #expect(AgentComputer.appKitPoint(pixel: CGPoint(x: -1, y: 10), region: region, imagePixels: pixels) == nil)
        // The voice path's own conversion agrees: the call carries fractions of the same region.
        let fraction = try #require(AgentComputer.fraction(pixel: CGPoint(x: 720, y: 450), imagePixels: pixels))
        #expect(RealtimeScreenVerbs.screenshotPoint(x: fraction.x, y: fraction.y, display: region) == CGPoint(x: -720, y: 650))
        // cursor_position: the way back, and off the display is nil.
        #expect(AgentComputer.pixel(appKit: CGPoint(x: -720, y: 650), region: region, imagePixels: pixels) == CGPoint(x: 720, y: 450))
        #expect(AgentComputer.pixel(appKit: CGPoint(x: 10, y: 650), region: region, imagePixels: pixels) == nil)
        #expect(AgentComputer.cursorText(mouse: CGPoint(x: -720, y: 650), region: region, imagePixels: pixels) == "X=720, Y=450")
        // zoom's [x0, y0, x1, y1] covers the AppKit rectangle between those corners.
        #expect(AgentComputer.appKitRect(pixelRegion: [100, 50, 300, 150], region: region, imagePixels: pixels)
                == CGRect(x: -1340, y: 950, width: 200, height: 100))
        #expect(AgentComputer.appKitRect(pixelRegion: [300, 50, 100, 150], region: region, imagePixels: pixels) == nil)
    }

    /// The computer `zoom`: `look` tier `screen` with a region, on that verb and tier alone, a real rectangle only.
    @Test func aZoomRegionDecodesOnlyOnTheScreenLook() throws {
        guard case .success(let zoom) = HarnessPolicy.decode(line: #"{"verb":"look","tier":"screen","region":{"x":-100,"y":20,"w":300,"h":150}}"#) else {
            Issue.record("a zoom was refused"); return
        }
        #expect(zoom.lookRegion == CGRect(x: -100, y: 20, width: 300, height: 150))
        for line in [#"{"verb":"look","tier":"window","region":{"x":0,"y":0,"w":10,"h":10}}"#,
                     #"{"verb":"pointer","action":"click","nearPoint":{"x":1,"y":1},"region":{"x":0,"y":0,"w":10,"h":10}}"#,
                     #"{"verb":"look","tier":"screen","region":{"x":0,"y":0,"w":0,"h":10}}"#] {
            guard case .failure(let error) = HarnessPolicy.decode(line: line) else { Issue.record("decoded: \(line)"); continue }
            #expect(error.code == "invalidField")
        }
        #expect(AgentLoop.screenLookRequestLine(expectApp: nil, region: CGRect(x: 1, y: 2, width: 3, height: 4)).map(object)?["region"]
                as? [String: Double] == ["x": 1, "y": 2, "w": 3, "h": 4])
    }

    // MARK: Members -> voice calls

    @Test func everyActingMemberBecomesAVoiceToolCallAimedAtFractions() throws {
        let region = CGRect(x: 0, y: 0, width: 1000, height: 500)
        let pixels = CGSize(width: 1000, height: 500)
        func mapped(_ name: String, _ input: [String: Any], mouse: CGPoint? = nil) -> AgentComputer.Mapped {
            AgentComputer.mapped(name: name, input: input, id: "t", region: region, imagePixels: pixels, mouse: mouse)
        }
        let click = try #require(call(mapped("left_click", ["coordinate": [100, 50]])))
        #expect(click.0.name == "press_element" && click.0.pointerAction == "click" && click.0.x == 0.1 && click.0.y == 0.1)
        #expect(call(mapped("double_click", ["coordinate": [100, 50]]))?.0.pointerAction == "doubleClick")
        #expect(call(mapped("right_click", ["coordinate": [100, 50]]))?.0.pointerAction == "rightClick")
        // No coordinate: where the pointer is now.
        let here = try #require(call(mapped("left_click", [:], mouse: CGPoint(x: 500, y: 400))))
        #expect(here.0.x == 0.5 && here.0.y == 0.2)
        #expect(refusal(mapped("left_click", [:], mouse: nil)) == "missingCoordinate")
        // Held modifiers are not something the pointer does: refused, never clicked plain.
        #expect(refusal(mapped("left_click", ["coordinate": [100, 50], "text": "cmd"])) == "modifiersUnsupported")
        #expect(refusal(mapped("left_click", ["coordinate": [1001, 50]])) == "coordinateOutOfRange")
        let drag = try #require(call(mapped("left_click_drag", ["start_coordinate": [100, 50], "coordinate": [900, 450]])))
        #expect(drag.0.name == "drag_item" && drag.0.pointerAction == "drag" && drag.0.x == 0.1 && drag.0.toX == 0.9 && drag.0.toY == 0.9)
        #expect(refusal(mapped("left_click_drag", ["coordinate": [900, 450]])) == "missingCoordinate")
        let hover = try #require(call(mapped("mouse_move", ["coordinate": [500, 250]])))
        #expect(hover.0.name == "point_at" && hover.0.pointerAction == "move")
        // A wheel at a point is the pointer's; with none, the window's own scroll.
        let wheel = try #require(call(mapped("scroll", ["coordinate": [500, 250], "scroll_direction": "down", "scroll_amount": 5])))
        #expect(wheel.0.name == "scroll" && wheel.0.pointerAction == "scroll" && wheel.0.direction == "down" && wheel.0.amount == 1)
        let plain = try #require(call(mapped("scroll", ["scroll_direction": "up", "scroll_amount": 10])))
        #expect(plain.0.pointerAction == nil && plain.0.amount == 2 && plain.0.x == nil)
        #expect(refusal(mapped("scroll", ["scroll_direction": "sideways"])) == "invalidDirection")
        let key = try #require(call(mapped("key", ["text": "ctrl+s", "repeat": 40])))
        #expect(key.0.name == "press_keys" && key.0.shortcut == "ctrl+s" && key.1 == AgentComputer.maximumKeyRepeat)
        let typed = try #require(call(mapped("type", ["text": "hello"])))
        #expect(typed.0.name == "type_text" && typed.0.text == "hello" && typed.0.x == nil)
        #expect(mapped("screenshot", [:]) == .screenshot)
        #expect(mapped("cursor_position", [:]) == .cursorPosition)
        #expect(mapped("wait", ["duration": 120]) == .wait(seconds: AgentComputer.maximumWaitSeconds))
        #expect(mapped("zoom", ["region": [0, 0, 500, 250]]) == .zoom(CGRect(x: 0, y: 250, width: 500, height: 250)))
        #expect(refusal(mapped("triple_click", ["coordinate": [1, 1]])) == "unsupportedAction")
        // No screenshot this step: a coordinate names nothing.
        #expect(refusal(AgentComputer.mapped(name: "left_click", input: ["coordinate": [1, 1]], id: "t", region: nil, imagePixels: nil,
                                             mouse: nil)) == "noScreenshot")
    }

    /// X11 key names (the model's) to the harness's: alt is opt, super is cmd, Delete deletes forward.
    @Test func keyNamesTranslateToTheHarnesses() {
        #expect(AgentComputer.harnessKeys("Return") == "return")
        #expect(AgentComputer.harnessKeys("ctrl+s") == "ctrl+s")
        #expect(AgentComputer.harnessKeys("alt+Tab") == "opt+tab")
        #expect(AgentComputer.harnessKeys("super+c") == "cmd+c")
        #expect(AgentComputer.harnessKeys("cmd+shift+n") == "cmd+shift+n")
        #expect(AgentComputer.harnessKeys("Page_Down") == "pagedown")
        #expect(AgentComputer.harnessKeys("Delete") == "forwarddelete")
        #expect(AgentComputer.harnessKeys("BackSpace") == "delete")
        #expect(AgentComputer.harnessKeys("Escape") == "escape")
        #expect(AgentComputer.harnessKeys("hyper+x") == nil)
        #expect(AgentComputer.harnessKeys("ctrl+") == nil)
    }

    // MARK: Voice calls -> harness requests

    @Test func pointerCallsBecomePointerRequestsAndANamedFrontAppPressStaysAX() throws {
        let point = CGPoint(x: 120.4, y: 880.6)
        let bare = RealtimeScreenTarget(candidate: nil, point: point, app: nil, source: .vision)
        var click = RealtimeToolCall(callID: "a", name: "press_element", appName: "com.apple.finder", x: 0.1, y: 0.02)
        click.pointerAction = "click"
        let clicked = object(try RealtimeOpenAppTool.harnessRequestLine(for: click, expectApp: "com.apple.finder", screenTarget: bare).get())
        #expect(clicked["verb"] as? String == "pointer" && clicked["action"] as? String == "click")
        #expect((clicked["nearPoint"] as? [String: Double]) == ["x": 120, "y": 881])
        #expect(clicked["expectApp"] == nil && clicked["label"] == nil)
        // The voice's press with nothing AX names at the point: the pointer, labelled with the model's words.
        let voice = RealtimeToolCall(callID: "b", name: "press_element", appName: "com.apple.finder", elementName: "Battery", x: 0.9, y: 0.01)
        let pressed = object(try RealtimeOpenAppTool.harnessRequestLine(for: voice, expectApp: "com.apple.finder", screenTarget: bare).get())
        #expect(pressed["verb"] as? String == "pointer" && pressed["label"] as? String == "Battery")
        // A Dock icon (another process) found at a position, or by its name on the Dock: the pointer at its centre.
        let safari = RealtimeScreenCandidate(name: "Safari", role: "AXDockItem", frame: CGRect(x: 600, y: 0, width: 50, height: 50), position: "in the Dock")
        for (app, source) in [("com.apple.dock", RealtimeOpenAppTool.OfferSource.screenshotPoint), (nil, .systemUI)] as [(String?, RealtimeOpenAppTool.OfferSource)] {
            let target = RealtimeScreenTarget(candidate: safari, point: CGPoint(x: 625, y: 25), app: app, source: source)
            let dock = object(try RealtimeOpenAppTool.harnessRequestLine(for: voice, expectApp: "com.apple.finder", screenTarget: target).get())
            #expect(dock["verb"] as? String == "pointer" && (dock["nearPoint"] as? [String: Double]) == ["x": 625, "y": 25])
        }
        // ...but another app's element from a find's OFFER is still refused: an old list never aims the pointer.
        let offered = RealtimeScreenTarget(candidate: safari, point: CGPoint(x: 625, y: 25), app: "com.apple.dock", source: .thisTurn)
        if case .failure(let refused) = RealtimeOpenAppTool.harnessRequestLine(for: voice, expectApp: "com.apple.finder", screenTarget: offered) {
            #expect(refused.error == "notOffered")
        } else { Issue.record("an offer from another app aimed the pointer") }
        // AX first: a pressable element of the app in front, at a position, is pressed by its name.
        let button = RealtimeScreenCandidate(name: "Share", role: "AXButton", frame: CGRect(x: 100, y: 800, width: 40, height: 20), position: "top")
        let named = RealtimeScreenTarget(candidate: button, point: CGPoint(x: 120, y: 810), app: "com.apple.finder", source: .screenshotPoint)
        #expect(object(try RealtimeOpenAppTool.harnessRequestLine(for: voice, expectApp: "com.apple.finder", screenTarget: named).get())["verb"]
                as? String == "click")
        // ...unless the owner asked for a right- or double-click: the pointer, at the element's centre.
        var right = voice
        right.pointerAction = "rightClick"
        let menu = object(try RealtimeOpenAppTool.harnessRequestLine(for: right, expectApp: "com.apple.finder", screenTarget: named).get())
        #expect(menu["verb"] as? String == "pointer" && menu["action"] as? String == "rightClick")
        // Opening never goes by pointer: AXOpen on a named item, else nothing.
        var open = voice
        open.open = true
        if case .failure(let refused) = RealtimeOpenAppTool.harnessRequestLine(for: open, expectApp: "com.apple.finder", screenTarget: bare) {
            #expect(refused.error == "nothingToOpen")
        } else { Issue.record("an open went by pointer") }
    }

    @Test func dragKeysWheelAndHoverRequests() throws {
        var drag = RealtimeToolCall(callID: "d", name: "drag_item", appName: "com.apple.finder", elementName: "drag-me.txt")
        drag.pointerAction = "drag"
        let from = RealtimeScreenTarget(candidate: nil, point: CGPoint(x: 100, y: 100), app: nil, source: .vision)
        let to = RealtimeScreenTarget(candidate: nil, point: CGPoint(x: 300, y: 200), app: nil, source: .vision)
        let dragged = object(try RealtimeOpenAppTool.harnessRequestLine(for: drag, expectApp: "com.apple.finder", screenTarget: from, dropTarget: to).get())
        #expect(dragged["verb"] as? String == "pointer" && dragged["action"] as? String == "drag")
        #expect((dragged["to"] as? [String: Double]) == ["x": 300, "y": 200] && dragged["label"] as? String == "drag-me.txt")
        if case .failure(let refused) = RealtimeOpenAppTool.harnessRequestLine(for: drag, screenTarget: from) {
            #expect(refused.error == "missingDropTarget")
        } else { Issue.record("a drag with no drop end") }
        // The drop end resolves as its own call: its name or position, never the start's.
        var named = drag
        (named.toName, named.toX, named.toY) = ("Drop Here", 0.5, 0.6)
        let drop = RealtimeOpenAppTool.dropCall(named)
        #expect(drop.elementName == "Drop Here" && drop.x == 0.5 && drop.y == 0.6 && drop.toName == nil && drop.pointerAction == "drag")

        let keys = RealtimeToolCall(callID: "k", name: "press_keys", appName: "TextEdit", shortcut: "cmd+shift+n")
        let pressed = object(try RealtimeOpenAppTool.harnessRequestLine(for: keys, expectApp: "com.apple.TextEdit").get())
        #expect(pressed["verb"] as? String == "key" && pressed["keys"] as? String == "cmd+shift+n" && pressed["expectApp"] as? String == "com.apple.TextEdit")
        let bad = RealtimeToolCall(callID: "k2", name: "press_keys", appName: "TextEdit", shortcut: "cmd+banana")
        if case .failure(let refused) = RealtimeOpenAppTool.harnessRequestLine(for: bad) { #expect(refused.error == "invalidKeys") }
        else { Issue.record("an unknown key was sent") }
        // The voice parses press_keys' `keys` and press_element's flags.
        #expect(RealtimeToolCall.parsed(callID: "p", name: "press_keys", arguments: ["keys": "escape"]).shortcut == "escape")
        #expect(RealtimeToolCall.parsed(callID: "p", name: "press_element", arguments: ["x": 0.5, "y": 0.5, "right": true]).pointerAction == "rightClick")
        #expect(RealtimeToolCall.parsed(callID: "p", name: "press_element", arguments: ["x": 0.5, "y": 0.5]).pointerAction == nil)
        let parsedDrag = RealtimeToolCall.parsed(callID: "p", name: "drag_item", arguments: ["name": "a.txt", "to_name": "Folder"])
        #expect(parsedDrag.pointerAction == "drag" && parsedDrag.toName == "Folder")

        var wheel = RealtimeToolCall(callID: "w", name: "scroll", appName: "Safari", direction: "down", amount: 0.6)
        wheel.pointerAction = "scroll"
        let wheeled = object(try RealtimeOpenAppTool.harnessRequestLine(for: wheel, screenTarget: from).get())
        #expect(wheeled["verb"] as? String == "pointer" && wheeled["action"] as? String == "scroll" && wheeled["direction"] as? String == "down")
        #expect(wheeled["amount"] as? Double == 0.6)
        var hover = RealtimeToolCall(callID: "h", name: "point_at", appName: "Safari")
        hover.pointerAction = "move"
        #expect(object(try RealtimeOpenAppTool.harnessRequestLine(for: hover, screenTarget: from).get())["action"] as? String == "move")
    }

    /// A position with the pointer asked for is the point itself: no hit test runs.
    @Test func anAskedForPointerAimsAtThePointWithoutAHitTest() async throws {
        var click = RealtimeToolCall(callID: "a", name: "press_element", appName: "com.apple.finder", x: 0.5, y: 0.5)
        click.pointerAction = "click"
        let target = try await RealtimeOpenAppTool.resolveScreenTarget(
            call: click, thisTurn: nil, previousTurn: nil, followUpConfirmed: nil, confirmedByYes: false, now: 0,
            screenshotDisplay: CGRect(x: 0, y: 0, width: 1440, height: 900), keyDownPointer: nil,
            hitTest: { _ in Issue.record("hit-tested"); return .nothing }).get()
        #expect(target.candidate == nil && target.point == CGPoint(x: 720, y: 450))
    }

    // MARK: What the harness says back

    @Test func aPointerOkIsPostedAndStandsOnlyWhenSomethingChanged() {
        let target: [String: Any] = ["source": "unnamed", "name": NSNull(), "role": NSNull(), "app": "Control Centre", "surface": "menuBar"]
        var response: [String: Any] = ["ok": true, "action": "click", "target": target,
                                       "verification": ["status": "changed", "evidence": "1 window(s) appeared"]]
        let changed = RealtimeOpenAppTool.pointerResult(RealtimeOpenAppTool.toolResult(fromHarnessResponse: response), response: response)
        #expect(changed["ok"] as? Bool == true && changed["verification"] as? String == "confirmed")
        #expect((changed["target"] as? String)?.contains("menu bar") == true && changed["evidence"] as? String == "1 window(s) appeared")
        response["verification"] = ["status": "noChangeSeen", "evidence": "nothing"]
        let unseen = RealtimeOpenAppTool.pointerResult(RealtimeOpenAppTool.toolResult(fromHarnessResponse: response), response: response)
        #expect(unseen["ok"] as? Bool == false && unseen["error"] as? String == "notVerified" && unseen["verification"] as? String == "notObserved")
        // A hover changes nothing by design: posted is its whole receipt.
        response["action"] = "move"
        #expect(RealtimeOpenAppTool.pointerResult(RealtimeOpenAppTool.toolResult(fromHarnessResponse: response), response: response)["ok"] as? Bool == true)
        // A named target is said by its role and quoted name.
        let named = RealtimeOpenAppTool.pointerTargetDescription(["name": "Safari", "role": "AXDockItem", "app": "Dock", "surface": "dock"])
        #expect(named.contains("\"Safari\"") && named.hasSuffix("in the Dock"))
    }

    // MARK: The toolset on the wire

    @MainActor @Test func aComputerResultEchoesItsToolsetAndCarriesItsImageAfterTheText() throws {
        let plain = AgentLoop.toolResultBlock(id: "t1", result: ["ok": true])
        #expect(plain["toolset_name"] == nil)
        let member = AgentLoop.toolResultBlock(id: "t2", result: ["ok": false, "error": "notVerified"], toolset: "computer")
        #expect(member["toolset_name"] as? String == "computer" && member["is_error"] as? Bool == true && member["content"] is String)
        let shot = AgentLoop.toolResultBlock(id: "t3", result: ["ok": true], toolset: "computer", image: Data([0xFF, 0xD8]))
        let content = try #require(shot["content"] as? [[String: Any]])
        #expect(content.map { $0["type"] as? String } == ["text", "image"])
        // Only the latest user message keeps a picture, inside a tool result too.
        let messages: [[String: Any]] = [["role": "user", "content": [shot]], ["role": "assistant", "content": [["type": "text", "text": "ok"]]],
                                         ["role": "user", "content": [["type": "text", "text": "Step 2."]]]]
        let kept = AgentLoop.keepingLatestImage(messages)
        let old = try #require(((kept[0]["content"] as? [[String: Any]])?.first)?["content"] as? [[String: Any]])
        #expect(old.map { $0["type"] as? String } == ["text", "text"])
        #expect((kept[0]["content"] as? [[String: Any]])?.first?["toolset_name"] as? String == "computer")
    }

    @MainActor @Test func claudeIsDeclaredTheToolsetWithItsUnsupportedMembersOff() throws {
        let tools = try #require(AgentLoop.requestBody(messages: [], provider: .claude)["tools"] as? [[String: Any]])
        let toolset = try #require(tools.first { $0["type"] as? String == AgentComputer.toolsetType })
        #expect(toolset["name"] == nil)
        let configs = try #require(toolset["configs"] as? [String: [String: Bool]])
        #expect(Set(configs.keys) == ["middle_click", "triple_click", "left_mouse_down", "left_mouse_up", "hold_key"])
        #expect(configs.values.allSatisfy { $0["enabled"] == false })
        let system = (AgentLoop.requestBody(messages: [], provider: .claude)["system"] as? [[String: Any]])?.first?["text"] as? String ?? ""
        #expect(system.contains("Computer actions"))
        // Gemini and OpenAI cannot take it; the wrap-up turn only reports.
        for provider in [AgentModelProvider.gemini, .openai] {
            let other = AgentLoop.requestBody(messages: [], provider: provider)["tools"] as? [[String: Any]] ?? []
            #expect(!other.contains { $0["type"] as? String == AgentComputer.toolsetType })
        }
        #expect(!(AgentLoop.requestBody(messages: [], provider: .claude, wrapUp: true)["tools"] as? [[String: Any]] ?? [])
            .contains { $0["type"] as? String == AgentComputer.toolsetType })
        // The 4.6 fallback takes only the beta tool: the toolset is stripped there.
        let fallback = AgentLoopModel.completed(AgentLoop.requestBody(messages: [], provider: .claude), model: AgentLoopModel.fallback)
        #expect(!(fallback["tools"] as? [[String: Any]] ?? []).contains { $0["type"] as? String == AgentComputer.toolsetType })
    }

    /// The instruction before the picture, and the picture's size in it.
    @MainActor @Test func theStepTextComesBeforeTheWholeScreen() {
        var observation = AgentObservation()
        observation.jpeg = Data([0xFF])
        observation.imagePixels = CGSize(width: 1440, height: 900)
        observation.look = "attached"
        let blocks = AgentLoop.observationBlocks(observation, step: 3)
        #expect(blocks.map { $0["type"] as? String } == ["text", "image"])
        let text = blocks.first?["text"] as? String ?? ""
        #expect(text.contains("whole screen") && text.contains("1440 by 900 pixels"))
    }

    // MARK: Guards on what the members send

    /// Read-only (the owner's words): a hover and a wheel look; a click, drag or right-click at a point is refused,
    /// and only keys that move through what is shown pass.
    @Test func aReadOnlyTaskRefusesAPointerPressAndAShortcut() throws {
        func refused(_ request: [String: Any]) -> Bool { AgentLoop.readOnlyRefusal(request, focusedField: { nil }) != nil }
        var click = RealtimeToolCall(callID: "a", name: "press_element", appName: "com.apple.finder", x: 0.5, y: 0.5)
        click.pointerAction = "click"
        let point = RealtimeScreenTarget(candidate: nil, point: CGPoint(x: 10, y: 10), app: nil, source: .vision)
        let line = try RealtimeOpenAppTool.harnessRequestLine(for: click, screenTarget: point).get()
        #expect(refused(object(line)))
        // Through the live wrapper the harness never hears it.
        let seen = Seen()
        let guarded = AgentLoop.readOnlyGuardedAnswer({ seen.lines.append($0); return "{\"ok\":true}" }, readFocusedField: { nil })
        #expect(object(guarded(line))["error"] as? String == "readOnlyTask" && seen.lines.isEmpty)
        for action in ["doubleClick", "rightClick", "drag"] { #expect(refused(["verb": "pointer", "action": action])) }
        for action in ["move", "scroll"] { #expect(!refused(["verb": "pointer", "action": action])) }
        for keys in ["escape", "down", "pagedown", "tab"] { #expect(!refused(["verb": "key", "keys": keys]), "\(keys)") }
        for keys in ["cmd+s", "return", "space", "cmd+down", "x"] { #expect(refused(["verb": "key", "keys": keys]), "\(keys)") }
    }

    /// A draft task's flag and an unnamed app's flag ride on a pointer request like any other acting verb's.
    @Test func theDraftAndUnnamedAppFlagsReachAPointerRequest() {
        let line = "{\"action\":\"click\",\"nearPoint\":{\"x\":1,\"y\":2},\"verb\":\"pointer\"}"
        let seen = Seen()
        _ = AgentLoop.draftGuardedAnswer({ seen.lines.append($0); return "{}" })(line)
        #expect(object(seen.lines.last ?? "")["draftScope"] as? Bool == true)
        _ = RealtimeVoiceConnection.unnamedAppAnswer({ seen.lines.append($0); return "{}" })(line)
        #expect(object(seen.lines.last ?? "")["unnamedApp"] as? Bool == true)
        #expect(HarnessVerb.pointer.isMutating && HarnessVerb.gatedForUnnamedApp.contains(.pointer) && HarnessVerb.gatedForUnnamedApp.contains(.key))
    }

    /// The task's own Control Centre panel: a pointer press that brought it forward makes it the task's, as
    /// press_menu_bar_item's does, so closing it again asks no unnamed-app card.
    @Test func aPanelAPointerPressOpenedIsTheTasks() {
        let response: [String: Any] = ["ok": true, "evidence": ["frontmostAfter": "com.apple.controlcenter"]]
        let bundle = AgentLoop.openedBundle(by: "press_element", confirmed: true, response: response)
        #expect(bundle == "com.apple.controlcenter")
        #expect(AgentLoop.ownership(afterOpening: "press_element", bundle: "com.apple.controlcenter", runningAtStart: ["com.apple.controlcenter"]) == .app)
        #expect(AgentLoop.openedBundle(by: "press_element", confirmed: false, response: response) == nil)
        #expect(AgentLoop.openedBundle(by: "press_element", confirmed: true, response: ["evidence": ["frontmostAfter": "com.apple.Safari"]]) == nil)
    }

    // MARK: The loop

    /// A computer action runs as its voice tool through `execute`, its result echoes the toolset, a failure stops the
    /// rest of the batch with the API's halt text, and the receipt is the voice tool's.
    @MainActor @Test func aMemberRunsThroughExecuteAndAFailureHaltsTheBatch() async throws {
        let seen = Seen()
        let replies: [[String: Any]] = [
            ["stop_reason": "tool_use", "content": [
                ["type": "tool_use", "id": "c1", "name": "left_click", "toolset_name": "computer", "input": ["coordinate": [720, 10]]],
                ["type": "tool_use", "id": "c2", "name": "left_click", "toolset_name": "computer", "input": ["coordinate": [10, 10]]]]],
            ["stop_reason": "tool_use", "content": [["type": "tool_use", "id": "d", "name": "done",
                                                     "input": ["summary": "The click did not work.", "evidence": [1]]]]]
        ]
        let loop = AgentLoop(dependencies: AgentLoop.Dependencies(
            model: { body, _ in
                seen.bodies.append(body)
                defer { seen.replies += 1 }
                return AgentModelReply(json: replies[min(seen.replies, replies.count - 1)], model: "fake", milliseconds: 1)
            },
            observe: { AgentObservation(jpeg: Data([0xFF]), frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                        imagePixels: CGSize(width: 1440, height: 900), look: "attached") },
            execute: { call, _, _, _ in
                seen.calls.append(call)
                return RealtimeToolDispatch(result: ["ok": false, "error": "notVerified", "message": "nothing changed"], harnessMilliseconds: 1,
                                            waitedForConfirmation: false, harnessResponse: nil)
            },
            readPage: { ["ok": true, "text": ""] },
            trace: { _ in }
        ))
        _ = await loop.run(goal: "click the battery icon")
        #expect(seen.calls.count == 1)
        #expect(seen.calls.first?.name == "press_element" && seen.calls.first?.pointerAction == "click" && seen.calls.first?.x == 0.5)
        let second = try #require(seen.bodies.dropFirst().first?["messages"] as? [[String: Any]])
        let results = try #require(second.last?["content"] as? [[String: Any]]).filter { $0["type"] as? String == "tool_result" }
        #expect(results.count == 2 && results.allSatisfy { $0["toolset_name"] as? String == "computer" })
        #expect(results.last?["content"] as? String == AgentComputer.notExecutedText)
        #expect(loop.receipts.first?.toolName == "press_element" && loop.receipts.first?.ok == false)
    }

    // MARK: Voice surfaces

    @Test func findOnScreenInTheDockReadsTheDock() {
        #expect(SystemUITargets.namesSurface("Dock") && SystemUITargets.namesSurface("menu bar") && SystemUITargets.namesSurface("Control Centre"))
        #expect(!SystemUITargets.namesSurface("Finder") && !SystemUITargets.namesSurface("Docker"))
        let screens = [CGRect(x: 0, y: 0, width: 1440, height: 900)]
        let visible = [SystemUITargets.target(name: "Safari", role: "AXDockItem", frame: CGRect(x: 600, y: 0, width: 50, height: 50), place: .dock, screens: screens),
                       SystemUITargets.target(name: "Notes", role: "AXDockItem", frame: CGRect(x: 650, y: 0, width: 50, height: 50), place: .dock, screens: screens)]
            .compactMap { $0 }
        let found = SystemUITargets.findResult(words: "safari", visible: visible, hidden: [])
        #expect((found["candidates"] as? [[String: Any]])?.map { $0["name"] as? String } == ["Safari"] && found["ok"] as? Bool == true)
        // Nothing shares a word: everything named is listed, said so.
        let all = SystemUITargets.findResult(words: "bluetooth", visible: visible, hidden: [])
        #expect((all["candidates"] as? [[String: Any]])?.count == 2 && (all["note"] as? String)?.contains("nothing there shares a word") == true)
    }

    /// annotate: a shape at a position draws round that point anywhere on the screen.
    @Test func anAnnotationAtAPositionDrawsThere() {
        let display = CGRect(x: 0, y: 0, width: 1000, height: 500)
        let shape = RealtimeAnnotation(shape: "circle", name: nil, underPointer: false, text: nil, x: 0.9, y: 0.02)
        guard case .success = RealtimeAnnotate.validated([shape]) else { Issue.record("a positioned shape was refused"); return }
        let resolved = RealtimeAnnotate.resolve([shape], snapshotResponse: [:], screens: [display], pointer: nil, screenshotDisplay: display)
        #expect(resolved.drawn.count == 1)
        #expect(resolved.drawn.first.map { $0.frame.midX == 900 && $0.frame.midY == 490 } == true)
        // Parsed from the provider's arguments, and normalised from Gemini's native [y, x].
        let parsed = RealtimeToolCall.parsed(callID: "a", name: "annotate", arguments: ["shapes": [["shape": "box", "point": [20, 900]]]])
        let native = RealtimePointFormat.normalised(parsed, format: .native, stack: .geminiLive, screenshotPixels: nil)
        #expect(native.shapes?.first?.x == 0.9 && native.shapes?.first?.y == 0.02)
    }
}
