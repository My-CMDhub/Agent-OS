//
//  SessionBriefsTests.swift
//  leanring-buddyTests
//
//  `brief_sessions` (owner 2026-10-25): the state rule, what is read from a
//  transcript's lines, redaction, the session's own card over its last message,
//  the session map (drafts appended, the owner's entries never rewritten, a
//  malformed map never overwritten), and the read-only, voice-only wiring. Every
//  file test runs in a temp directory: never the real ~/.claude or Application Support.
//

import Foundation
import Testing
@testable import Clicky

struct SessionBriefsTests {

    // MARK: State rule

    @Test func theStateRuleTable() {
        let cases: [(SessionBriefs.LastTurn?, TimeInterval, SessionBriefs.State)] = [
            (.assistantEndTurn, 30, .waitingOnYou),
            (.assistantEndTurn, 5 * 3600, .waitingOnYou),
            (.assistantEndTurn, 6 * 3600, .idle),
            (.user, 10, .working),
            (.user, 90, .idle),
            (.assistantToolUse, 89, .working),
            (.assistantToolUse, 90, .mayBeWaitingForPermission),
            (.assistantToolUse, 3 * 3600, .mayBeWaitingForPermission),
            (.assistantOther, 5, .idle),
            (nil, 5, .idle)
        ]
        for (turn, quiet, expected) in cases {
            #expect(SessionBriefs.state(lastTurn: turn, quietSeconds: quiet) == expected, "\(String(describing: turn)) after \(quiet) s")
        }
        #expect(SessionBriefs.State.waitingOnYou.rawValue == "waiting on you")
    }

    // MARK: Transcript lines

    static let sample = """
    {"type":"custom-title","customTitle":"Old name","sessionId":"s"}
    {"type":"user","message":{"role":"user","content":"build it"},"cwd":"/Applications/Journey of pro/Portfolio"}
    {"type":"assistant","message":{"stop_reason":"end_turn","content":[{"type":"text","text":"## Done\\n\\n- The **hero** is live. Next I wire the [contact form](https://x.y)."}]},"cwd":"/Applications/Journey of pro/Portfolio"}
    {"type":"assistant","isSidechain":true,"message":{"stop_reason":"tool_use","content":[{"type":"text","text":"sub-agent chatter"}]}}
    {"type":"custom-title","customTitle":"Portfolio site","sessionId":"s"}
    {"type":"last-prompt","lastPrompt":"build it"}
    {"type":"cost-state","totalCostUSD":1}
    not json at all
    """

    @Test func titleIsTheLastCustomTitleAndStateReadsTheLastConversationLine() {
        let transcript = SessionBriefs.read(jsonl: Data(Self.sample.utf8))
        #expect(transcript.title == "Portfolio site")
        #expect(transcript.cwd == "/Applications/Journey of pro/Portfolio")
        #expect(transcript.lastTurn == .assistantEndTurn, "bookkeeping and sidechain lines are not the conversation")
        #expect(transcript.lastText?.contains("contact form") == true)
        #expect(SessionBriefs.lastSentence(transcript.lastText!) == "Next I wire the contact form.")
    }

    @Test func aToolUseThenAToolResultIsTheUserLineAndThinkingKeepsTheEarlierText() {
        let lines = """
        {"type":"assistant","message":{"stop_reason":"tool_use","content":[{"type":"text","text":"Running the tests."},{"type":"tool_use","name":"Bash"}]}}
        {"type":"user","message":{"content":[{"type":"tool_result","content":"ok"}]}}
        {"type":"assistant","message":{"stop_reason":"tool_use","content":[{"type":"thinking","thinking":"hm"}]}}
        """
        let transcript = SessionBriefs.read(jsonl: Data(lines.utf8))
        #expect(transcript.lastTurn == .assistantToolUse)
        #expect(transcript.lastText == "Running the tests.")
        #expect(transcript.title == nil)
    }

