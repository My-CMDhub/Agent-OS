//
//  HandsVoiceTests.swift
//  leanring-buddyTests
//
//  The voice half of "hands that work" (H2, 2026-10-02), each test named for
//  the live scenario rows it answers (docs/superpowers/specs/live-scenarios.csv):
//  names resolved on the live screen, press_element as a click, open_url and
//  its site check, the heard check's content and web-address fixes, underPointer
//  only when said, receipts corrected aloud, pointing when telling, and the
//  OpenAI follow-up that came back empty. Pure halves and the connection's own
//  event handling; fixtures are SYNTHETIC.
//

import CoreGraphics
import Foundation
import Testing
@testable import Clicky

@MainActor
struct HandsVoiceTests {

    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let chromeBundle = "com.google.Chrome"

    private func frameJSON(_ frame: CGRect) -> [String: Any] {
        ["x": frame.minX, "y": frame.minY, "w": frame.width, "h": frame.height]
    }

    private func element(_ role: String, _ name: String?, _ frame: CGRect, subrole: String? = nil, actions: [String] = ["AXPress"],
                         source: String = "title", parent: Int? = nil) -> [String: Any] {
        ["role": role, "subrole": subrole ?? NSNull(), "name": name ?? NSNull(), "nameIsPlausibleLabel": true, "actions": actions,
         "nameSource": source, "parent": parent ?? NSNull(), "frame": frameJSON(frame)]
    }

    /// A Heroku-like signup page in Chrome: a Log In button, a Log in link,
    /// four labelled fields, a Video button.
    private var signupSnapshot: [String: Any] {
        ["ok": true, "bundleIdentifier": chromeBundle, "walkStopReasons": [String](), "windowFrame": frameJSON(screen), "elements": [
            element("AXWindow", "Heroku", screen),
            element("AXButton", "Log In", CGRect(x: 1200, y: 840, width: 80, height: 30)),
            element("AXTextField", "First name", CGRect(x: 500, y: 600, width: 300, height: 30), actions: [], source: "placeholder"),
            element("AXTextField", "Last name", CGRect(x: 500, y: 550, width: 300, height: 30), actions: [], source: "placeholder"),
            element("AXButton", "Sign Up", CGRect(x: 500, y: 400, width: 120, height: 36)),
            element("AXLink", "Log in", CGRect(x: 700, y: 300, width: 60, height: 16)),
            element("AXButton", "Video", CGRect(x: 300, y: 700, width: 60, height: 24)),
            element("AXStaticText", "Get started on Heroku today", CGRect(x: 500, y: 700, width: 300, height: 24), actions: [], source: "value")
        ]]
    }

    private func candidates(_ name: String) -> [RealtimeScreenCandidate] {
        RealtimeScreenVerbs.liveCandidates(named: name, fromSnapshotResponse: signupSnapshot, screens: [screen])
    }

    // MARK: 2. A name is looked up on the live screen (rows 5, 10, 11, 20, 22)

    @Test func aSpokenNameMeansTheVisibleElementExactlyThenNormalised() {
        #expect(RealtimeScreenVerbs.normalisedName("Log In") == "login")
        #expect(RealtimeScreenVerbs.normalisedName("New Agent (\u{21E7}\u{2318}L)") == "newagent")
        #expect(RealtimeScreenVerbs.normalisedName("Wi\u{2011}Fi") == RealtimeScreenVerbs.normalisedName("wifi"))
        // Exact wins: "Log In" is the button even though the link normalises the same.
        #expect(candidates("Log In").map(\.role) == ["AXButton"])
        // Row 5: "login" was refused against an offered "Log In". Normalised, it is BOTH: asked, never guessed.
        #expect(Set(candidates("login").map(\.role)) == ["AXButton", "AXLink"])
        #expect(candidates("first name").map(\.name) == ["First name"])
        // Never a partial match, never a hidden one.
        #expect(candidates("first").isEmpty)
        #expect(candidates("Heroku").isEmpty)
    }

    private func resolve(_ call: RealtimeToolCall, heard: String? = nil, offer: [RealtimeScreenCandidate]? = nil,
                         pointer: RealtimeScreenTarget? = nil, lookups: LookupCount = LookupCount()) async -> Result<RealtimeScreenTarget, RealtimeToolRefusal> {
        let snapshot = signupSnapshot
        let screen = self.screen
        let chrome = chromeBundle
        return await RealtimeOpenAppTool.resolveScreenTarget(
            call: call, thisTurn: offer.map { RealtimeStandingOffer(candidates: [], app: chrome, uptime: 1_000, elements: $0) },
            previousTurn: nil, followUpConfirmed: nil, confirmedByYes: false, now: 1_000, screenshotDisplay: screen,
            keyDownPointer: pointer, heard: heard,
            lookUp: { name in
                lookups.count += 1
                return .success(RealtimeScreenLookup(candidates: RealtimeScreenVerbs.liveCandidates(named: name, fromSnapshotResponse: snapshot,
                                                                                                    screens: [screen]), app: chrome))
            },
            hitTest: { _ in .nothing })
    }

