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
                                                    affordanceMap: map.offer, now: 10_000)
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
                                                      followUpConfirmed: nil, affordanceMap: map.offer, now: 10_000)
        #expect(unmapped.source == nil, "a private item is never in the map, so never offered by it")
        // This turn's find still comes first.
        let found = RealtimeStandingOffer(candidates: [RealtimeMenuCandidate(path: ["View", "as List"], shortcut: nil)], app: "com.apple.finder", uptime: 9_999)
        #expect(RealtimeOpenAppTool.pressOffer(path: ["View", "as List"], thisTurn: found, previousTurn: nil, followUpConfirmed: nil,
                                               affordanceMap: map.offer, now: 10_000).source == .thisTurn)
    }

    @Test func aShortcutBecomesTheOwningItemsPath() throws {
        let map = try #require(AffordanceMap(menusResponse: menus, bundleIdentifier: "com.apple.finder", version: "1", pid: 1, builtUptime: 0))
        let parsed = RealtimeToolCall.parsed(callID: "1", name: RealtimeVoiceVerbs.pressMenuName, arguments: ["app": "Finder", "shortcut": "⌘2"])
        #expect(parsed.shortcut == "⌘2")
        #expect(parsed.path == nil)
        guard case .success(let resolved) = RealtimeOpenAppTool.withShortcutResolved(parsed, map: map.offer) else {
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
        guard case .success(let kept) = RealtimeOpenAppTool.withShortcutResolved(both, map: map.offer) else { Issue.record("a path passes"); return }
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
}