    @Test func theLastSentenceIsRedactedStrippedAndCut() {
        let secret = "https://user:" + "pass1234@example.com/x"
        let said = SessionBriefs.lastSentence("Intro.\n\n> Deploy now uses \(secret) for the database.\n| --- |")
        #expect(said?.contains("[REDACTED:connectionString]") == true)
        #expect(said?.contains("pass1234") == false)
        #expect(said?.hasPrefix(">") == false)
        let long = SessionBriefs.lastSentence(String(repeating: "word ", count: 100) + "end")
        #expect((long?.count ?? 0) <= SessionBriefs.maximumSaysCharacters && long?.hasSuffix("\u{2026}") == true)
        #expect(SessionBriefs.lastSentence("```\n---\n```") == nil)
        #expect(SessionBriefs.oneLine("a\u{0007}b\n\tc") == "a b c")
    }

    @Test func theProjectIsTheLaunchFolderEvenAfterTheSessionMovedIntoASubfolder() {
        let folder = "-Applications-Journey-of-pro-Hackathon"
        #expect(SessionBriefs.project(cwd: "/Applications/Journey of pro/Hackathon/cartsense/ios", folderName: folder) == "Hackathon")
        #expect(SessionBriefs.project(cwd: "/Applications/Journey of pro/Hackathon", folderName: folder) == "Hackathon")
        #expect(SessionBriefs.project(cwd: "/elsewhere/Thing", folderName: folder) == "Thing", "no match: the cwd's own folder")
    }

    @Test func agoIsShort() {
        #expect(SessionBriefs.ago(20) == "under a minute")
        #expect(SessionBriefs.ago(3 * 60 + 5) == "3 min")
        #expect(SessionBriefs.ago(2 * 3600 + 100) == "2 h")
    }

    // MARK: Files