    final class LookupCount: @unchecked Sendable { var count = 0 }

    @Test func pressTypeAndPointByNameNeedNoOfferThisTurn() async throws {
        // Row 10 / 22: type into a field found a turn earlier — now found live.
        let type = RealtimeToolCall(callID: "t", name: "type_text", appName: "Google Chrome", elementName: "First name", text: "Dhruv")
        let field = try await resolve(type).get()
        #expect(field.source == .liveName && field.candidate?.name == "First name" && field.app == chromeBundle)
        // Row 11: point at First name with no find this turn.
        let point = RealtimeToolCall(callID: "p", name: "point_at", appName: "Google Chrome", elementName: "First name")
        #expect(try await resolve(point).get().candidate?.role == "AXTextField")
        // Several: listed for the model to ask, with where each is.
        let press = RealtimeToolCall(callID: "b", name: "press_element", appName: "Google Chrome", elementName: "login")
        guard case .failure(let several) = await resolve(press) else { Issue.record("pressed one of two"); return }
        #expect(several.error == "elementAmbiguous" && several.message.contains("button \"Log In\"") && several.message.contains("link \"Log in\""))
        // None: notFound, and the model is told how to look.
        guard case .failure(let none) = await resolve(RealtimeToolCall(callID: "n", name: "press_element", appName: "Google Chrome",
                                                                        elementName: "Start a post")) else { Issue.record("pressed nothing"); return }
        #expect(none.error == "elementNotFound" && none.message.contains("find_on_screen"))
        // An offer this turn that holds the exact name is still used first: no live read.
        let offered = RealtimeScreenCandidate(name: "Sign Up", role: "AXButton", frame: CGRect(x: 1, y: 1, width: 9, height: 9), position: "x")
        let lookups = LookupCount()
        let fromOffer = try await resolve(RealtimeToolCall(callID: "o", name: "press_element", appName: "Google Chrome", elementName: "Sign Up"),
                                          offer: [offered], lookups: lookups).get()
        #expect(fromOffer.source == .thisTurn && fromOffer.candidate == offered && lookups.count == 0)
    }

    // Rows 2 and 19: underPointer sent for "let's point it" and "in Google Chrome".
    @Test func underPointerIsOnlyForWhatTheOwnerPointedAt() async throws {
        let pointer = RealtimeScreenTarget(candidate: candidates("Video").first, point: CGPoint(x: 330, y: 712), app: chromeBundle, source: .underPointer)
        let call = RealtimeToolCall(callID: "u", name: "point_at", appName: nil, underPointer: true)
        for said in ["All right, let's point it", "Non, in Google Chrome."] {
            guard case .failure(let refusal) = await resolve(call, heard: said, pointer: pointer) else { Issue.record("aimed at the pointer: \(said)"); continue }
            #expect(refusal.error == "underPointerNotSaid")
        }
        for said in ["press this one", "what's here?", "the thing where my cursor is", "under my mouse"] {
            #expect(try await resolve(call, heard: said, pointer: pointer).get() == pointer, "\(said)")
        }
        // No transcript: as before, the pointer.
        #expect(try await resolve(call, heard: nil, pointer: pointer).get() == pointer)
    }

    // MARK: 1. press_element is a click; type_text clicks into its field; open_url (rows 13, 14, 23, 29)

    @Test func pressElementGoesToTheClickVerbAndAFieldIsClickedItself() throws {
        func line(_ candidate: RealtimeScreenCandidate) throws -> [String: Any] {
            let line = try RealtimeOpenAppTool.harnessRequestLine(
                for: RealtimeToolCall(callID: "c", name: "press_element", appName: "Google Chrome", elementName: candidate.name),
                expectApp: chromeBundle,
                screenTarget: RealtimeScreenTarget(candidate: candidate, point: CGPoint(x: candidate.frame.midX, y: candidate.frame.midY),
                                                   app: chromeBundle, source: .liveName)).get()
            return (try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]) ?? [:]
        }
        let field = try #require(candidates("First name").first)
        #expect(!field.pressable)
        let clickField = try line(field)
        #expect(clickField["verb"] as? String == "click" && clickField["title"] as? String == "First name" && clickField["labelTitle"] == nil)
        #expect(clickField["requireAtPoint"] as? Bool == true)
        let button = try line(try #require(candidates("Log In").first))
        #expect(button["verb"] as? String == "click" && button["role"] as? String == "AXButton")
        guard case .success(let decoded) = HarnessPolicy.decode(line: String(decoding: try JSONSerialization.data(withJSONObject: clickField), as: UTF8.self)) else {
            Issue.record("the click line did not decode"); return
        }
        #expect(decoded.verb == .click)
    }

