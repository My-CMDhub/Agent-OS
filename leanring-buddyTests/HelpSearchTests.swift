//
//  HelpSearchTests.swift
//  leanring-buddyTests
//
//  `helpSearch` / `search_help` (design 2026-10-07 §A, build step 5). The live
//  half — press Help open, write the search field's AXValue, read the result
//  table, AXCancel the menu — was measured by the coordinator 2026-10-11
//  (Calculator x3, TextEdit x1) and is proven by running it. These prove the
//  pure half: how result rows become menu paths and topics, which paths count
//  as real menu items, when the table has settled, the wire refusals, and that
//  only resolved menu paths — never topics — become a press_menu offer.
//

import Foundation
import Testing
@testable import Clicky

private func line(_ object: [String: Any]) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
}

private func item(_ path: [String], enabled: Bool = true, submenu: Bool = false) -> AccessibilityMenu.ListedItem {
    AccessibilityMenu.ListedItem(path: path, role: "AXMenuItem", isEnabled: enabled, shortcut: nil, hasSubmenu: submenu, isMarked: false)
}

struct HelpSearchTests {

    // MARK: Rows

    /// TextEdit "font", as the coordinator read it: a blank header, menu hits as
    /// " > " paths, a blank header, topic titles, "Show All Help Topics" last.
    @Test func rowsSplitIntoMenuPathsAndTopicsAtTheirHeaders() {
        let rows = ["", "Font", "Font > Show Fonts", "Font > Bold", "",
                    "Use the scientific calculator on Mac", "Change fonts in TextEdit", "Show All Help Topics"]
        let classified = HarnessHelpSearch.classify(rows: rows)
        #expect(classified.menuPaths == [["Font"], ["Font", "Show Fonts"], ["Font", "Bold"]])
        #expect(classified.topics == ["Use the scientific calculator on Mac", "Change fonts in TextEdit"])
    }

    @Test func aSearchWithNoMenuHitsIsAllTopics() {
        let classified = HarnessHelpSearch.classify(rows: ["", "Use memory functions in Calculator", "Show All Help Topics"])
        #expect(classified.menuPaths.isEmpty)
        #expect(classified.topics == ["Use memory functions in Calculator"])
        #expect(HarnessHelpSearch.classify(rows: []) == .init(menuPaths: [], topics: []))
    }

    /// No "Show All Help Topics" row (another language, another build): a section
    /// with a " > " path is menus, any other is topics — never the other way round.
    @Test func withoutTheShowAllRowAPathSectionIsStillMenus() {
        let classified = HarnessHelpSearch.classify(rows: ["", "View > Scientific", "", "Calculator help"])
        #expect(classified.menuPaths == [["View", "Scientific"]])
        #expect(classified.topics == ["Calculator help"])
    }

    /// Live 2026-10-11, Calculator: Help fills in stages — the menu hit ("Scientific")
    /// or "No Results Found" first, the topics and "Show All Help Topics" ~100 ms
    /// later — so two identical reads of a partial table settled on 1 row.
    @Test func theTableHasSettledOnlyOnceTheTopicsHaveArrived() {
        let full = ["", "Scientific", "", "Use the scientific calculator on Mac", "Show All Help Topics"]
        #expect(!HarnessHelpSearch.isSettled(previous: nil, current: full))
        #expect(!HarnessHelpSearch.isSettled(previous: [], current: []))
        #expect(!HarnessHelpSearch.isSettled(previous: ["", "Scientific"], current: ["", "Scientific"]))
        #expect(!HarnessHelpSearch.isSettled(previous: ["No Results Found"], current: ["No Results Found"]))
        #expect(!HarnessHelpSearch.isSettled(previous: Array(full.dropLast()), current: full))
        #expect(HarnessHelpSearch.isSettled(previous: full, current: full))
    }

    @Test func theNoResultsPlaceholderIsNotATopic() {
        #expect(HarnessHelpSearch.classify(rows: ["No Results Found"]) == .init(menuPaths: [], topics: []))
    }

    // MARK: Resolution against the live listing

    /// A Help path may start below the bar (TextEdit's "Font > Bold" is Format >
    /// Font > Bold): kept only when it ends exactly one enabled leaf.
    @Test func onlyAPathEndingOneEnabledLeafIsKept() {
        let listing = [
            item(["Format"], submenu: true), item(["Format", "Font"], submenu: true),
            item(["Format", "Font", "Show Fonts"]), item(["Format", "Font", "Bold"], enabled: false),
            item(["View", "Scientific"]),
            item(["Edit", "Copy"]), item(["Format", "Text", "Copy"])
        ]
        let hits: [[String]] = [["Font"], ["Font", "Show Fonts"], ["Font", "Bold"], ["View", "Scientific"], ["Copy"], ["Nowhere"],
                                ["Font", "Show Fonts"]]
        let resolved = HarnessHelpSearch.resolve(hits, in: listing)
        #expect(resolved.paths == [["Format", "Font", "Show Fonts"], ["View", "Scientific"]])
        // A submenu parent, a disabled item, an ambiguous suffix, a missing one; the repeat is not counted twice.
        #expect(resolved.dropped == 4)
    }