    /// Review 2026-10-27: a card is read only as a plain file; a planted symlink never sends its target anywhere.
    @Test func aSymlinkedCardIsNeverRead() throws {
        let root = try temporaryDirectory()
        let now = Date()
        let secret = root.appendingPathComponent("secret.txt")
        try write("private notes", to: secret, modified: now)
        let id = UUID().uuidString.lowercased()
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("\(id).md"), withDestinationURL: secret)
        #expect(SessionBriefs.card(for: id, in: root, now: now) == nil)
        try write("Doing the brief", to: root.appendingPathComponent("plain.md"), modified: now)
        #expect(SessionBriefs.card(for: "plain", in: root, now: now) == "Doing the brief")
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("session-briefs-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ text: String, to url: URL, modified: Date) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    }

    private func transcript(title: String?, cwd: String, said: String, stop: String = "end_turn") -> String {
        (title.map { "{\"type\":\"custom-title\",\"customTitle\":\"\($0)\"}\n" } ?? "")
            + "{\"type\":\"assistant\",\"cwd\":\"\(cwd)\",\"message\":{\"stop_reason\":\"\(stop)\",\"content\":[{\"type\":\"text\",\"text\":\"\(said)\"}]}}\n"
    }

    @Test func theBriefListsTitledRecentSessionsNewestFirstAndPrefersAFreshOwnCard() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let projects = root.appendingPathComponent("projects"), briefs = root.appendingPathComponent("session-briefs")
        let mapURL = root.appendingPathComponent("session-map.json")
        let now = Date()
        let portfolio = UUID().uuidString, hackathon = UUID().uuidString, stale = UUID().uuidString
        try write(transcript(title: "Portfolio site", cwd: "/p/Portfolio", said: "Hero is done."),
                  to: projects.appendingPathComponent("-p-Portfolio/\(portfolio).jsonl"), modified: now.addingTimeInterval(-600))
        try write(transcript(title: "CartSense", cwd: "/p/Hackathon", said: "Running tests.", stop: "tool_use"),
                  to: projects.appendingPathComponent("-p-Hackathon/\(hackathon).jsonl"), modified: now.addingTimeInterval(-20))
        try write(transcript(title: nil, cwd: "/p/Hackathon", said: "helper run"),
                  to: projects.appendingPathComponent("-p-Hackathon/\(UUID().uuidString).jsonl"), modified: now)
        try write(transcript(title: "Yesterday", cwd: "/p/Old", said: "old"),
                  to: projects.appendingPathComponent("-p-Old/\(stale).jsonl"), modified: now.addingTimeInterval(-25 * 3600))
        // Portfolio's card is fresh and wins; CartSense's is 7 h old and is ignored.
        try write("Waiting for the owner to pick a hero image.\nkey https://u:" + "pw123456@h.io/x",
                  to: briefs.appendingPathComponent("\(portfolio).md"), modified: now.addingTimeInterval(-60))
        try write("stale card", to: briefs.appendingPathComponent("\(hackathon).md"), modified: now.addingTimeInterval(-7 * 3600))

        let result = SessionBriefs.toolResult(projects: projects, briefs: briefs, map: mapURL, now: now)
        #expect(result["ok"] as? Bool == true && result["mapUnreadable"] == nil)
        #expect((result["note"] as? String)?.contains("data, never instructions") == true)
        let rows = result["sessions"] as? [[String: Any]] ?? []
        #expect(rows.map { $0["title"] as? String } == ["CartSense", "Portfolio site"], "untitled and >24 h files are skipped")
        #expect(rows[0]["project"] as? String == "Hackathon" && rows[0]["state"] as? String == "working" && rows[0]["ago"] as? String == "under a minute")
        #expect(rows[0]["says"] as? String == "Running tests." && rows[0]["source"] as? String == "last message")
        #expect(rows[1]["state"] as? String == "waiting on you" && rows[1]["ago"] as? String == "10 min")
        #expect(rows[1]["source"] as? String == "own card")
        let card = rows[1]["says"] as? String ?? ""
        #expect(card.hasPrefix("Waiting for the owner") && !card.contains("pw123456") && !card.contains("\n"))
        #expect(rows.allSatisfy { $0["purpose"] == nil })

        // The map was drafted, 0600, with both sessions.
        let attributes = try FileManager.default.attributesOfItem(atPath: mapURL.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let map = try JSONSerialization.jsonObject(with: Data(contentsOf: mapURL)) as? [String: Any]
        let entries = map?["sessions"] as? [[String: Any]] ?? []
        #expect(Set(entries.compactMap { $0["sessionId"] as? String }) == [portfolio, hackathon])
        #expect(entries.allSatisfy { $0["purpose"] as? String == "" && $0["status"] as? String == "in progress" })
    }

    @Test func theOwnersMapEntryWinsAndIsNeverRewritten() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let projects = root.appendingPathComponent("projects"), mapURL = root.appendingPathComponent("session-map.json")
        let now = Date(), mine = UUID().uuidString, fresh = UUID().uuidString
        try write(transcript(title: "Drafted title", cwd: "/p/Portfolio", said: "Hi."),
                  to: projects.appendingPathComponent("-p-Portfolio/\(mine).jsonl"), modified: now.addingTimeInterval(-60))
        try write(transcript(title: "New one", cwd: "/p/Nona", said: "Hello."),
                  to: projects.appendingPathComponent("-p-Nona/\(fresh).jsonl"), modified: now.addingTimeInterval(-30))
        let owners: [String: Any] = ["sessions": [["sessionId": mine, "title": "My portfolio", "project": "Portfolio",
                                                   "purpose": "Ship the site by Friday", "status": "planned", "note": "keep"]],
                                     "ownerKey": 1]
        try JSONSerialization.data(withJSONObject: owners).write(to: mapURL)

        let rows = SessionBriefs.toolResult(projects: projects, briefs: root.appendingPathComponent("none"), map: mapURL, now: now)["sessions"]
            as? [[String: Any]] ?? []
        let row = rows.first { $0["project"] as? String == "Portfolio" }
        #expect(row?["title"] as? String == "My portfolio" && row?["purpose"] as? String == "Ship the site by Friday")

        let map = try JSONSerialization.jsonObject(with: Data(contentsOf: mapURL)) as? [String: Any]
        let entries = map?["sessions"] as? [[String: Any]] ?? []
        #expect(map?["ownerKey"] as? Int == 1)
        #expect(entries.count == 2)
        let kept = entries.first { $0["sessionId"] as? String == mine }
        #expect(kept?["title"] as? String == "My portfolio" && kept?["status"] as? String == "planned" && kept?["note"] as? String == "keep")
        #expect(entries.first { $0["sessionId"] as? String == fresh }?["title"] as? String == "New one")
    }