    @Test func openURLIsATool() throws {
        let declared = RealtimeVoiceVerbs.openAIDeclarations.first { $0["name"] as? String == "open_url" }
        #expect((declared?["parameters"] as? [String: Any])?["required"] as? [String] == ["url"])
        let calls = RealtimeOpenAppTool.parseGemini(["toolCall": ["functionCalls": [
            ["id": "g", "name": "open_url", "args": ["url": "https://www.linkedin.com/", "app": "Google Chrome"]]]]])
        #expect(calls.first?.url == "https://www.linkedin.com/" && calls.first?.appName == "Google Chrome")
        let line = try RealtimeOpenAppTool.harnessRequestLine(for: try #require(calls.first)).get()
        #expect(line == #"{"app":"Google Chrome","url":"https:\/\/www.linkedin.com\/","verb":"openURL"}"#)
        let defaultBrowser = try RealtimeOpenAppTool.harnessRequestLine(
            for: RealtimeToolCall(callID: "d", name: "open_url", appName: nil, url: "https://example.com/")).get()
        #expect(defaultBrowser == #"{"url":"https:\/\/example.com\/","verb":"openURL"}"#)
        guard case .failure(let missing) = RealtimeOpenAppTool.harnessRequestLine(for: RealtimeToolCall(callID: "m", name: "open_url", appName: nil)) else {
            Issue.record("opened nothing"); return
        }
        #expect(missing.error == "missingURL")
        // The trace keeps the host, never a path or query.
        let logged = RealtimeDecisionTrace.loggedArguments(for: RealtimeToolCall(callID: "l", name: "open_url", appName: nil,
                                                                                 url: "https://www.google.com/search?q=my+address"))
        #expect(logged["urlHost"] as? String == "www.google.com" && logged["url"] == nil)
        #expect(RealtimeVoiceVerbs.isActingTool("open_url") && RealtimeVoiceVerbs.allToolNames.contains("open_url"))
    }

    @Test func openURLNeedsTheOwnersWordsToNameTheSite() {
        #expect(RealtimeHeardCheck.siteName(of: "https://www.linkedin.com/feed/") == "linkedin")
        #expect(RealtimeHeardCheck.siteName(of: "https://www.bbc.co.uk/news") == "bbc")
        #expect(RealtimeHeardCheck.siteName(of: "https://mail.google.com/") == "google")
        #expect(RealtimeHeardCheck.heardSite("open my LinkedIn and guide me", siteName: "linkedin"))
        #expect(RealtimeHeardCheck.heardSite("open linked in in chrome", siteName: "linkedin"))
        #expect(!RealtimeHeardCheck.heardSite("open my profile", siteName: "linkedin"))
        #expect(!RealtimeHeardCheck.heardSite("open the box", siteName: "x"))
        #expect(RealtimeHeardCheck.siteRefusal(transcript: "Open LinkedIn in Chrome", url: "https://www.linkedin.com/") == nil)
        #expect(RealtimeHeardCheck.siteRefusal(transcript: "open my mail", url: "https://evil.example/")?["error"] as? String == "heardSiteMismatch")
        #expect(RealtimeHeardCheck.siteRefusal(transcript: nil, url: "https://www.linkedin.com/")?["error"] as? String == "heardUnavailable")
    }

    // Review 2026-10-02: a redirector passes the site check on its own host, and
    // "don't open evil.com" names the site it forbids.
    @Test func openURLRefusesARedirectAndASiteTheOwnerSaidNotToOpen() {
        func error(_ heard: String, _ url: String) -> String? { RealtimeHeardCheck.siteRefusal(transcript: heard, url: url)?["error"] as? String }
        for url in ["https://www.linkedin.com/redir/redirect?url=https://evil.example/", "https://www.linkedin.com/redir?u=HTTPS%3A%2F%2Fevil.example",
                    "https://www.linkedin.com/feed/#next=http://evil.example"] {
            #expect(error("open linkedin", url) == "urlCarriesAnotherAddress", "\(url)")
        }
        #expect(error("open linkedin", "https://www.linkedin.com/search/results/?keywords=swift") == nil)
        #expect(error("don't open evil.com", "https://evil.com/") == "heardSiteMismatch")
        #expect(error("do not go to evil dot com", "https://evil.com/") == "heardSiteMismatch")
        #expect(error("don\u{2019}t open evil.com, open linkedin", "https://evil.com/") == "heardSiteMismatch")
        #expect(error("don't open evil.com, open linkedin", "https://www.linkedin.com/") == nil)
        #expect(error("No, open LinkedIn", "https://www.linkedin.com/") == nil)      // C1AAF61A's turn: "no" is its own clause
    }

    // The call site (RealtimeVoiceConnection `heard?.refusal ?? siteRefusal`) is the only
    // defence against a URL a page planted: open_url names no app, so no heard check runs.
    @Test func aSiteTheOwnerDidNotNameNeverReachesTheHarness() async throws {
        final class Requests: @unchecked Sendable {
            private let lock = NSLock()
            private var lines: [String] = []
            func add(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
            var count: Int { lock.lock(); defer { lock.unlock() }; return lines.count }
        }
        let requests = Requests()
        let connection = RealtimeVoiceConnection(stack: .geminiLive, harnessAnswer: { line in requests.add(line); return "{}" })
        func openURL(_ url: String, heard: String) async throws -> String? {
            try await connection.beginTurn()
            try await connection.endTurn()
            connection.handle(["serverContent": ["inputTranscription": ["text": heard]]], arrivalUptime: ProcessInfo.processInfo.systemUptime)
            connection.handle(["toolCall": ["functionCalls": [["id": "u", "name": "open_url", "args": ["url": url]]]]],
                              arrivalUptime: ProcessInfo.processInfo.systemUptime)
            let turn = connection.turn
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            while turn.decisions.first?.dispatch == nil, ProcessInfo.processInfo.systemUptime < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            return turn.decisions.first?.dispatch?.result["error"] as? String
        }
        #expect(try await openURL("https://evil.example/", heard: "open linkedin") == "heardSiteMismatch")
        #expect(try await openURL("https://www.linkedin.com/redir?url=https://evil.example/", heard: "open linkedin") == "urlCarriesAnotherAddress")
        #expect(requests.count == 0)
        // The control that must move: the owner's own site reaches the harness.
        _ = try await openURL("https://www.linkedin.com/", heard: "open linkedin")
        #expect(requests.count == 1)
    }

    // MARK: 3. The heard check (rows 15, 18, 28)

    private func app(_ path: String) -> RealtimeVoiceVerbs.AppName {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        return RealtimeVoiceVerbs.AppName(name: url.deletingPathExtension().lastPathComponent, url: url, isFileName: true)
    }

    private var installed: [RealtimeVoiceVerbs.AppName] {
        [app("/Applications/Google Chrome.app"), app("/Users/o/Applications/LinkedIn.app"), app("/Applications/Cursor.app"),
         app("/System/Applications/Utilities/Terminal.app")]
    }

    private func outcome(_ heard: String, named: String, tool: String, content: String = "", browser: Bool = false,
                         frontmost: String? = "/Applications/Google Chrome.app") -> RealtimeHeardCheck.Outcome {
        RealtimeHeardCheck.decide(transcript: heard, named: named, among: installed, toolName: tool,
                                  frontmostApp: frontmost.map { URL(fileURLWithPath: $0, isDirectory: true) },
                                  contentWords: RealtimeHeardCheck.contentTokens(content), namedIsBrowser: browser).outcome
    }

    @Test func typedTextAndWebAddressesAreNotAppsAndABrowserHoldsItsPages() {
        // Row 15: "search for LinkedIn" typed into Chrome was refused as the LinkedIn web app.
        #expect(outcome("Can you type Can you search for LinkedIn here?", named: "Google Chrome", tool: "type_text",
                        content: "linkedin.com") == .noAppHeard)
        #expect(outcome("Can you type Can you search for LinkedIn here?", named: "Google Chrome", tool: "type_text") == .heardNamedMismatch)
        // The content never hides the app the call names.
        #expect(outcome("type Chrome", named: "Google Chrome", tool: "type_text", content: "Chrome") == .match)
        // Row 28: "type down linkedin.com" — an address, not the LinkedIn app.
        #expect(RealtimeHeardCheck.withoutWebAddresses("try to type down linkedin.com.").contains("linkedin") == false)
        #expect(RealtimeHeardCheck.withoutWebAddresses("go to linkedin dot com please").contains("linkedin") == false)
        #expect(RealtimeHeardCheck.withoutWebAddresses("Open Cursor. In the panel").contains("Cursor"))
        #expect(outcome("Open again and try to type down linkedin.com.", named: "Google Chrome", tool: "open_app") == .noAppHeard)
        #expect(outcome("open linkedin", named: "Google Chrome", tool: "open_app") == .heardNamedMismatch)
        // Row 18: "LinkedIn within this browser" with Chrome named and in front.
        #expect(outcome("I would like you to open LinkedIn within this browser.", named: "Google Chrome", tool: "focus_app",
                        browser: true) == .noAppHeard)
        #expect(outcome("I would like you to open LinkedIn within this browser.", named: "Google Chrome", tool: "focus_app") == .heardNamedMismatch)
        // Row 13 stays a match: the named app is in the words, LinkedIn is "in Chrome".
        #expect(outcome("let's open LinkedIn in Chrome and guide me to draft a post", named: "Google Chrome", tool: "open_app") == .match)
        // open_url's site is content too: the browser named, the site said.
        #expect(outcome("open LinkedIn in Chrome", named: "Google Chrome", tool: "open_url",
                        content: "linkedin www.linkedin.com") == .match)
    }

    // MARK: 5. Receipts (rows 15, 16, 33)

    private func decision(_ name: String, ok: Bool, result: [String: Any] = [:]) -> RealtimeToolDecision {
        var full = result
        full["ok"] = ok
        return RealtimeToolDecision(call: RealtimeToolCall(callID: name, name: name, appName: "Google Chrome"), callUptime: 1, offeredBeforeCall: nil,
                                    dispatch: RealtimeToolDispatch(result: full, harnessMilliseconds: 1, waitedForConfirmation: false,
                                                                   harnessResponse: ok ? ["ok": true] : nil))
    }

    @Test func aClaimWithNoReceiptIsCorrectedAloudWithTheReason() {
        // Row 33: "typed" after type_text performFailed.
        let failedType = decision("type_text", ok: false, result: ["error": "performFailed", "message": "the field did not take the text"])
        let correction = RealtimeOpenAppTool.receiptCorrection(transcript: "I've typed your post, sir.", decisions: [failedType])
        #expect(correction?.contains("Correction: that didn't go through") == true)
        #expect(correction?.contains("the field did not take the text") == true)
        #expect(RealtimeOpenAppTool.receiptCorrection(transcript: "I've typed your post, sir.", decisions: [decision("type_text", ok: true)]) == nil)
        #expect(RealtimeOpenAppTool.receiptCorrection(transcript: "That didn't go through, sir.", decisions: [failedType]) == nil)
        // Row 16: "opened" with nothing opened; no tool at all says so.
        #expect(RealtimeOpenAppTool.claimedWithoutReceipt(transcript: "I've opened LinkedIn for you.", okToolNames: ["find_on_screen"]))
        #expect(!RealtimeOpenAppTool.claimedWithoutReceipt(transcript: "I've opened LinkedIn for you.", okToolNames: ["open_url"]))
        #expect(RealtimeOpenAppTool.claimedWithoutReceipt(transcript: "I've opened LinkedIn for you.", okToolNames: ["point_at"]))
        #expect(!RealtimeOpenAppTool.claimedWithoutReceipt(transcript: "Opened a new window.", okToolNames: ["press_menu"]))
        #expect(RealtimeOpenAppTool.receiptCorrection(transcript: "Opened it.", decisions: []) == nil)       // nothing was tried
        #expect(RealtimeOpenAppTool.receiptCorrection(transcript: "Opened it.", decisions: [decision("open_url", ok: false, result: ["error": "openFailed"])])?
            .contains("openFailed") == true)
        #expect(RealtimeOpenAppTool.systemTurnVariant(for: .openAIRealtime) == .textThenCreate)
        #expect(RealtimeOpenAppTool.systemTurnVariant(for: .geminiLive) == .textOnly)
    }

    // Live 2026-10-02: the bare-word check fired on 9 of 100 turns and at least 3 were
    // honest. A correction needs a first-person completion AND a matching tool tried this
    // turn with no receipt. Replies verbatim from voice-transcripts.log.
    @Test func aCorrectionAnswersOnlyAFirstPersonClaimATriedToolDidNotBack() {
        let failedType = decision("type_text", ok: false, result: ["error": "performFailed"])
        let corrected: [(String, [RealtimeToolDecision])] = [
            // 7C47552C: type_text performFailed, then "I've typed out some text".
            ("Very well, sir. The draft window is open and I've typed out some text for your first post. You can review it there and let me "
                + "know when you're ready to share.", [decision("find_on_screen", ok: true), failedType]),
            // 28F7E2CD: refused heardNamedMismatch, then "I've typed" inside a question.
            ("I've typed linkedin dot com into the address bar, but before navigating there: did you mean LinkedIn, the application, or the "
                + "website within Chrome?", [decision("type_text", ok: false, result: ["error": "heardNamedMismatch"])]),
            ("Done, sir.", [decision("press_element", ok: false)]),
            ("Pressed.", [decision("press_element", ok: false)]),
            ("Typed it.", [failedType]),
            ("I have just opened LinkedIn for you.", [decision("open_url", ok: false)])
        ]
        for (reply, decisions) in corrected {
            #expect(RealtimeOpenAppTool.receiptCorrection(transcript: reply, decisions: decisions) != nil, "\(reply)")
        }
        let honest: [(String, [RealtimeToolDecision])] = [
            // 8181F20B, C1AAF61A, A410BC02: no tool tried, and two admit it.
            ("My apologies, sir. I appear to have had trouble typing into that field; the text didn't take. The field has keyboard focus now, "
                + "so you can enter your thoughts directly whenever you're ready.", []),
            ("My apologies, but I can only open installed applications, not specific websites within Chrome. If you navigate to your LinkedIn "
                + "page, I'll be happy to guide you through creating a post. I just need you to pull up the page for me, sir.", []),
            ("Certainly, sir. At the top of your screen, look for the Product menu. Click on that, then move your pointer down to Scheme, and "
                + "select Edit Scheme from the submenu that appears. It should open the settings window. Is that working?", []),
            // Admitted with a tool tried: still nothing to correct.
            ("I appear to have had trouble typing; I typed nothing.", [failedType]),
            ("I wasn't able to, sir. I'm not able to type there.", [failedType]),
            // A2214744 / BF7E385A: future tense after a failed tool.
            ("I understand now, sir; my mistake. To open the AI chat, I believe it's called Toggle Agents. I shall attempt to press that "
                + "button now.", [decision("press_element", ok: false, result: ["error": "notOffered"])]),
            ("Understood. I'll open LinkedIn in the browser. One moment.", [failedType]),
            // 0F755225: the owner opened it, and nothing matching was tried.
            ("You've opened the scheme editor, sir.", [decision("press_element", ok: false)]),
            // Claimed, but the matching tool came back ok; or only an unrelated tool failed.
            ("I've typed it.", [decision("type_text", ok: true)]),
            ("I've typed it.", [decision("press_element", ok: false)]),
            ("Have I typed it correctly?", [failedType]),
            ("It's done and ready in front of you.", [decision("open_url", ok: false)])
        ]
        for (reply, decisions) in honest {
            #expect(RealtimeOpenAppTool.receiptCorrection(transcript: reply, decisions: decisions) == nil, "\(reply)")
        }
    }

    // A410BC02: the correction returned before the pointer. Both run now, correction first.
    @Test func aCorrectionNeverStopsThePointer() async {
        final class Order: @unchecked Sendable { var steps: [String] = [] }
        let order = Order()
        let outcome = await RealtimeOpenAppTool.afterReply(
            transcript: "I've pressed it. Now click Video.", decisions: [decision("press_element", ok: false)],
            sendCorrection: { _ in order.steps.append("correction") },
            pointWhenTelling: { order.steps.append("point"); return "pointed" })
        #expect(order.steps == ["correction", "point"])
        #expect(outcome.correctionSent && outcome.pointed == "pointed")
        let honest = await RealtimeOpenAppTool.afterReply(transcript: "Click Video.", decisions: [], sendCorrection: { _ in order.steps.append("x") },
                                                          pointWhenTelling: { "notFound" })
        #expect(!honest.correctionSent && honest.pointed == "notFound" && !order.steps.contains("x"))
    }

    // Review 2026-10-02: a spoken correction reset the turn, so "yes, that one" after it
    // lost the offer and was judged against the correction's own words.
    @Test func aSystemTurnCarriesTheOwnerTurnsOffersAndWords() async throws {
        let connection = RealtimeVoiceConnection(stack: .geminiLive, harnessAnswer: { _ in "{}" })
        try await connection.beginTurn()
        try await connection.endTurn()
        let owner = connection.turn
        let logIn = RealtimeScreenCandidate(name: "Log In", role: "AXButton", frame: CGRect(x: 1, y: 1, width: 9, height: 9), position: "x")
        owner.latestScreenOffer = RealtimeStandingOffer(candidates: [], app: chromeBundle, uptime: 1, elements: [logIn])
        owner.latestMenuOffer = RealtimeStandingOffer(candidates: [], app: chromeBundle, uptime: 2)
        owner.transcript = "I found Log In. Shall I press it?"
        owner.heardCompleteUptime = ProcessInfo.processInfo.systemUptime
        try await connection.beginSystemTurn(text: "correction", variant: .textOnly)
        let system = connection.turn
        #expect(system !== owner && system.isSystemTurn)
        #expect(system.previousTurnScreenOffer?.elements == [logIn] && system.previousTurnMenuOffer?.uptime == 2)
        // The owner said nothing in it: a late piece is never its heard text.
        connection.handle(["serverContent": ["inputTranscription": ["text": "late"]]], arrivalUptime: ProcessInfo.processInfo.systemUptime)
        #expect(system.heardText.isEmpty)
        system.transcript = "Correction: that didn't go through."
        // The next owner turn reads through the system turn to the owner turn.
        try await connection.beginTurn(previousReplyWasHeard: true)
        #expect(connection.turn.previousTurnSaid == "I found Log In. Shall I press it?")
        #expect(connection.turn.previousTurnScreenOffer?.elements == [logIn] && connection.turn.previousTurnMenuOffer?.uptime == 2)
        #expect(connection.turn.staleHeardPiecesUntilUptime == nil)
        // Two system turns in a row still stand for the same owner turn.
        connection.turn.transcript = "Opening it now."
        try await connection.beginSystemTurn(text: "one", variant: .textOnly)
        connection.turn.transcript = "Correction one."
        try await connection.beginSystemTurn(text: "two", variant: .textOnly)
        connection.turn.transcript = "Correction two."
        try await connection.beginTurn(previousReplyWasHeard: true)
        #expect(connection.turn.previousTurnSaid == "Opening it now.")
    }

    // MARK: 6. Point when telling (row 31)

    @Test func aReplyThatSaysClickNamesWhatToPointAt() {
        #expect(RealtimeOpenAppTool.instructedTargets(in: "Now click on 'Video' to add a clip.").first == "Video")
        #expect(RealtimeOpenAppTool.instructedTargets(in: "Click \u{201C}Start a post\u{201D} at the top.").first == "Start a post")
        #expect(RealtimeOpenAppTool.instructedTargets(in: "Just press the Log In button, sir.").prefix(2) == ["Log In button", "Log In"])
        #expect(RealtimeOpenAppTool.instructedTargets(in: "Shall I click Video?").isEmpty)
        #expect(RealtimeOpenAppTool.instructedTargets(in: "I clicked it already.").isEmpty)
        #expect(RealtimeOpenAppTool.instructedTargets(in: "The page has loaded.").isEmpty)
        // Only a target the live screen names exactly once.
        func target(_ reply: String) -> String? {
            RealtimeOpenAppTool.pointWhenTellingTarget(RealtimeOpenAppTool.instructedTargets(in: reply), snapshotResponse: signupSnapshot,
                                                       screens: [screen], screenshotDisplay: nil)?.name
        }
        #expect(target("Now click on 'Video' to add a clip.") == "Video")
        #expect(target("Just press the Log In button, sir.") == "Log In")
        #expect(target("Click login.") == nil)                      // a button and a link: no guess
        #expect(target("Click Start a post.") == nil)
    }

    // MARK: 8. OpenAI's empty follow-up (rows 21, 22, 24, 25)

    @Test func anEmptyFollowUpIsDecidedByItsOwnOutput() {
        #expect(RealtimeVoiceConnection.openAIFollowUpWasEmpty(output: [], toolResultSentUptime: 1, arrivalUptime: 2, followUpHadAudio: false, toolsInFlight: 0))
        #expect(!RealtimeVoiceConnection.openAIFollowUpWasEmpty(output: [["type": "message"]], toolResultSentUptime: 1, arrivalUptime: 2,
                                                                followUpHadAudio: false, toolsInFlight: 0))
        #expect(!RealtimeVoiceConnection.openAIFollowUpWasEmpty(output: nil, toolResultSentUptime: 1, arrivalUptime: 2, followUpHadAudio: false, toolsInFlight: 0))
        // The response that CALLED the tool ends before any result was sent.
        #expect(!RealtimeVoiceConnection.openAIFollowUpWasEmpty(output: [], toolResultSentUptime: nil, arrivalUptime: 2, followUpHadAudio: false, toolsInFlight: 0))
        #expect(!RealtimeVoiceConnection.openAIFollowUpWasEmpty(output: [], toolResultSentUptime: 3, arrivalUptime: 2, followUpHadAudio: false, toolsInFlight: 0))
        #expect(!RealtimeVoiceConnection.openAIFollowUpWasEmpty(output: [], toolResultSentUptime: 1, arrivalUptime: 2, followUpHadAudio: true, toolsInFlight: 0))
        #expect(!RealtimeVoiceConnection.openAIFollowUpWasEmpty(output: [], toolResultSentUptime: 1, arrivalUptime: 2, followUpHadAudio: false, toolsInFlight: 1))
    }

    @Test func anEmptyFollowUpIsAskedForOnceMoreThenTheTurnEnds() async throws {
        let connection = RealtimeVoiceConnection(stack: .openAIRealtime, harnessAnswer: { _ in "{}" })
        let now = ProcessInfo.processInfo.systemUptime
        try await connection.beginTurn()
        try await connection.endTurn()
        let turn = connection.turn
        connection.handle(["type": "response.created", "response": ["id": "resp_A"]], arrivalUptime: now)
        connection.handle(["type": "response.output_item.done", "response_id": "resp_A",
                           "item": ["type": "function_call", "call_id": "call_1", "name": "bogus_tool", "arguments": "{}"]],
                          arrivalUptime: now + 0.1)
        connection.handle(["type": "response.done", "response": ["id": "resp_A", "status": "completed", "output": [["type": "function_call"]]]],
                          arrivalUptime: now + 0.2)
        let deadline = ProcessInfo.processInfo.systemUptime + 4
        while turn.toolResultSentUptime == nil, ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(connection.pendingResponseCreateEventIDs.count == 1)            // the follow-up's create
        let followUp = ProcessInfo.processInfo.systemUptime
        connection.handle(["type": "response.created", "response": ["id": "resp_B"]], arrivalUptime: followUp)
        // Live: created, then done ~250 ms later with nothing in it.
        connection.handle(["type": "response.done", "response": ["id": "resp_B", "status": "completed", "output": [Any]()]],
                          arrivalUptime: followUp + 0.25)
        #expect(turn.finishedUptime == nil)
        while connection.pendingResponseCreateEventIDs.isEmpty, ProcessInfo.processInfo.systemUptime < deadline + 4 {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(connection.pendingResponseCreateEventIDs.count == 1)            // asked once more
        #expect(turn.emptyFollowUpReasked && turn.eventTrail.contains { $0.hasPrefix("emptyFollowUp:completed@") })
        // Empty again: the turn ends rather than wait for a press.
        let again = ProcessInfo.processInfo.systemUptime
        connection.handle(["type": "response.created", "response": ["id": "resp_C"]], arrivalUptime: again)
        connection.handle(["type": "response.done", "response": ["id": "resp_C", "status": "completed", "output": [Any]()]], arrivalUptime: again + 0.2)
        #expect(turn.finishedUptime == again + 0.2)
        #expect(connection.pendingResponseCreateEventIDs.isEmpty)               // no third ask
    }

    // Scenario C5 02-51-12Z: "I have highlighted it for you." with no point and no press
    // tried this turn: the owner looks for a mark that is not there. A point claim with
    // nothing tried is corrected; "Opened it." with nothing tried still is not.
    @Test func aHighlightClaimWithNothingPointedIsCorrected() {
        let killed = decision("type_text", ok: false, result: ["error": "killSwitch"])
        let c5 = "Regrettably, typing is beyond my capabilities at present, sir. You may, however, type it yourself in the search field "
            + "on the right. I have highlighted it for you."
        #expect(RealtimeOpenAppTool.receiptCorrection(transcript: c5, decisions: [decision("find_on_screen", ok: true), killed]) != nil)
        #expect(RealtimeOpenAppTool.receiptCorrection(transcript: c5, decisions: [decision("point_at", ok: true)]) == nil)
        #expect(RealtimeOpenAppTool.receiptCorrection(transcript: "Opened it.", decisions: []) == nil)
    }

    // A11 / A8 02-51-12Z failed the runner's never-rule on words that claim nothing:
    // "which appears to be open, if you'd like me to highlight it" (a state and an offer)
    // and "nothing at all was pressed". The rule judges first-person claims, the check the
    // correction uses; a pointer the reply drew is a point's receipt; a corrected claim is retracted.
    @Test func theRunnersClaimRuleJudgesClaimsNotOffers() {
        typealias Runner = ScenarioRunner
        let a11 = "Wi-Fi is beyond my reach, sir. I do see the switch in System Settings, though, which appears to be open, if you'd like me "
            + "to highlight it. I can't help noticing a dialogue box on screen too."
        #expect(!Runner.claimLeftStanding(transcript: a11, decisions: [], pointed: false, corrected: false))
        let a8 = "That did not work; nothing at all was pressed, sir. Shall I try again, or would you prefer to scroll first?"
        #expect(!Runner.claimLeftStanding(transcript: a8, decisions: [decision("press_element", ok: false)], pointed: false, corrected: false))
        let c5 = "You may type it yourself in the search field on the right. I have highlighted it for you."
        #expect(Runner.claimLeftStanding(transcript: c5, decisions: [decision("find_on_screen", ok: true)], pointed: false, corrected: false))
        #expect(!Runner.claimLeftStanding(transcript: c5, decisions: [], pointed: true, corrected: false))
        #expect(!Runner.claimLeftStanding(transcript: c5, decisions: [], pointed: false, corrected: true))
        #expect(Runner.claimLeftStanding(transcript: "I've opened LinkedIn for you.", decisions: [decision("point_at", ok: true)],
                                         pointed: false, corrected: false))
    }
}
