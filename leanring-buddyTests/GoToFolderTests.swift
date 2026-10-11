//
//  GoToFolderTests.swift
//  leanring-buddyTests
//
//  `goToFolder` / `go_to_folder` (owner's ruling 2026-10-11: a read-only task
//  may type a path into Finder's Go > Go to Folder field; nothing else widens).
//  The live half — press the menu item, wait for `PathTextField` inside
//  `GoToWindow`, write its AXValue, press the Touch Bar function row's "Go" —
//  was measured by the coordinator 2026-10-11 and is proven by running it.
//  These prove the pure half: which paths may be written, which menu item is
//  Go to Folder, the one "Go" / "Cancel" button, what counts as arriving, the
//  wire, the read-only allowance and the tool's request.
//

import Foundation
import Testing
@testable import Clicky

private func line(_ object: [String: Any]) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
}

struct GoToFolderTests {

    // MARK: Paths

    @Test func anAbsoluteOrHomePathMayBeWritten() {
        for path in ["~/Downloads", "~", "/Applications", "/Applications/Journey of pro/Heyclicky/scripts", "~/Desktop/a…b"] {
            #expect(HarnessGoToFolder.pathProblem(path) == nil, "\(path)")
        }
    }

    /// Return is never typed by any caller, and a bare name makes Go to Folder
    /// guess among its suggestions — so neither is written.
    @Test func anEmptyLongRelativeOrControlCharacterPathIsRefused() {
        for path in ["", "   ", "Downloads", "../etc", String(repeating: "/a", count: 513), "/tmp\n", "/tmp\r/x", "\t/x", "/a\u{7f}"] {
            #expect(HarnessGoToFolder.pathProblem(path) != nil, "\(path.debugDescription)")
        }
        #expect(HarnessGoToFolder.pathProblem("/" + String(repeating: "a", count: 1023)) == nil, "1024 characters is the limit, not over it")
    }

    @Test func theFolderNameExpectedIsThePathsLastComponent() {
        let home = "/Users/owner"
        #expect(HarnessGoToFolder.expectedFolderName("~/Downloads", home: home) == "Downloads")
        #expect(HarnessGoToFolder.expectedFolderName("~", home: home) == "owner")
        #expect(HarnessGoToFolder.expectedFolderName("/Applications/", home: home) == "Applications")
        #expect(HarnessGoToFolder.expectedFolderName("/Applications/Journey of pro/Heyclicky/scripts", home: home) == "scripts")
        #expect(HarnessGoToFolder.expectedFolderName("/a/b/../c", home: home) == "c")
        // The root shows as the volume's name, which a path cannot predict.
        #expect(HarnessGoToFolder.expectedFolderName("/", home: home) == nil)
    }

    // MARK: The menu item and the function row

    @Test func goToFolderIsMatchedWithEitherEllipsisAndNothingElse() {
        #expect(HarnessGoToFolder.isGoToFolderItem("Go to Folder…"))
        #expect(HarnessGoToFolder.isGoToFolderItem("Go to Folder..."))
        for label in [nil, "Go to Folder Later…", "Recent Folders", "Go", "Connect to Server…", ""] as [String?] {
            #expect(!HarnessGoToFolder.isGoToFolderItem(label), "\(String(describing: label))")
        }
    }

    /// Live 2026-10-11: while the panel is up Finder's function row holds exactly
    /// "Cancel" and "Go"; with no panel it holds the window's own controls.
    @Test func exactlyOneButtonOfATitleIsPickedOrNone() {
        let panel: [String?] = ["Cancel", "Go"]
        #expect(HarnessGoToFolder.singleIndex(of: "Go", in: panel) == 1)
        #expect(HarnessGoToFolder.singleIndex(of: "Cancel", in: panel) == 0)
        #expect(HarnessGoToFolder.isPanelShowing(functionRowTitles: panel))
        let window: [String?] = ["View Options", "Quick Look", "Share…", nil]
        #expect(HarnessGoToFolder.singleIndex(of: "Go", in: window) == nil)
        #expect(!HarnessGoToFolder.isPanelShowing(functionRowTitles: window))
        #expect(HarnessGoToFolder.singleIndex(of: "Go", in: ["Go", "Cancel", "Go"]) == nil, "two are a question, never the first")
        #expect(HarnessGoToFolder.singleIndex(of: "Go", in: ["go", "Go "]) == nil, "titles match exactly")
        #expect(!HarnessGoToFolder.isPanelShowing(functionRowTitles: ["Cancel"]), "an alert's Cancel is not the panel")
    }

