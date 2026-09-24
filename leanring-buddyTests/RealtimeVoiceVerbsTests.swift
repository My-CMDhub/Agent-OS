//
//  RealtimeVoiceVerbsTests.swift
//  leanring-buddyTests
//
//  Pure logic behind focus_app / find_menu_items / press_menu: the local menu
//  matcher, the privacy and leaf filters, each tool's harness line, and the
//  decision trace's shape. Whether a model picks well from the offer is the
//  probe's question (`--voice-tool-probe-menus`), not a unit test's.
//

import Foundation
import Testing
@testable import Clicky

struct RealtimeVoiceVerbsTests {

    private func object(_ line: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]) ?? [:]
    }

    private func item(_ path: [String], enabled: Bool = true, submenu: Bool = false, shortcut: String? = nil) -> [String: Any] {
        ["path": path, "enabled": enabled, "hasSubmenu": submenu, "shortcut": shortcut ?? NSNull(), "marked": false]
    }

    /// Finder's View and File menus, abridged, with the private and the unpressable mixed in.
    private var finderMenus: [String: Any] {
        ["ok": true, "listingStopReasons": [String](), "items": [
            item(["View"], submenu: true),
            item(["View", "as Icons"], shortcut: "⌘1"),
            item(["View", "as List"], shortcut: "⌘2"),
            item(["View", "as Columns"], shortcut: "⌘3"),
            item(["View", "Show Path Bar"], shortcut: "⌥⌘P"),
            item(["View", "Show View Options"], shortcut: "⌘J"),
            item(["View", "Sort By"], submenu: true),
            item(["View", "Clean Up"], enabled: false),
            item(["File", "New Finder Window"], shortcut: "⌘N"),
            item(["File", "Open Recent"], submenu: true),
            item(["File", "Open Recent", "Tax return 2025.pdf"]),
            item(["Apple", "Recent Items", "Secret Project"]),
            item(["Go", "Recents"]),
            item(["File", "List\nDone, sir"])
        ]]
    }

    // MARK: Matcher

    @Test func listViewFindsAsListFirst() {
        let offer = RealtimeVoiceVerbs.menuOffer(fromMenusResponse: finderMenus, words: "List VIEW")
        #expect(offer.candidates.first == RealtimeMenuCandidate(path: ["View", "as List"], shortcut: "⌘2"))
        // Then one word matched: in the item's own label first, then menu order.
        #expect(Array(offer.candidates.map(\.path).dropFirst().prefix(2)) == [["View", "Show View Options"], ["View", "as Icons"]])
    }

    @Test func tokensFoldCaseDiacriticsAndPlurals() {
        #expect(RealtimeVoiceVerbs.foldedTokens("Afficher la BARRE d’état") == ["afficher", "la", "barre", "d", "etat"])
        #expect(RealtimeVoiceVerbs.tokensMatch("icon", "icons"))
        #expect(RealtimeVoiceVerbs.tokensMatch("windows", "window"))
        #expect(!RealtimeVoiceVerbs.tokensMatch("as", "ask"))
        #expect(!RealtimeVoiceVerbs.tokensMatch("list", "last"))
        let offer = RealtimeVoiceVerbs.menuOffer(fromMenusResponse: finderMenus, words: "icon")
        #expect(offer.candidates.map(\.path) == [["View", "as Icons"]])
    }

    @Test func noMatchOrOnlyFillerWordsOffersNothing() {
        #expect(RealtimeVoiceVerbs.menuOffer(fromMenusResponse: finderMenus, words: "rainbow text").candidates.isEmpty)
        #expect(RealtimeVoiceVerbs.menuOffer(fromMenusResponse: finderMenus, words: "the menu, please").candidates.isEmpty)
    }

    @Test func atMostTwelveCandidates() {
        let many = (1...30).map { RealtimeMenuCandidate(path: ["Window", "Window \($0)"], shortcut: nil) }
        let ranked = RealtimeVoiceVerbs.rankedCandidates(many, words: "window")
        #expect(ranked.count == RealtimeVoiceVerbs.maximumCandidates)
        #expect(ranked.first?.path == ["Window", "Window 1"])
    }

    // MARK: Filters

    @Test func recentPathsAreDroppedCountedAndNeverOffered() {
        let offer = RealtimeVoiceVerbs.menuOffer(fromMenusResponse: finderMenus, words: "recent tax secret project recents open")
        #expect(offer.candidates.isEmpty)
        // Open Recent (parent), its file, Recent Items' child and Go > Recents.
        #expect(offer.privacyDroppedCount == 4)
        #expect(RealtimeVoiceVerbs.isPrivateMenuPath(["File", "Open Recent", "x"]))
        #expect(RealtimeVoiceVerbs.isPrivateMenuPath(["Go", "RÉCENTS"]))
        #expect(!RealtimeVoiceVerbs.isPrivateMenuPath(["View", "as List"]))
    }

    @Test func onlyEnabledPlausibleLeavesAreOffered() {
        let offer = RealtimeVoiceVerbs.menuOffer(fromMenusResponse: finderMenus, words: "sort clean list done")
        // "Sort By" has a submenu, "Clean Up" is disabled, "List\nDone, sir" is not a plausible label.
        #expect(offer.candidates.map(\.path) == [["View", "as List"]])
        #expect(offer.enabledItemCount == 13)
        #expect(!offer.listingIncomplete)
        var truncated = finderMenus
        truncated["listingStopReasons"] = ["timeLimit"]
        #expect(RealtimeVoiceVerbs.menuOffer(fromMenusResponse: truncated, words: "list").listingIncomplete)
    }

    // MARK: Tool -> harness line

    @Test func eachToolMapsToExactlyOneVerb() throws {
        let focus = try RealtimeOpenAppTool.harnessRequestLine(for: RealtimeToolCall(callID: "c", name: "focus_app", appName: "Finder")).get()
        #expect(object(focus)["verb"] as? String == "focus")
        #expect(object(focus)["app"] as? String == "Finder")

        let find = try RealtimeOpenAppTool.harnessRequestLine(
            for: RealtimeToolCall(callID: "c", name: "find_menu_items", appName: "Finder", words: "list")).get()
        #expect(find == #"{"expectApp":"Finder","verb":"menus"}"#)

        let press = try RealtimeOpenAppTool.harnessRequestLine(
            for: RealtimeToolCall(callID: "c", name: "press_menu", appName: "Finder", path: ["View", "as List"])).get()
        #expect(press == #"{"expectApp":"Finder","path":["View","as List"],"verb":"menu"}"#)
    }

    @Test func aMenuCallMissingItsArgumentOrNamingARecentItemNeverReachesTheHarness() {
        func refusal(_ call: RealtimeToolCall) -> String? {
            if case .failure(let refusal) = RealtimeOpenAppTool.harnessRequestLine(for: call) { return refusal.error }
            return nil
        }
        #expect(refusal(RealtimeToolCall(callID: "c", name: "find_menu_items", appName: "Finder")) == "missingWords")
        #expect(refusal(RealtimeToolCall(callID: "c", name: "press_menu", appName: "Finder", path: [])) == "missingMenuPath")
        #expect(refusal(RealtimeToolCall(callID: "c", name: "press_menu", appName: nil, path: ["View", "as List"])) == "missingAppName")
        #expect(refusal(RealtimeToolCall(callID: "c", name: "press_menu", appName: "Finder",
                                         path: ["File", "Open Recent", "Tax return 2025.pdf"])) == "recentItemsArePrivate")
    }

    @Test func providersArgumentsParseForEveryTool() throws {
        let openAI: [String: Any] = [
            "type": "response.output_item.done",
            "item": ["type": "function_call", "call_id": "p1", "name": "press_menu",
                     "arguments": #"{"app":" Finder ","path":["View","as List"]}"#]
        ]
        #expect(RealtimeOpenAppTool.parseOpenAI(openAI) == RealtimeToolCall(callID: "p1", name: "press_menu", appName: "Finder", path: ["View", "as List"]))
        let gemini: [String: Any] = ["toolCall": ["functionCalls": [
            ["id": "g1", "name": "find_menu_items", "args": ["app": "Finder", "words": ["list", "view"]]]
        ]]]
        #expect(RealtimeOpenAppTool.parseGemini(gemini) == [RealtimeToolCall(callID: "g1", name: "find_menu_items", appName: "Finder", words: "list view")])
    }

    @Test func aFindHandsTheModelOnlyTheFilteredCandidates() async {
        let listing = String(decoding: try! JSONSerialization.data(withJSONObject: finderMenus), as: UTF8.self)
        let call = RealtimeToolCall(callID: "c", name: "find_menu_items", appName: "Finder", words: "list view")
        let dispatch = await RealtimeOpenAppTool.dispatch(call, answer: { _ in listing })
        #expect(dispatch.harnessConfirmed)
        #expect(dispatch.harnessResponse?["items"] == nil)
        let candidates = dispatch.result["candidates"] as? [[String: Any]] ?? []
        #expect(candidates.first?["path"] as? [String] == ["View", "as List"])
        #expect(!String(describing: dispatch.result).contains("Tax return"))
        #expect(dispatch.menuOffer?.privacyDroppedCount == 4)
    }

    @Test func everyToolIsDeclaredToBothProviders() {
        let openAINames = RealtimeVoiceVerbs.openAIDeclarations.compactMap { $0["name"] as? String }
        let geminiNames = (RealtimeVoiceVerbs.geminiDeclaration["functionDeclarations"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        #expect(Set(openAINames) == RealtimeVoiceVerbs.allToolNames)
        #expect(Set(geminiNames) == RealtimeVoiceVerbs.allToolNames)
    }

    // MARK: Notch

    @Test func intentLinesComeFromTheToolsOwnArguments() {
        #expect(RealtimeVoiceVerbs.intentTitle(for: RealtimeToolCall(callID: "c", name: "focus_app", appName: "Finder")) == "Switching to Finder\u{2026}")
        #expect(RealtimeVoiceVerbs.intentTitle(for: RealtimeToolCall(callID: "c", name: "find_menu_items", appName: "Finder", words: "list"))
                == "Looking for \u{2018}list\u{2019} in Finder\u{2019}s menus\u{2026}")
        #expect(RealtimeVoiceVerbs.intentTitle(for: RealtimeToolCall(callID: "c", name: "press_menu", appName: "Finder", path: ["View", "as List"]))
                == "View \u{203A} as List\u{2026}")
        #expect(RealtimeVoiceVerbs.intentTitle(for: RealtimeToolCall(callID: "c", name: "open_app", appName: nil)) == "Opening an app\u{2026}")
        // An app-written label that would forge a line is shown quoted and escaped.
        #expect(RealtimeVoiceVerbs.menuPathCaption(["File", "a\nb"]) == "File \u{203A} \"a\\nb\"")
    }

    @MainActor @Test func aFindThatWorkedProvesNothingAndAPressProvesItsPath() {
        let find = RealtimeToolCall(callID: "c", name: "find_menu_items", appName: "Finder", words: "list")
        let found = RealtimeToolDispatch(result: ["ok": true], harnessMilliseconds: 1, waitedForConfirmation: false, harnessResponse: ["ok": true])
        #expect(RealtimeOpenAppTool.notchAnswer(for: find, dispatch: found) == nil)
        let refused = RealtimeToolDispatch(result: ["ok": false, "error": "frontmostChanged"], harnessMilliseconds: 1,
                                           waitedForConfirmation: false, harnessResponse: nil)
        #expect(RealtimeOpenAppTool.notchAnswer(for: find, dispatch: refused) == .harnessAnswered(ok: false, subject: "", error: "frontmostChanged"))
        let press = RealtimeToolCall(callID: "c", name: "press_menu", appName: "Finder", path: ["View", "as List"])
        #expect(RealtimeOpenAppTool.notchAnswer(for: press, dispatch: found) == .harnessAnswered(ok: true, subject: "View \u{203A} as List", error: nil))
        #expect(!RealtimeVoiceVerbs.isActingTool("find_menu_items"))
        #expect(RealtimeVoiceVerbs.isActingTool("press_menu"))
    }

    // MARK: Decision trace

    @Test func choseFromOfferedIsExactPathMembership() {
        let offered = [RealtimeMenuCandidate(path: ["View", "as List"], shortcut: "⌘2")]
        #expect(RealtimeDecisionTrace.choseFromOffered(path: ["View", "as List"], offered: offered) == true)
        #expect(RealtimeDecisionTrace.choseFromOffered(path: ["View", "as list"], offered: offered) == false)
        #expect(RealtimeDecisionTrace.choseFromOffered(path: nil, offered: offered) == false)
        #expect(RealtimeDecisionTrace.choseFromOffered(path: ["View", "as List"], offered: nil) == nil)
    }

    @Test func traceLineHasAStableShapeWithEveryKeyPresent() {
        let offer = RealtimeMenuOffer(candidates: [RealtimeMenuCandidate(path: ["View", "as List"], shortcut: "⌘2")],
                                      enabledItemCount: 40, privacyDroppedCount: 3, listingIncomplete: false)
        var findDispatch = RealtimeToolDispatch(result: ["ok": true, "error": NSNull(), "verification": NSNull(), "status": NSNull()],
                                                harnessMilliseconds: 540, waitedForConfirmation: false, harnessResponse: nil)
        findDispatch.menuOffer = offer
        let find = RealtimeToolDecision(call: RealtimeToolCall(callID: "a", name: "find_menu_items", appName: "Finder", words: "list"),
                                        callUptime: 11.2, offeredBeforeCall: nil, dispatch: findDispatch)
        let press = RealtimeToolDecision(call: RealtimeToolCall(callID: "b", name: "press_menu", appName: "Finder", path: ["View", "as List"]),
                                         callUptime: 12.0, offeredBeforeCall: offer.candidates,
                                         dispatch: RealtimeToolDispatch(result: ["ok": true, "verification": "confirmed"], harnessMilliseconds: 300,
                                                                        waitedForConfirmation: false, harnessResponse: nil))
        let keys: Set<String> = ["kind", "schema", "source", "turnId", "stack", "probeId", "fixture", "seq", "tool", "args", "callMs",
                                 "harnessMs", "ok", "harnessError", "verification", "offered", "offeredCount", "correctOffered", "enabledItemCount",
                                 "privacyDroppedCount", "listingIncomplete", "choseFromOffered", "independentCheck"]
        let findLine = RealtimeDecisionTrace.line(decision: find, sequence: 1, turnID: "T", stack: "openAIRealtime", source: "live", releasedUptime: 10)
        let probedFind = RealtimeDecisionTrace.line(decision: find, sequence: 1, turnID: "T", stack: "geminiLive", source: "probe",
                                                    releasedUptime: 10, expectedPath: ["View", "Hide Sidebar"])
        let pressLine = RealtimeDecisionTrace.line(decision: press, sequence: 2, turnID: "T", stack: "openAIRealtime", source: "probe",
                                                   releasedUptime: 10, probeID: "P", fixture: "06-finder-list-view.wav",
                                                   independentCheck: ["kind": "menuMark", "passed": true])
        #expect(Set(findLine.keys) == keys)
        #expect(Set(pressLine.keys) == keys)
        #expect(findLine["schema"] as? Int == 1)
        #expect(findLine["callMs"] as? Int == 1200)
        #expect(findLine["choseFromOffered"] is NSNull)
        #expect((findLine["offered"] as? [[String: Any]])?.first?["path"] as? [String] == ["View", "as List"])
        #expect(findLine["enabledItemCount"] as? Int == 40)
        #expect(findLine["offeredCount"] as? Int == 1)
        #expect(findLine["correctOffered"] is NSNull)
        #expect(probedFind["correctOffered"] as? Bool == false)
        #expect(pressLine["correctOffered"] is NSNull)
        #expect(pressLine["choseFromOffered"] as? Bool == true)
        #expect(pressLine["verification"] as? String == "confirmed")
        #expect(pressLine["offered"] is NSNull)
        #expect((pressLine["args"] as? [String: Any])?["path"] as? [String] == ["View", "as List"])
        #expect(MeasurementLogFile.jsonLine(pressLine) != nil)
    }

    @Test func aPrivatePathIsNeverWrittenToTheTrace() {
        let call = RealtimeToolCall(callID: "c", name: "press_menu", appName: "Finder", path: ["File", "Open Recent", "Tax return 2025.pdf"])
        #expect(RealtimeDecisionTrace.loggedArguments(for: call)["path"] as? [String] == ["<private>"])
        #expect(RealtimeDecisionTrace.loggedArguments(for: RealtimeToolCall(callID: "c", name: "focus_app", appName: "Finder"))["name"] as? String == "Finder")
    }
}