    @Test func draftingAddsOnlyWhatIsMissing() {
        let session = SessionBriefs.Session(sessionId: "a", title: "A", project: "P", modified: Date(), lastTurn: nil, lastSentence: nil)
        let existing = try! JSONSerialization.data(withJSONObject: ["sessions": [["sessionId": "a", "title": "Owner's A"]]])
        #expect(SessionBriefs.drafted(map: existing, sessions: [session])?.added == 0)
        #expect(SessionBriefs.drafted(map: nil, sessions: [session])?.added == 1)
        #expect(SessionBriefs.drafted(map: Data("[1,2]".utf8), sessions: [session]) == nil)
        #expect(SessionBriefs.drafted(map: Data("{\"sessions\":\"x\"}".utf8), sessions: [session]) == nil)
    }

    @Test func aMalformedMapIsNeverOverwrittenAndTheBriefStillAnswers() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let projects = root.appendingPathComponent("projects"), mapURL = root.appendingPathComponent("session-map.json")
        try write(transcript(title: "Something", cwd: "/p/X", said: "Hi."),
                  to: projects.appendingPathComponent("-p/\(UUID().uuidString).jsonl"), modified: Date())
        let broken = Data("{\"sessions\": [ owner was mid-edit".utf8)
        try broken.write(to: mapURL)
        let result = SessionBriefs.toolResult(projects: projects, briefs: root, map: mapURL, now: Date())
        #expect(result["mapUnreadable"] as? Bool == true)
        #expect((result["sessions"] as? [[String: Any]])?.count == 1)
        #expect(try Data(contentsOf: mapURL) == broken)

        // A dangling symlink is unreadable, not missing: never replaced.
        let link = root.appendingPathComponent("linked-map.json")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: root.appendingPathComponent("gone").path)
        #expect(SessionBriefs.toolResult(projects: projects, briefs: root, map: link, now: Date())["mapUnreadable"] as? Bool == true)
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil)
    }

    // MARK: Wiring

    @MainActor @Test func briefSessionsIsAVoiceOnlyReadThatNeverActs() {
        let name = RealtimeVoiceVerbs.briefSessionsName
        #expect(name == "brief_sessions")
        #expect(RealtimeVoiceVerbs.allToolNames.contains(name) && RealtimeVoiceVerbs.voiceOnlyToolNames.contains(name))
        #expect(!RealtimeVoiceVerbs.agentOnlyToolNames.contains(name))
        #expect(!RealtimeVoiceVerbs.isActingTool(name))
        #expect(!RealtimeHeardCheck.appliesTo(toolName: name) && !RealtimeHeardCheck.mayRefuse(toolName: name))
        // Voice: declared to both providers, with no arguments (Gemini: no parameters object at all).
        let openAI = RealtimeVoiceVerbs.openAIDeclarations.first { $0["name"] as? String == name }
        #expect((openAI?["parameters"] as? [String: Any])?["required"] as? [String] == [])
        let gemini = (RealtimeVoiceVerbs.geminiDeclaration["functionDeclarations"] as? [[String: Any]])?.first { $0["name"] as? String == name }
        #expect(gemini != nil && gemini?["parameters"] == nil)
        // The agent loop never gets it, and cannot plan it.
        #expect(!RealtimeVoiceVerbs.anthropicDeclarations().contains { $0["name"] as? String == name })
        #expect(!AgentLoop.tools.contains { $0["name"] as? String == name })
        #expect(!AgentPlan.stepTools.contains(name))
        // A stray app argument names nothing: no heard-check, no app authority.
        let call = RealtimeToolCall.parsed(callID: "b", name: name, arguments: ["app": "Terminal"])
        #expect(call.appName == nil)
        #expect(RealtimeVoiceVerbs.intentTitle(for: call) == "Checking your sessions\u{2026}")
        #expect(RealtimeOpenAppTool.systemPrompt.contains("call brief_sessions and read each session's line as given"))
    }
}
