//
//  RenameItemTests.swift
//  leanring-buddyTests
//
//  `renameItem` / `rename_item`: Finder's rename of a listed item (measured
//  2026-10-13). Pure parts only — the name rules, which row is the item, the
//  empty point the committing click aims at, the kernel's words and the wire.
//  Whether Finder commits on that click is a live fact.
//

import CoreGraphics
import Foundation
import Testing
@testable import Clicky

private func line(_ object: [String: Any]) -> String {
    String(decoding: (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data(), as: UTF8.self)
}

struct RenameItemTests {

    // MARK: Names

    @Test func aNewNameIsOneFinderCanTakeAndNotHidden() {
        #expect(HarnessRenameItem.nameProblem("probe-renamed.txt") == nil)
        #expect(HarnessRenameItem.nameProblem("Notes 2026 (old).md") == nil)
        for bad in ["", "   ", "a/b.txt", "a:b.txt", "tab\there", "line\nbreak", ".hidden", String(repeating: "a", count: 256),
                    String(repeating: "é", count: 128)] {
            #expect(HarnessRenameItem.nameProblem(bad) != nil, "must refuse \(bad.prefix(12).debugDescription)")
        }
        #expect(HarnessRenameItem.nameProblem(String(repeating: "a", count: 255)) == nil)
    }

    @Test func theItemIsTheOneRowListedExactlyAsNamed() {
        let names: [String?] = [nil, "probe-file.txt", "Probe-file.txt", "copy.txt", "copy.txt"]
        #expect(HarnessRenameItem.resolveItem(named: "probe-file.txt", among: names) == .found(1))
        #expect(HarnessRenameItem.resolveItem(named: "probe-file", among: names) == .notFound, "the name as listed, with its extension")
        #expect(HarnessRenameItem.resolveItem(named: "copy.txt", among: names) == .ambiguous(2))
    }

    @Test func aNameAnotherItemHasIsTakenButTheItemsOwnCaseChangeIsNot() {
        let names: [String?] = ["a.txt", "b.txt", nil]
        #expect(HarnessRenameItem.nameTaken("b.txt", among: names, except: 0))
        #expect(HarnessRenameItem.nameTaken("B.TXT", among: names, except: 0), "APFS compares case-insensitively")
        #expect(!HarnessRenameItem.nameTaken("A.txt", among: names, except: 0), "a case-only rename of the item itself")
        #expect(!HarnessRenameItem.nameTaken("c.txt", among: names, except: 0))
    }

    // MARK: The committing click's point

    @Test func theClickAimsAtEmptySpaceBelowTheLastRowOrNowhere() throws {
        let area = CGRect(x: 300, y: 200, width: 600, height: 400)   // top-left coordinates
        let rows = [CGRect(x: 300, y: 200, width: 600, height: 24), CGRect(x: 300, y: 224, width: 600, height: 24)]
        let point = try #require(HarnessRenameItem.emptyPoint(area: area, rowFrames: rows))
        #expect(point.x == area.midX)
        #expect(point.y > 248 && point.y < area.maxY, "below the last row, inside the list")
        #expect(abs(point.y - 424) < 0.001, "the middle of the empty space")
        // Rows filling the area (or past it): no empty space, so no click.
        #expect(HarnessRenameItem.emptyPoint(area: area, rowFrames: [CGRect(x: 300, y: 580, width: 600, height: 24)]) == nil)
        #expect(HarnessRenameItem.emptyPoint(area: area, rowFrames: [CGRect(x: 300, y: 590, width: 600, height: 4)]) == nil,
                "a sliver under the margin is not space")
        // A scrolled-out last row reads (0,0,0,0): unknown is not empty.
        #expect(HarnessRenameItem.emptyPoint(area: area, rowFrames: [.zero]) == nil)
        #expect(HarnessRenameItem.emptyPoint(area: area, rowFrames: []) == nil)
        #expect(HarnessRenameItem.emptyPoint(area: .zero, rowFrames: rows) == nil)
    }

    // MARK: The kernel

    @Test func aRenameIsAllowedButBothNamesAreWordChecked() {
        #expect(ActionSafetyKernel.evaluateRename(from: "probe-file.txt", to: "probe-renamed.txt") == .allow)
        guard case .refuse = ActionSafetyKernel.evaluateRename(from: "notes.txt", to: "payroll.txt") else {
            Issue.record("an irreversible word in the new name refuses"); return
        }
        guard case .requireConfirmation(_, true) = ActionSafetyKernel.evaluateRename(from: "delete-me.txt", to: "kept.txt") else {
            Issue.record("a destructive word in the old name asks"); return
        }
        guard case .requireConfirmation(_, true) = ActionSafetyKernel.evaluateRename(from: "draft.txt", to: "publish now.txt") else {
            Issue.record("a publishing word asks"); return
        }
    }

    // MARK: The wire

    @Test func theVerbNeedsTheItemTheNewNameAndTheAppItActsIn() {
        let ok = try? HarnessPolicy.decode(line: line(["verb": "renameItem", "title": "probe-file.txt", "text": "probe-renamed.txt",
                                                       "expectApp": "com.apple.finder"])).get()
        #expect(ok?.verb == .renameItem)
        #expect(ok?.title == "probe-file.txt", "the audit line names the item")
        #expect(ok?.text == "probe-renamed.txt")
        guard case .failure(.missingField("title")) = HarnessPolicy.decode(line: line(["verb": "renameItem", "text": "b.txt", "expectApp": "Finder"])) else {
            Issue.record("no item must refuse"); return
        }
        guard case .failure(.missingField("text")) = HarnessPolicy.decode(line: line(["verb": "renameItem", "title": "a.txt", "expectApp": "Finder"])) else {
            Issue.record("no new name must refuse"); return
        }
        guard case .failure(.missingField("expectApp")) = HarnessPolicy.decode(line: line(["verb": "renameItem", "title": "a.txt", "text": "b.txt"])) else {
            Issue.record("no expectApp must refuse"); return
        }
        guard case .failure(.invalidField(field: "text", _)) = HarnessPolicy.decode(
            line: line(["verb": "renameItem", "title": "a.txt", "text": "../b.txt", "expectApp": "Finder"])) else {
            Issue.record("a slash must refuse"); return
        }
    }

    /// Mutating everywhere; a read-only task may not rename; a ticket binds the new name.
    @Test func itIsGuardedAsMutatingAndNeverReadOnly() throws {
        #expect(HarnessVerb.renameItem.isMutating)
        #expect(HarnessVerb.renameItem.elementAction == nil)
        #expect(HarnessPolicy.killSwitchRefusal(verb: .renameItem, killSwitchPresent: true) != nil)
        let secure = SecureInputState(isOn: true, holderPID: nil, holderName: nil, holderIsFrontmost: true)
        #expect(HarnessPolicy.handOverRefusal(verb: .renameItem, secureInput: secure) != nil)
        #expect(AgentLoop.readOnlyRefusal(["verb": "renameItem", "title": "a.txt", "text": "b.txt", "expectApp": "com.apple.finder"],
                                          focusedField: { nil }) != nil)
        let request = try HarnessPolicy.decode(line: line(["verb": "renameItem", "title": "a.txt", "text": "b.txt", "expectApp": "Finder"])).get()
        let other = try HarnessPolicy.decode(line: line(["verb": "renameItem", "title": "a.txt", "text": "c.txt", "expectApp": "Finder"])).get()
        #expect(HarnessServer.confirmationShape(for: request, bundleIdentifier: "com.apple.finder").text == "b.txt")
        #expect(HarnessServer.confirmationShape(for: request, bundleIdentifier: "com.apple.finder")
                != HarnessServer.confirmationShape(for: other, bundleIdentifier: "com.apple.finder"), "approving b.txt is not approving c.txt")
    }

    // MARK: The tool

    @Test func renameItemIsAnActingToolSentAsTheVerbInFinder() throws {
        #expect(RealtimeVoiceVerbs.allToolNames.contains("rename_item"))
        #expect(RealtimeVoiceVerbs.isActingTool("rename_item"))
        #expect(!RealtimeVoiceVerbs.readOnlyToolNames.contains("rename_item"))
        #expect(AgentPlan.stepTools.contains("rename_item"))
        let call = RealtimeToolCall.parsed(callID: "r", name: "rename_item", arguments: ["name": "probe-file.txt", "new_name": "probe-renamed.txt"])
        #expect(call.appName == nil, "the item's name is not an app's")
        let request = try JSONSerialization.jsonObject(with: Data(try RealtimeOpenAppTool.harnessRequestLine(for: call).get().utf8)) as? [String: Any]
        #expect(request?["verb"] as? String == "renameItem")
        #expect(request?["title"] as? String == "probe-file.txt")
        #expect(request?["text"] as? String == "probe-renamed.txt")
        #expect(request?["expectApp"] as? String == "com.apple.finder")
        guard case .success = HarnessPolicy.decode(line: try RealtimeOpenAppTool.harnessRequestLine(for: call).get()) else {
            Issue.record("the rename line did not decode"); return
        }
        guard case .failure(let refusal) = RealtimeOpenAppTool.harnessRequestLine(
            for: RealtimeToolCall.parsed(callID: "r", name: "rename_item", arguments: ["name": "probe-file.txt"])) else {
            Issue.record("no new name must refuse before the harness"); return
        }
        #expect(refusal.error == "missingName")
        #expect(AgentPlan.precheck([["tool": "rename_item", "name": "a.txt"]]) != nil)
        #expect(AgentPlan.precheck([["tool": "rename_item", "name": "a.txt", "new_name": "b.txt"]]) == nil)
        #expect(JarvisNotchReason.byErrorCode["renameNotCommitted"] != nil)
    }
}
