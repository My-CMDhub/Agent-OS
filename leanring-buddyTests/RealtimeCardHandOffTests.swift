//
//  RealtimeCardHandOffTests.swift
//  leanring-buddyTests
//
//  An approval card is the realtime voice's to ask about, the moment it shows,
//  and its answer is told to the model so it never asks again (owner's live test
//  2026-10-31: a canned nudge spoke first, then the model asked for approval 3.9 s
//  AFTER the owner had clicked Allow). Fed through `handle(_:arrivalUptime:)` with
//  a fake harness; no socket, no card on screen.
//

import Foundation
import Testing
@testable import Clicky

@MainActor
struct RealtimeCardHandOffTests {
    /// A ticket the test answers: confirmationRequired, then pending until `answer` is set.
    final class FakeTicket: @unchecked Sendable {
        private let lock = NSLock()
        private var answerLine: String?
        private(set) var requests: [String] = []
        func set(_ line: String) { lock.lock(); answerLine = line; lock.unlock() }
        func respond(_ line: String) -> String {
            lock.lock(); defer { lock.unlock() }
            requests.append(line)
            guard line.contains("\"ticket\"") else { return #"{"ok":false,"error":"confirmationRequired","ticket":"T1","message":"needs a click"}"# }
            return answerLine ?? #"{"ok":false,"error":"confirmationPending"}"#
        }
    }

    private func until(_ seconds: Double = 5, _ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while !condition(), ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(for: .milliseconds(20)) }
    }

    @Test func theModelIsToldAtOnceAndHearsTheAnswerAfterwards() async throws {
        let ticket = FakeTicket()
        let connection = RealtimeVoiceConnection(stack: .geminiLive, harnessAnswer: { ticket.respond($0) })
        final class Told { var text: String?; var askStillCurrent: Bool?; var line: [String: Any]? }
        let told = Told()
        connection.onCardAnswered = { told.text = $0; told.askStillCurrent = $1; told.line = $2 }
        try await connection.beginTurn()
        try await connection.endTurn()
        let turn = connection.turn
        connection.handle(["serverContent": ["inputTranscription": ["text": "switch to finder"]]], arrivalUptime: ProcessInfo.processInfo.systemUptime)
        connection.handle(["toolCall": ["functionCalls": [["id": "c1", "name": "focus_app", "args": ["name": "Finder"]]]]],
                          arrivalUptime: ProcessInfo.processInfo.systemUptime)
        // The card is up and unanswered: the model already has its result, and asks.
        try await until { turn.toolResultSentUptime != nil }
        #expect(turn.toolResultSentUptime != nil)
        #expect(turn.decisions.first?.dispatch?.result["error"] as? String == "confirmationRequired")
        #expect(turn.decisions.first?.dispatch?.result["status"] as? String == "awaitingOwner")
        #expect(turn.cardsAwaitingOwner == 1)
        #expect(ConfirmationNudger.voiceAskedUptime != nil)
        #expect(told.text == nil)
        // Its ask is spoken and the turn ends while the card is still up.
        let audio: [String: Any] = ["serverContent": ["modelTurn": ["parts": [["inlineData": ["mimeType": "audio/pcm;rate=24000",
                                                                                               "data": Data(count: 8).base64EncodedString()]]]]]]
        connection.handle(audio, arrivalUptime: ProcessInfo.processInfo.systemUptime)
        connection.handle(["serverContent": ["turnComplete": true]], arrivalUptime: ProcessInfo.processInfo.systemUptime)
        #expect(turn.finishedUptime != nil)
        // The owner clicks Allow: the model is told, once, as a system line.
        ticket.set(#"{"ok":true,"status":"confirmed","verification":"confirmed"}"#)
        try await until { told.text != nil }
        #expect(told.text?.contains("the owner allowed it on the card") == true)
        #expect(told.text?.contains("never ask for approval again") == true)
        #expect(told.askStillCurrent == true)
        #expect(told.line?["kind"] as? String == "cardOutcome")
        #expect(told.line?["outcome"] as? String == "allowed")
        #expect(turn.replyMuted)
        #expect(turn.cardsAwaitingOwner == 0)
        #expect(turn.decisions.first?.dispatch?.result["ok"] as? Bool == true)
    }

    @Test func aCallBehindTheCardIsAnsweredAtOnceSoTheAskIsNotHeld() async throws {
        let ticket = FakeTicket()
        let connection = RealtimeVoiceConnection(stack: .geminiLive, harnessAnswer: { ticket.respond($0) })
        connection.onCardAnswered = { _, _, _ in }
        try await connection.beginTurn()
        try await connection.endTurn()
        let turn = connection.turn
        connection.handle(["serverContent": ["inputTranscription": ["text": "switch to finder"]]], arrivalUptime: ProcessInfo.processInfo.systemUptime)
        connection.handle(["toolCall": ["functionCalls": [["id": "c1", "name": "focus_app", "args": ["name": "Finder"]],
                                                          ["id": "c2", "name": "bogus_tool", "args": [String: Any]()]]]],
                          arrivalUptime: ProcessInfo.processInfo.systemUptime)
        try await until { turn.decisions.count == 2 && turn.decisions[1].dispatch != nil }
        #expect(turn.decisions[1].dispatch?.result["error"] as? String == "cardPending")
        // Both calls are answered while the card is still up.
        #expect(turn.toolsInFlight == 0)
        #expect(turn.cardsAwaitingOwner == 1)
        ticket.set(#"{"ok":false,"error":"confirmationDenied","message":"denied"}"#)
        try await until { turn.cardsAwaitingOwner == 0 }
    }

    @Test func theAnswerSaysWhatHappenedFromTheResultOnly() {
        #expect(RealtimeVoiceConnection.cardAnsweredText(result: ["ok": false, "error": "confirmationDenied"])
            .contains("denied it on the card, so nothing was done"))
        #expect(RealtimeVoiceConnection.cardAnsweredText(result: ["ok": false, "error": "confirmationExpired"])
            .contains("expired without an answer"))
        #expect(RealtimeVoiceConnection.cardAnsweredText(result: ["ok": false, "error": "confirmationPending"])
            .contains("expired without an answer"))
        #expect(RealtimeVoiceConnection.cardAnsweredText(result: ["ok": false, "error": "appStillRunning"])
            .contains("did not complete"))
        #expect(RealtimeVoiceConnection.cardOutcome(result: ["ok": true]) == "allowed")
        #expect(RealtimeVoiceConnection.cardOutcome(result: ["ok": false, "error": "confirmationDenied"]) == "denied")
        #expect(RealtimeVoiceConnection.cardOutcome(result: ["ok": false, "error": "confirmationStale"]) == "failed")
        // The hand-off never claims anything was done.
        #expect(RealtimeVoiceConnection.cardHandOffResult["ok"] as? Bool == false)
    }
}