    // MARK: The wire

    @Test func theVerbNeedsAQueryAndTheAppItActsIn() {
        guard case .failure(.missingField("expectApp")) = HarnessPolicy.decode(line: line(["verb": "helpSearch", "text": "memory"])) else {
            Issue.record("no expectApp must refuse"); return
        }
        guard case .failure(.missingField("text")) = HarnessPolicy.decode(line: line(["verb": "helpSearch", "expectApp": "Calculator"])) else {
            Issue.record("no text must refuse"); return
        }
        let ok = try? HarnessPolicy.decode(line: line(["verb": "helpSearch", "text": " memory ", "expectApp": "com.apple.calculator"])).get()
        #expect(ok?.verb == .helpSearch)
        #expect(ok?.text == "memory")
        #expect(ok?.title == "memory", "the audit line names what was searched")
    }

    @Test func aQueryThatIsLongHoldsAControlCharacterOrLooksLikeASecretIsRefused() {
        for text in [String(repeating: "m", count: 101), "memory\nrecall", "sk-proj-Ab3dEf6hIj9kLm2nOp5qRs8tUv1wXy4z"] {
            guard case .failure(.invalidField(field: "text", _)) = HarnessPolicy.decode(
                line: line(["verb": "helpSearch", "text": text, "expectApp": "Calculator"])) else {
                Issue.record("must refuse \(text.prefix(12))"); continue
            }
        }
    }

    /// Mutating for the kill switch, policy and audit; it types, so secure input
    /// hands over; and a read-only task may still run it.
    @Test func itIsGuardedAsMutatingButAllowedReadOnly() {
        #expect(HarnessVerb.helpSearch.isMutating)
        #expect(HarnessPolicy.killSwitchRefusal(verb: .helpSearch, killSwitchPresent: true) != nil)
        let secure = SecureInputState(isOn: true, holderPID: nil, holderName: nil, holderIsFrontmost: true)
        #expect(HarnessPolicy.handOverRefusal(verb: .helpSearch, secureInput: secure) != nil)
        #expect(AgentLoop.readOnlyRefusal(["verb": "helpSearch", "text": "memory", "expectApp": "Calculator"], focusedField: { nil }) == nil)
    }

    // MARK: The tool

    @Test func searchHelpIsAReadOnlyAppScopedToolSentAsTheVerb() throws {
        #expect(RealtimeVoiceVerbs.allToolNames.contains("search_help"))
        #expect(RealtimeVoiceVerbs.readOnlyToolNames.contains("search_help"))
        #expect(RealtimeVoiceVerbs.isAppScopedMenuTool("search_help"))
        #expect(!RealtimeVoiceVerbs.isActingTool("search_help"))
        #expect(AgentLoop.readingTools.contains("search_help") && AgentPlan.isReading("search_help"))
        let call = RealtimeToolCall(callID: "h", name: "search_help", appName: "Calculator", words: "memory")
        let request = try JSONSerialization.jsonObject(with: Data(try RealtimeOpenAppTool.harnessRequestLine(
            for: call, expectApp: "com.apple.calculator").get().utf8)) as? [String: Any]
        #expect(request?["verb"] as? String == "helpSearch")
        #expect(request?["text"] as? String == "memory")
        #expect(request?["expectApp"] as? String == "com.apple.calculator")
    }