    // MARK: Arriving

    @Test func arrivingIsTheFrontWindowTurningIntoTheFolder() {
        let path = "/Applications/Journey of pro/Heyclicky/scripts"
        let before = HarnessGoToFolder.WindowReading(title: "mybookpro", document: nil)
        #expect(HarnessGoToFolder.arrival(at: path, home: "/Users/o", before: before,
                                         now: .init(title: "scripts", document: nil)) != nil)
        // Only the desktop before: Go to Folder opens a new window, and that is arriving too.
        #expect(HarnessGoToFolder.arrival(at: path, home: "/Users/o", before: nil, now: .init(title: "scripts", document: nil)) != nil)
        #expect(HarnessGoToFolder.arrival(at: path, home: "/Users/o", before: before, now: before) == nil)
        #expect(HarnessGoToFolder.arrival(at: path, home: "/Users/o", before: before, now: .init(title: "Go to Folder", document: nil)) == nil)
        #expect(HarnessGoToFolder.arrival(at: path, home: "/Users/o", before: before, now: nil) == nil)
    }

    /// A window already titled "scripts" may be another folder of that name: the
    /// title alone is not evidence then, the window's document is.
    @Test func aWindowAlreadyOfThatNameArrivesOnlyByItsDocument() {
        let path = "/Applications/Journey of pro/Heyclicky/scripts"
        let before = HarnessGoToFolder.WindowReading(title: "scripts", document: "file:///Users/o/scripts/")
        #expect(HarnessGoToFolder.arrival(at: path, home: "/Users/o", before: before,
                                         now: .init(title: "scripts", document: "file:///Users/o/scripts/")) == nil)
        #expect(HarnessGoToFolder.arrival(at: path, home: "/Users/o", before: before,
                                         now: .init(title: "scripts", document: "file:///Applications/Journey%20of%20pro/Heyclicky/scripts/")) != nil)
        #expect(HarnessGoToFolder.arrival(at: "~/Downloads", home: "/Users/o", before: nil,
                                         now: .init(title: nil, document: "file:///Users/o/Downloads/")) != nil)
        #expect(HarnessGoToFolder.arrival(at: "/", home: "/Users/o", before: nil, now: .init(title: "Macintosh HD", document: nil)) == nil,
                "the root has no predictable title")
    }

    // MARK: The wire

    @Test func theVerbNeedsAPathAndTheAppItActsIn() {
        guard case .failure(.missingField("expectApp")) = HarnessPolicy.decode(line: line(["verb": "goToFolder", "text": "~/Downloads"])) else {
            Issue.record("no expectApp must refuse"); return
        }
        guard case .failure(.missingField("text")) = HarnessPolicy.decode(line: line(["verb": "goToFolder", "expectApp": "Finder"])) else {
            Issue.record("no path must refuse"); return
        }
        for bad in ["Downloads", "/tmp\n", String(repeating: "/a", count: 513)] {
            guard case .failure(.invalidField(field: "text", _)) = HarnessPolicy.decode(
                line: line(["verb": "goToFolder", "text": bad, "expectApp": "Finder"])) else {
                Issue.record("must refuse \(bad.prefix(12).debugDescription)"); continue
            }
        }
        let ok = try? HarnessPolicy.decode(line: line(["verb": "goToFolder", "text": "~/Downloads", "expectApp": "com.apple.finder"])).get()
        #expect(ok?.verb == .goToFolder)
        #expect(ok?.text == "~/Downloads")
        #expect(ok?.title == "~/Downloads", "the audit line names where it went")
    }

    /// Mutating for the kill switch, policy and audit; it writes into a field,
    /// so secure input hands over; and a read-only task may run it (owner 2026-10-11).
    @Test func itIsGuardedAsMutatingButAllowedReadOnly() {
        #expect(HarnessVerb.goToFolder.isMutating)
        #expect(HarnessVerb.goToFolder.elementAction == nil)
        #expect(HarnessPolicy.killSwitchRefusal(verb: .goToFolder, killSwitchPresent: true) != nil)
        let secure = SecureInputState(isOn: true, holderPID: nil, holderName: nil, holderIsFrontmost: true)
        #expect(HarnessPolicy.handOverRefusal(verb: .goToFolder, secureInput: secure) != nil)
        #expect(AgentLoop.readOnlyRefusal(["verb": "goToFolder", "text": "~/Downloads", "expectApp": "com.apple.finder"],
                                          focusedField: { nil }) == nil)
        // Nothing else widened: typing into a non-search field is still refused.
        #expect(AgentLoop.readOnlyRefusal(["verb": "type", "text": "~/Downloads", "target": "focused"],
                                          focusedField: { .init(role: "AXTextField", subrole: nil, labels: []) }) != nil)
    }

    // MARK: The tool

    @Test func goToFolderIsAnActingToolSentAsTheVerbInFinder() throws {
        #expect(RealtimeVoiceVerbs.allToolNames.contains("go_to_folder"))
        #expect(RealtimeVoiceVerbs.isActingTool("go_to_folder"))
        #expect(AgentPlan.stepTools.contains("go_to_folder"))
        let call = RealtimeToolCall.parsed(callID: "g", name: "go_to_folder", arguments: ["folder": " ~/Downloads "])
        #expect(call.text == "~/Downloads")
        let request = try JSONSerialization.jsonObject(with: Data(try RealtimeOpenAppTool.harnessRequestLine(for: call).get().utf8)) as? [String: Any]
        #expect(request?["verb"] as? String == "goToFolder")
        #expect(request?["text"] as? String == "~/Downloads")
        #expect(request?["expectApp"] as? String == "com.apple.finder")
        guard case .failure(let refusal) = RealtimeOpenAppTool.harnessRequestLine(
            for: RealtimeToolCall.parsed(callID: "g", name: "go_to_folder", arguments: [:])) else {
            Issue.record("no folder must refuse before the harness"); return
        }
        #expect(refusal.error == "missingFolder")
        #expect(AgentPlan.precheck([["tool": "go_to_folder"]]) != nil)
        #expect(AgentPlan.precheck([["tool": "go_to_folder", "folder": "~/Downloads"]]) == nil)
    }

    @Test func aConfirmedGoIsOkAndAnUnavailableOneSaysWhy() async {
        let call = RealtimeToolCall.parsed(callID: "g", name: "go_to_folder", arguments: ["folder": "~/Downloads"])
        let went = await RealtimeOpenAppTool.dispatch(call, answer: { _ in
            line(["ok": true, "verification": ["status": "confirmed", "evidence": "the front window is now \"Downloads\""]]) })
        #expect(went.result["ok"] as? Bool == true)
        #expect(went.result["verification"] as? String == "confirmed")
        let failed = await RealtimeOpenAppTool.dispatch(call, answer: { _ in
            line(["ok": false, "error": "goToFolderUnavailable", "message": "no Go to Folder panel"]) })
        #expect(failed.result["error"] as? String == "goToFolderUnavailable")
        #expect(JarvisNotchReason.byErrorCode["goToFolderUnavailable"] != nil)
        #expect(JarvisNotchReason.byErrorCode["notFinder"] != nil)
    }
}
