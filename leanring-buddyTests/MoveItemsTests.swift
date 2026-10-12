//
//  MoveItemsTests.swift
//  leanring-buddyTests
//
//  `moveItems` / `move_items`: Finder's move of listed items (measured
//  2026-10-13). Pure parts only — which rows the names are, the destination
//  path, Copy and Move Item Here found by shortcut, a name the destination
//  already holds, the kernel's words and the wire. Whether Finder moves on
//  Move Item Here is a live fact.
//

import Foundation
import Testing
@testable import Clicky

private func line(_ object: [String: Any]) -> String {
    String(decoding: (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data(), as: UTF8.self)
}

struct MoveItemsTests {

    // MARK: Names

    @Test func everyNameMustBeOneListedRow() {
        let listed: [String?] = [nil, "invoice-a.pdf", "invoice-b.pdf", "copy.txt", "copy.txt", "Receipts"]
        guard case .success(let indices) = HarnessMoveItems.resolveItems(["invoice-b.pdf", "invoice-a.pdf"], among: listed) else {
            Issue.record("both invoices are listed"); return
        }
        #expect(indices == [2, 1], "in the order asked")
        guard case .failure(let missing) = HarnessMoveItems.resolveItems(["invoice-a.pdf", "invoice-c.pdf"], among: listed) else {
            Issue.record("one missing name must refuse the whole move"); return
        }
        #expect(missing.code == "moveItemNotFound")
        guard case .failure(let twice) = HarnessMoveItems.resolveItems(["copy.txt"], among: listed) else {
            Issue.record("a name listed twice must refuse"); return
        }
        #expect(twice.code == "ambiguous")
    }

    // MARK: The destination

    @Test func theDestinationIsAPathOrAFolderNameInTheSameWindow() {
        let home = "/Users/owner", source = "/Users/owner/JARVIS-sandbox"
        func path(_ destination: String, source: String? = source, names: [String] = ["invoice-a.pdf"]) -> String? {
            try? HarnessMoveItems.destinationPath(destination, sourceFolder: source, names: names, home: home).get()
        }
        #expect(path("Receipts") == "/Users/owner/JARVIS-sandbox/Receipts")
        #expect(path("~/Archive") == "/Users/owner/Archive")
        #expect(path("/tmp/x/") == "/tmp/x")
        #expect(path("Receipts", source: nil) == nil, "a bare name with no known folder is unknown")
        #expect(path("~/Archive", source: nil) == "/Users/owner/Archive", "a path needs no window folder")
        #expect(path("a/b") == nil, "a relative path is not a folder name")
        #expect(path("~/JARVIS-sandbox") == nil, "the items' own folder")
        #expect(path("Receipts", names: ["Receipts"]) == nil, "a folder into itself")
        #expect(path("~/JARVIS-sandbox/Receipts/Old", names: ["Receipts"]) == nil, "a folder into its own subfolder")
        #expect(HarnessMoveItems.folderPath(document: "file:///Users/owner/JARVIS-sandbox/") == "/Users/owner/JARVIS-sandbox")
        #expect(HarnessMoveItems.folderPath(document: "https://example.com/") == nil)
        let bar = { HarnessMoveItems.folderPath(pathBar: $0, rootVolumeName: "Macintosh HD") }
        #expect(bar(["Macintosh HD", "Users", "owner", "JARVIS-sandbox"]) == "/Users/owner/JARVIS-sandbox")
        #expect(bar(["Macintosh HD"]) == "/")
        #expect(bar(["Backup", "Photos"]) == "/Volumes/Backup/Photos", "another volume lives under /Volumes")
        #expect(bar(["Macintosh HD", "Users", "a/b"]) == nil, "a shown slash is a colon on disk")
        #expect(bar([]) == nil)
    }

    @Test func aNameTheDestinationListsIsTakenCaseInsensitively() {
        let listed: [String?] = [nil, "Invoice-A.pdf", "notes.txt"]
        #expect(HarnessMoveItems.takenName(["invoice-b.pdf", "invoice-a.pdf"], destinationListed: listed) == "invoice-a.pdf")
        #expect(HarnessMoveItems.takenName(["invoice-b.pdf"], destinationListed: listed) == nil)
        #expect(HarnessMoveItems.takenName(["invoice-b.pdf"], destinationListed: []) == nil)
    }

    // MARK: Copy and Move Item Here, by shortcut

    private func item(_ label: String, _ character: String?, _ modifiers: Int = 0, enabled: Bool = true) -> AccessibilityMenu.Node {
        AccessibilityMenu.Node(label: label, role: AccessibilityMenu.menuItemRole, isEnabled: enabled,
                               shortcut: AccessibilityMenu.describeShortcut(character: character, modifiers: modifiers))
    }

    private func bar(_ menus: [(String, [AccessibilityMenu.Node])]) -> AccessibilityMenu.Node {
        AccessibilityMenu.Node(label: nil, role: AccessibilityMenu.menuBarRole, children: menus.map { title, items in
            AccessibilityMenu.Node(label: title, role: AccessibilityMenu.menuBarItemRole, children: [
                AccessibilityMenu.Node(label: nil, role: AccessibilityMenu.menuRole, children: items)
            ])
        })
    }

    @Test func copyAndMoveItemHereAreFoundByShortcutNotTitle() {
        // As measured: Copy carries the selection in its title; ⌥⌘C is Copy as Pathname; ⌥⌘V the Option alternate.
        let finder = bar([("File", [item("New Folder", "N", 1)]),
                          ("Edit", [item("Copy \u{201C}invoice-a.pdf\u{201D}", "C"), item("Copy as Pathname", "C", 2),
                                    item("Paste", "V"), item("Move Item Here", "V", 2, enabled: false)])])
        #expect(HarnessMoveItems.menuItem(withShortcut: HarnessMoveItems.copyShortcut, in: finder, children: \.children)?.label
                == "Copy \u{201C}invoice-a.pdf\u{201D}")
        let moveHere = HarnessMoveItems.menuItem(withShortcut: HarnessMoveItems.moveHereShortcut, in: finder, children: \.children)
        #expect(moveHere?.label == "Move Item Here")
        #expect(moveHere?.isEnabled == false, "disabled until something is copied — the live step waits for enabled")
        let german = bar([("Bearbeiten", [item("2 Objekte kopieren", "c"), item("Objekt hierher bewegen", "v", 2)])])
        #expect(HarnessMoveItems.menuItem(withShortcut: HarnessMoveItems.copyShortcut, in: german, children: \.children)?.label == "2 Objekte kopieren")
        #expect(HarnessMoveItems.menuItem(withShortcut: HarnessMoveItems.moveHereShortcut, in: german, children: \.children) != nil)
        let doubled = bar([("Edit", [item("Copy", "C")]), ("Format", [item("Copy Style", "C")])])
        #expect(HarnessMoveItems.menuItem(withShortcut: HarnessMoveItems.copyShortcut, in: doubled, children: \.children) == nil)
        #expect(HarnessMoveItems.menuItem(withShortcut: HarnessMoveItems.moveHereShortcut, in: bar([("Edit", [item("Paste", "V")])]),
                                          children: \.children) == nil)
    }

    // MARK: The kernel

    @Test func aMoveIsAllowedButEveryNameIsWordCheckedAndTheTrashRefuses() {
        #expect(ActionSafetyKernel.evaluateMove(names: ["invoice-a.pdf", "invoice-b.pdf"], destination: "/Users/owner/JARVIS-sandbox/Receipts") == .allow)
        guard case .requireConfirmation(_, true) = ActionSafetyKernel.evaluateMove(names: ["a.pdf", "delete-me.txt"], destination: "/Users/owner/x") else {
            Issue.record("a destructive word in any name asks"); return
        }
        guard case .refuse = ActionSafetyKernel.evaluateMove(names: ["a.pdf"], destination: "/Users/owner/.Trash") else {
            Issue.record("the Trash refuses"); return
        }
        guard case .refuse = ActionSafetyKernel.evaluateMove(names: ["a.pdf"], destination: "/Users/owner/payroll") else {
            Issue.record("an irreversible word in the destination's name refuses"); return
        }
    }

    // MARK: The wire

    @Test func theVerbNeedsTheNamesTheFolderAndTheAppItActsIn() throws {
        let ok = try HarnessPolicy.decode(line: line(["verb": "moveItems", "path": ["invoice-a.pdf", "invoice-b.pdf"], "text": "Receipts",
                                                      "expectApp": "com.apple.finder"])).get()
        #expect(ok.verb == .moveItems)
        #expect(ok.path == ["invoice-a.pdf", "invoice-b.pdf"])
        #expect(ok.title == "invoice-a.pdf, invoice-b.pdf", "the audit line and a ticket name every item")
        #expect(ok.text == "Receipts")
        for (raw, field) in [(["verb": "moveItems", "text": "R", "expectApp": "Finder"] as [String: Any], "path"),
                             (["verb": "moveItems", "path": ["a.pdf"], "expectApp": "Finder"], "text"),
                             (["verb": "moveItems", "path": ["a.pdf"], "text": "R"], "expectApp")] {
            guard case .failure(.missingField(field)) = HarnessPolicy.decode(line: line(raw)) else { Issue.record("no \(field) must refuse"); continue }
        }
        for names in [["a.pdf", "a.pdf"], ["a/b.pdf"], (0...HarnessMoveItems.maximumItems).map { "f\($0).txt" }] {
            guard case .failure(.invalidField(field: "path", _)) = HarnessPolicy.decode(
                line: line(["verb": "moveItems", "path": names, "text": "R", "expectApp": "Finder"])) else {
                Issue.record("bad names must refuse: \(names.prefix(2))"); continue
            }
        }
        #expect(HarnessVerb.moveItems.isMutating)
        #expect(HarnessVerb.moveItems.elementAction == nil)
        #expect(HarnessPolicy.killSwitchRefusal(verb: .moveItems, killSwitchPresent: true) != nil)
        #expect(AgentLoop.readOnlyRefusal(["verb": "moveItems", "path": ["a.pdf"], "text": "R"], focusedField: { nil }) != nil)
    }

    @Test func theToolCarriesTheNamesAndTheFolderToTheHarness() throws {
        let call = RealtimeToolCall.parsed(callID: "c", name: "move_items",
                                           arguments: ["names": ["invoice-a.pdf", "invoice-b.pdf"], "to_folder": "Receipts"])
        #expect(call.path == ["invoice-a.pdf", "invoice-b.pdf"])
        #expect(call.text == "Receipts")
        #expect(call.appName == nil)
        let declaration = try #require(RealtimeVoiceVerbs.openAIDeclarations.first { $0["name"] as? String == "move_items" })
        #expect((declaration["description"] as? String)?.contains("Your clipboard is restored afterwards") == true)
        #expect(AgentPlan.requiredArguments["move_items"] == [["names", "to_folder"]])
    }
}