    /// The offer: resolved, non-private menu paths become press_menu's offer,
    /// exactly as a find_menu_items result does; a topic is never pressable
    /// (G07's last run pressed "Help > Calculator Help", opened Tips, then was refused).
    @Test func onlyResolvedMenuPathsAreOfferedAndTopicsNeverAre() async throws {
        let response = line(["ok": true, "menuItems": [["View", "Scientific"], ["File", "Open Recent", "Taxes.pdf"]],
                             "menuItemsDropped": 1, "topics": ["\"Use memory functions in Calculator\""], "closed": true])
        let call = RealtimeToolCall(callID: "h", name: "search_help", appName: "com.apple.calculator", words: "memory")
        let dispatch = await RealtimeOpenAppTool.dispatch(call, answer: { _ in response })
        #expect(dispatch.harnessConfirmed)
        let offered = try #require(dispatch.menuOffer)
        #expect(offered.candidates.map(\.path) == [["View", "Scientific"]])
        #expect(offered.privacyDroppedCount == 1)
        #expect((dispatch.result["topics"] as? [String]) == ["\"Use memory functions in Calculator\""])
        let standing = RealtimeStandingOffer(candidates: offered.candidates, app: "com.apple.calculator", uptime: 0)
        func press(_ path: [String]) -> Result<String, RealtimeToolRefusal> {
            RealtimeOpenAppTool.harnessRequestLine(for: RealtimeToolCall(callID: "p", name: "press_menu", appName: "Calculator", path: path),
                                                   expectApp: "com.apple.calculator", offered: standing.candidates, offeredApp: standing.app)
        }
        guard case .success = press(["View", "Scientific"]) else { Issue.record("a resolved help path is pressable"); return }
        guard case .failure(let refusal) = press(["Help", "Use memory functions in Calculator"]) else {
            Issue.record("a topic must never be pressable"); return
        }
        #expect(refusal.error == "notOffered")
    }

    @Test func aFailedSearchOffersNothing() async {
        let call = RealtimeToolCall(callID: "h", name: "search_help", appName: "com.apple.calculator", words: "memory")
        let dispatch = await RealtimeOpenAppTool.dispatch(call, answer: { _ in
            line(["ok": false, "error": "helpSearchUnavailable", "message": "no search field"]) })
        #expect(dispatch.menuOffer == nil)
        #expect(dispatch.result["error"] as? String == "helpSearchUnavailable")
        #expect(JarvisNotchReason.byErrorCode["helpSearchUnavailable"] != nil)
    }

    // MARK: G07, judged by outcome and meaning

    @Test func g07PassesOnAnOkMemorySearchWhoseResultTheAnswerNames() {
        let calls: [[String: Any]] = [["tool": "search_help", "ok": true, "words": "Memory functions",
                                       "found": ["\"Use memory functions in Calculator\"", "View > Show Paper Tape"]]]
        #expect(GeneralitySuite.helpSearchVerdict(calls: calls, spoken: "Its Help has a page on using the memory functions in Calculator.")["passed"] as? Bool == true)
        // The search ran, but the answer names nothing it returned.
        #expect(GeneralitySuite.helpSearchVerdict(calls: calls, spoken: "Done, sir.")["passed"] as? Bool == false)
        // Another query, or a search that failed, is no pass whatever is said.
        let other: [[String: Any]] = [["tool": "search_help", "ok": true, "words": "paper tape", "found": ["View > Show Paper Tape"]]]
        #expect(GeneralitySuite.helpSearchVerdict(calls: other, spoken: "show paper tape is in View")["passed"] as? Bool == false)
        let failed: [[String: Any]] = [["tool": "search_help", "ok": false, "words": "memory", "found": NSNull()]]
        #expect(GeneralitySuite.helpSearchVerdict(calls: failed, spoken: "memory functions in calculator")["passed"] as? Bool == false)
        // Live 2026-10-19T22-36-50Z: "Calculator User Guide" is not "Use the scientific calculator on Mac".
        let live: [[String: Any]] = [["tool": "search_help", "ok": true, "words": "memory",
                                      "found": ["\"Choose the right mode in Calculator on Mac\"", "\"Use the scientific calculator on Mac\""]]]
        #expect(GeneralitySuite.helpSearchVerdict(calls: live, spoken: "I chose Calculator Help, which opened the Calculator User Guide; "
            + "the search did not return anything I could read.")["passed"] as? Bool == false)
        #expect(GeneralitySuite.helpSearchVerdict(calls: live, spoken: "Two topics came back: Use the scientific calculator on Mac, "
            + "and Choose the right mode.")["passed"] as? Bool == true)
    }

    /// G07 2026-10-18, measured live: Tips' AXSearchField took "memory" by AX write and answered
    /// AXConfirm with success, and the window stayed on the welcome page — so the model is sent to
    /// search_help, and the suite quits the Help Viewer a G07 run opened (its leftover query was
    /// read as the next run's own typing).
    @Test func helpSearchIsTheRouteAndG07CleansUpTheHelpViewer() throws {
        let declaration = try #require(RealtimeVoiceVerbs.anthropicDeclarations().first { $0["name"] as? String == "search_help" })
        #expect((declaration["description"] as? String)?.contains("never its help window") == true)
        let g07 = try #require(GeneralitySuite.tasks.first { $0.id == "G07" })
        #expect(g07.apps.contains("com.apple.helpviewer"))
    }
}
