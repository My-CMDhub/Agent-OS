//
//  AffordanceOfferTests.swift
//  leanring-buddyTests
//
//  The affordance map as an offer (design 2026-10-07 §A "Intents"): a mapped
//  path counts as offered without a find_menu_items read, only in its own
//  app; press_menu(shortcut:) presses the one mapped item that owns it, by its
//  path; a mapped path that came back notFound / targetIsSubmenu stales the map.
//

import Foundation
import Testing
@testable import Clicky

private let menus: [String: Any] = ["ok": true, "items": [
    ["path": ["File", "New Folder"], "enabled": true, "shortcut": "⇧⌘N", "hasSubmenu": false],
    ["path": ["View", "as List"], "enabled": true, "shortcut": "⌘2", "hasSubmenu": false],
    ["path": ["File", "Open Recent", "Taxes 2025.pdf"], "enabled": true, "shortcut": NSNull(), "hasSubmenu": false]
]]

struct AffordanceOfferTests {

    @Test func aMappedPathCountsAsOfferedOnlyInItsOwnApp() throws {
        let map = try #require(AffordanceMap(menusResponse: menus, bundleIdentifier: "com.apple.finder", version: "1", pid: 1, builtUptime: 0))
        let chosen = RealtimeOpenAppTool.pressOffer(path: ["View", "as List"], thisTurn: nil, previousTurn: nil, followUpConfirmed: nil,
                                                    affordanceMap: map.offer(readOnly: false), now: 10_000)
        #expect(chosen.source == .affordanceMap, "no age limit: the cache's own 10 minutes bound the map")
        let call = RealtimeToolCall(callID: "1", name: RealtimeVoiceVerbs.pressMenuName, appName: "Finder", path: ["View", "as List"])
        guard case .success = RealtimeOpenAppTool.harnessRequestLine(for: call, expectApp: "com.apple.finder", offered: chosen.offer?.candidates,
                                                                      offeredApp: chosen.offer?.app) else {
            Issue.record("a mapped path in its own app is offered"); return
        }
        guard case .failure(let refusal) = RealtimeOpenAppTool.harnessRequestLine(for: call, expectApp: "com.apple.Safari",
                                                                                   offered: chosen.offer?.candidates, offeredApp: chosen.offer?.app) else {
            Issue.record("another app's map is no offer"); return
        }
        #expect(refusal.error == "notOffered")
        let unmapped = RealtimeOpenAppTool.pressOffer(path: ["File", "Open Recent", "Taxes 2025.pdf"], thisTurn: nil, previousTurn: nil,
                                                      followUpConfirmed: nil, affordanceMap: map.offer(readOnly: false), now: 10_000)
        #expect(unmapped.source == nil, "a private item is never in the map, so never offered by it")
        // This turn's find still comes first.
        let found = RealtimeStandingOffer(candidates: [RealtimeMenuCandidate(path: ["View", "as List"], shortcut: nil)], app: "com.apple.finder", uptime: 9_999)
        #expect(RealtimeOpenAppTool.pressOffer(path: ["View", "as List"], thisTurn: found, previousTurn: nil, followUpConfirmed: nil,
                                               affordanceMap: map.offer(readOnly: false), now: 10_000).source == .thisTurn)
    }

    @Test func aShortcutBecomesTheOwningItemsPath() throws {
        let map = try #require(AffordanceMap(menusResponse: menus, bundleIdentifier: "com.apple.finder", version: "1", pid: 1, builtUptime: 0))
        let parsed = RealtimeToolCall.parsed(callID: "1", name: RealtimeVoiceVerbs.pressMenuName, arguments: ["app": "Finder", "shortcut": "⌘2"])
        #expect(parsed.shortcut == "⌘2")
        #expect(parsed.path == nil)
        guard case .success(let resolved) = RealtimeOpenAppTool.withShortcutResolved(parsed, map: map.offer(readOnly: false)) else {
            Issue.record("one owner resolves"); return
        }
        #expect(resolved.path == ["View", "as List"])
        guard case .failure(let refusal) = RealtimeOpenAppTool.withShortcutResolved(parsed, map: nil) else {
            Issue.record("no map: refused, never a keystroke"); return
        }
        #expect(refusal.error == "shortcutNotMapped")
        // A path wins: the shortcut is only read when no path was given.
        let both = RealtimeToolCall.parsed(callID: "2", name: RealtimeVoiceVerbs.pressMenuName,
                                           arguments: ["app": "Finder", "path": ["File", "New Folder"], "shortcut": "⌘2"])
        guard case .success(let kept) = RealtimeOpenAppTool.withShortcutResolved(both, map: map.offer(readOnly: false)) else { Issue.record("a path passes"); return }
        #expect(kept.path == ["File", "New Folder"])
    }

    @Test func theLoopsPressMenuDeclaresAShortcut() throws {
        let pressMenu = try #require(RealtimeVoiceVerbs.anthropicDeclarations().first { $0["name"] as? String == RealtimeVoiceVerbs.pressMenuName })
        let schema = try #require(pressMenu["input_schema"] as? [String: Any])
        #expect((schema["properties"] as? [String: Any])?["shortcut"] != nil)
        #expect((schema["required"] as? [String])?.contains("path") == false, "a shortcut alone is a whole press")
    }

    @Test func notFoundOrSubmenuStalesAMappedPress() {
        #expect(RealtimeOpenAppTool.invalidatesAffordanceMap(error: "notFound"))
        #expect(RealtimeOpenAppTool.invalidatesAffordanceMap(error: "targetIsSubmenu"))
        #expect(!RealtimeOpenAppTool.invalidatesAffordanceMap(error: "kernelRefused"))
        #expect(!RealtimeOpenAppTool.invalidatesAffordanceMap(error: nil))
    }

    /// Launch M05 2026-10-18: one reply batched open_app Notes + press_menu File > New Note, and the press
    /// was judged against the last look's Finder map. After a confirmed open/focus, the opened app's map judges.
    @Test func anOpenInTheSameReplyRejudgesLaterPressesByTheOpenedAppsMap() throws {
        let notes = "com.apple.Notes"
        #expect(AgentLoop.mapRebuildBundle(after: RealtimeOpenAppTool.name, confirmed: true, response: ["bundleIdentifier": notes]) == notes)
        #expect(AgentLoop.mapRebuildBundle(after: RealtimeVoiceVerbs.focusAppName, confirmed: true, response: ["bundleIdentifier": notes]) == notes)
        #expect(AgentLoop.mapRebuildBundle(after: RealtimeOpenAppTool.name, confirmed: false, response: ["bundleIdentifier": notes]) == nil,
                "an open that did not land changes nothing")
        #expect(AgentLoop.mapRebuildBundle(after: RealtimeVoiceVerbs.pressMenuName, confirmed: true, response: ["bundleIdentifier": notes]) == nil)
        #expect(AgentLoop.mapRebuildBundle(after: RealtimeVoiceVerbs.openURLName, confirmed: true, response: ["bundleIdentifier": "com.apple.Safari"]) == nil)

        let newNote = ["File", "New Note"]
        let notesMenus: [String: Any] = ["ok": true, "items": [["path": newNote, "enabled": true, "shortcut": "⌘N", "hasSubmenu": false]]]
        let finderMap = try #require(AffordanceMap(menusResponse: menus, bundleIdentifier: "com.apple.finder", version: "1", pid: 1, builtUptime: 0))
        let notesMap = try #require(AffordanceMap(menusResponse: notesMenus, bundleIdentifier: notes, version: "1", pid: 2, builtUptime: 1))
        let call = RealtimeToolCall(callID: "1", name: RealtimeVoiceVerbs.pressMenuName, appName: "Notes", path: newNote)
        func line(map: AffordanceMap) -> Result<String, RealtimeToolRefusal> {
            let chosen = RealtimeOpenAppTool.pressOffer(path: newNote, thisTurn: nil, previousTurn: nil, followUpConfirmed: nil,
                                                        affordanceMap: map.offer(readOnly: false), now: 2)
            return RealtimeOpenAppTool.harnessRequestLine(for: call, expectApp: notes, offered: chosen.offer?.candidates, offeredApp: chosen.offer?.app)
        }
        guard case .failure(let refusal) = line(map: finderMap) else { Issue.record("the old app's map offers nothing in Notes"); return }
        #expect(refusal.error == "notOffered")
        guard case .success = line(map: notesMap) else { Issue.record("the opened app's own map offers its path"); return }
        // The gate still holds: a path Notes' map does not list is refused against it.
        let invented = RealtimeToolCall(callID: "2", name: RealtimeVoiceVerbs.pressMenuName, appName: "Notes", path: ["File", "Delete Everything"])
        guard case .failure = RealtimeOpenAppTool.harnessRequestLine(for: invented, expectApp: notes, offered: notesMap.offer(readOnly: false).candidates,
                                                                     offeredApp: notes) else { Issue.record("an unlisted path stays refused"); return }
    }

    /// The agent step's notOffered says what to do next; the voice turn's still says to press nothing and say so.
    @Test func anAgentStepsNotOfferedSaysHowToRetry() {
        let listed = RealtimeOpenAppTool.agentStepNotOfferedMessage(menuListed: true)
        let unlisted = RealtimeOpenAppTool.agentStepNotOfferedMessage(menuListed: false)
        #expect(listed.contains("call press_menu again"))
        #expect(unlisted.contains("call find_menu_items"))
        for message in [listed, unlisted] {
            #expect(!message.contains("say so"), "a task's words ask for the outcome; the refusal must not steer to giving up")
            #expect(message.hasPrefix("Nothing was pressed"))
        }
        let call = RealtimeToolCall(callID: "1", name: RealtimeVoiceVerbs.pressMenuName, appName: "Notes", path: ["File", "New Note"])
        guard case .failure(let voice) = RealtimeOpenAppTool.harnessRequestLine(for: call, expectApp: "com.apple.Notes", offered: nil, offeredApp: nil) else {
            Issue.record("nothing offered: refused"); return
        }
        #expect(voice.error == "notOffered")
        #expect(voice.message.contains("press nothing and say so"), "an unasked press in a voice turn is still refused and said")
    }
}
