//
//  RealtimeTurnCompletionTests.swift
//  leanring-buddyTests
//
//  A provider's "answer done" counts only for the turn whose request it
//  answers. A barge-in replaces the connection's turn while the cut-off answer
//  is still being generated, and that answer's done event then arrives inside
//  the NEW turn (live log 2026-09-28: four turns "finished" 15-51 ms after
//  key-up with no audio, each straight after a barge-in). Fed through the same
//  `handle(_:arrivalUptime:)` the socket calls; no socket.
//

import Foundation
import Testing
@testable import Clicky

@MainActor
struct RealtimeTurnCompletionTests {

    @Test func geminiCompletionWhileTheKeyIsHeldDoesNotFinishTheNewTurn() async throws {
        let connection = RealtimeVoiceConnection(stack: .geminiLive, harnessAnswer: { _ in "{}" })
        try await connection.beginTurn()
        try await connection.endTurn()
        // The owner presses again while that answer is still being generated.
        try await connection.beginTurn()
        let barged = connection.turn
        let now = ProcessInfo.processInfo.systemUptime
        connection.handle(["serverContent": ["interrupted": true]], arrivalUptime: now)
        connection.handle(["serverContent": ["turnComplete": true]], arrivalUptime: now + 0.01)
        #expect(barged.finishedUptime == nil)
        #expect(barged.staleCompletionsIgnored == 1)
        try await connection.endTurn()
        connection.handle(["serverContent": ["turnComplete": true]], arrivalUptime: now + 2)
        #expect(barged.finishedUptime == now + 2)
    }

    @Test func geminiAudioOfTheCutOffAnswerIsNotTheNewTurnsFirstAudio() async throws {
        let connection = RealtimeVoiceConnection(stack: .geminiLive, harnessAnswer: { _ in "{}" })
        final class Count { var played = 0 }
        let count = Count()
        connection.onAudio = { _ in count.played += 1 }
        try await connection.beginTurn()
        try await connection.endTurn()
        try await connection.beginTurn()
        let barged = connection.turn
        let audio: [String: Any] = ["serverContent": ["modelTurn": ["parts": [["inlineData": ["mimeType": "audio/pcm;rate=24000",
                                                                                               "data": Data(count: 8).base64EncodedString()]]]]]]
        connection.handle(audio, arrivalUptime: ProcessInfo.processInfo.systemUptime)
        #expect(barged.firstAudioUptime == nil)
        #expect(count.played == 0)
        try await connection.endTurn()
        let answered = ProcessInfo.processInfo.systemUptime
        connection.handle(audio, arrivalUptime: answered)
        #expect(barged.firstAudioUptime == answered)
        #expect(count.played == 1)
    }

    @Test func geminiTapReleasedBeforeTheStaleCompletionStillWaitsForItsOwn() async throws {
        let connection = RealtimeVoiceConnection(stack: .geminiLive, harnessAnswer: { _ in "{}" })
        try await connection.beginTurn()
        try await connection.endTurn()
        try await connection.beginTurn()
        let tapped = connection.turn
        let now = ProcessInfo.processInfo.systemUptime
        connection.handle(["serverContent": ["interrupted": true]], arrivalUptime: now)
        // Released 120 ms in; the cut-off answer's done lands after the release.
        try await connection.endTurn()
        connection.handle(["serverContent": ["turnComplete": true]], arrivalUptime: now + 0.2)
        #expect(tapped.finishedUptime == nil)
        #expect(tapped.eventTrail.contains { $0.hasPrefix("ignored:turnComplete@") })
        connection.handle(["serverContent": ["turnComplete": true]], arrivalUptime: now + 1.5)
        #expect(tapped.finishedUptime == now + 1.5)
    }

    @Test func openAIDoneOfTheCancelledResponseDoesNotFinishTheNewTurn() async throws {
        let connection = RealtimeVoiceConnection(stack: .openAIRealtime, harnessAnswer: { _ in "{}" })
        let now = ProcessInfo.processInfo.systemUptime
        try await connection.beginTurn()
        try await connection.endTurn()
        connection.handle(["type": "response.created", "response": ["id": "resp_A"]], arrivalUptime: now)
        try await connection.beginTurn()
        let barged = connection.turn
        // A quick tap: released before the cancelled answer's done arrives.
        try await connection.endTurn()
        connection.handle(["type": "response.done", "response": ["id": "resp_A", "status": "cancelled"]], arrivalUptime: now + 0.2)
        #expect(barged.finishedUptime == nil)
        #expect(barged.staleCompletionsIgnored == 1)
        connection.handle(["type": "response.created", "response": ["id": "resp_B"]], arrivalUptime: now + 0.3)
        connection.handle(["type": "response.done", "response": ["id": "resp_B", "status": "completed"]], arrivalUptime: now + 1)
        #expect(barged.finishedUptime == now + 1)
    }

    @Test func openAIDoneWhileTheKeyIsHeldDoesNotFinishTheNewTurn() async throws {
        let connection = RealtimeVoiceConnection(stack: .openAIRealtime, harnessAnswer: { _ in "{}" })
        let now = ProcessInfo.processInfo.systemUptime
        try await connection.beginTurn()
        try await connection.endTurn()
        connection.handle(["type": "response.created", "response": ["id": "resp_A"]], arrivalUptime: now)
        try await connection.beginTurn()
        let barged = connection.turn
        connection.handle(["type": "response.done", "response": ["id": "resp_A", "status": "completed"]], arrivalUptime: now + 0.1)
        #expect(barged.finishedUptime == nil)
        #expect(barged.staleCompletionsIgnored == 1)
        // The barge-in's cancel then finds nothing active: not a failure of this turn.
        connection.handle(["type": "error", "error": ["code": "response_cancel_not_active"]], arrivalUptime: now + 0.25)
        try await connection.endTurn()
        connection.handle(["type": "response.created", "response": ["id": "resp_B"]], arrivalUptime: now + 2)
        connection.handle(["type": "response.done", "response": ["id": "resp_B", "status": "completed"]], arrivalUptime: now + 3)
        #expect(try await barged.finished.value(timeoutSeconds: 1, timeoutKind: "t") == now + 3)
        #expect(barged.eventTrail.contains { $0.hasPrefix("error:response_cancel_not_active@") })
    }

    // MARK: Review 2026-09-29: the same bug class through tool calls, the press gap and expiry

    private final class Record: @unchecked Sendable {
        private let lock = NSLock()
        private var harnessLines: [String] = []
        var audioChunks = 0
        var turnsFinished = 0
        func add(_ line: String) { lock.lock(); harnessLines.append(line); lock.unlock() }
        var harnessRequests: Int { lock.lock(); defer { lock.unlock() }; return harnessLines.count }
    }

    private func focusFinderCall(id: String = "c1") -> [String: Any] {
        ["toolCall": ["functionCalls": [["id": id, "name": "focus_app", "args": ["name": "Finder"]]]]]
    }

    private func geminiAudio() -> [String: Any] {
        ["serverContent": ["modelTurn": ["parts": [["inlineData": ["mimeType": "audio/pcm;rate=24000", "data": Data(count: 8).base64EncodedString()]]]]]]
    }

    private func settle(_ seconds: Double = 0.4) async throws { try await Task.sleep(for: .seconds(seconds)) }

    @Test func geminiToolCallWhileTheKeyIsHeldIsNeverDispatched() async throws {
        let record = Record()
        let connection = RealtimeVoiceConnection(stack: .geminiLive, harnessAnswer: { line in record.add(line); return "{}" })
        try await connection.beginTurn()
        try await connection.endTurn()
        try await connection.beginTurn()
        connection.handle(focusFinderCall(), arrivalUptime: ProcessInfo.processInfo.systemUptime)
        try await settle()
        #expect(connection.turn.toolCalls.isEmpty)
        #expect(record.harnessRequests == 0)
        #expect(connection.turn.eventTrail.contains { $0.hasPrefix("ignored:toolCall@") })
    }

    @Test func openAIToolCallOfTheCutOffAnswerIsNeverDispatched() async throws {
        let record = Record()
        let connection = RealtimeVoiceConnection(stack: .openAIRealtime, harnessAnswer: { line in record.add(line); return "{}" })
        let now = ProcessInfo.processInfo.systemUptime
        try await connection.beginTurn()
        try await connection.endTurn()
        connection.handle(["type": "response.created", "response": ["id": "resp_A"]], arrivalUptime: now)
        try await connection.beginTurn()
        try await connection.endTurn()
        connection.handle(["type": "response.output_item.done", "response_id": "resp_A",
                           "item": ["type": "function_call", "call_id": "call_1", "name": "focus_app", "arguments": "{\"name\":\"Finder\"}"]],
                          arrivalUptime: now + 0.1)
        try await settle()
        #expect(connection.turn.toolCalls.isEmpty)
        #expect(record.harnessRequests == 0)
    }

    /// Live `beginTurn` waits ~300 ms for the key-down capture; until then
    /// `connection.turn` is still the answer being cut off.
    @Test func aPressSupersedesTheAnsweringTurnBeforeBeginTurnReplacesIt() async throws {
        let record = Record()
        let connection = RealtimeVoiceConnection(stack: .geminiLive, harnessAnswer: { line in record.add(line); return "{}" })
        connection.onAudio = { _ in record.audioChunks += 1 }
        connection.onTurnFinished = { record.turnsFinished += 1 }
        try await connection.beginTurn()
        try await connection.endTurn()
        let cutOff = connection.turn
        connection.handle(geminiAudio(), arrivalUptime: ProcessInfo.processInfo.systemUptime)
        #expect(record.audioChunks == 1)
        connection.supersedeForPress()
        connection.handle(geminiAudio(), arrivalUptime: ProcessInfo.processInfo.systemUptime)
        connection.handle(focusFinderCall(), arrivalUptime: ProcessInfo.processInfo.systemUptime)
        connection.handle(["serverContent": ["turnComplete": true]], arrivalUptime: ProcessInfo.processInfo.systemUptime)
        try await settle()
        #expect(record.audioChunks == 1)
        #expect(record.turnsFinished == 0)
        #expect(cutOff.toolCalls.isEmpty)
        #expect(record.harnessRequests == 0)
    }

    @Test func aCallAlreadyAtTheHarnessWhenThePressCameSendsNoResult() async throws {
        let record = Record()
        let release = DispatchSemaphore(value: 0)
        let connection = RealtimeVoiceConnection(stack: .geminiLive, harnessAnswer: { line in
            record.add(line); release.wait(); return #"{"ok":true}"#
        })
        try await connection.beginTurn()
        try await connection.endTurn()
        connection.handle(["serverContent": ["inputTranscription": ["text": "switch to finder"]]], arrivalUptime: ProcessInfo.processInfo.systemUptime)
        connection.handle(focusFinderCall(), arrivalUptime: ProcessInfo.processInfo.systemUptime)
        let answering = connection.turn
        let deadline = ProcessInfo.processInfo.systemUptime + 4
        while record.harnessRequests == 0, ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(record.harnessRequests == 1)
        // Waiting on the harness (a card, say) when the owner presses again.
        connection.supersedeForPress()
        release.signal()
        while answering.toolsInFlight > 0, ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(answering.toolsInFlight == 0)
        #expect(answering.toolResultSentUptime == nil)
        #expect(answering.dispatches.count == 1)
        #expect(answering.eventTrail.contains { $0.hasPrefix("ignored:toolResult@") })
    }

    @Test func geminiInterruptedWithNoTurnCompleteDoesNotSwallowTheNextAnswer() async throws {
        let connection = RealtimeVoiceConnection(stack: .geminiLive, harnessAnswer: { _ in "{}" })
        try await connection.beginTurn()
        try await connection.endTurn()
        try await connection.beginTurn()
        let now = ProcessInfo.processInfo.systemUptime
        connection.handle(["serverContent": ["interrupted": true]], arrivalUptime: now)
        try await connection.endTurn()
        let answered = now + RealtimeVoiceConnection.geminiInterruptedStaleSeconds + 0.5
        connection.handle(geminiAudio(), arrivalUptime: answered)
        connection.handle(["serverContent": ["turnComplete": true]], arrivalUptime: answered + 1)
        #expect(connection.turn.firstAudioUptime == answered)
        #expect(connection.turn.finishedUptime == answered + 1)
    }

    @Test func openAIAudioCountsOnlyForThisTurnsResponse() async throws {
        let record = Record()
        let connection = RealtimeVoiceConnection(stack: .openAIRealtime, harnessAnswer: { _ in "{}" })
        connection.onAudio = { _ in record.audioChunks += 1 }
        let now = ProcessInfo.processInfo.systemUptime
        try await connection.beginTurn()
        try await connection.endTurn()
        connection.handle(["type": "response.created", "response": ["id": "resp_A"]], arrivalUptime: now)
        try await connection.beginTurn()
        try await connection.endTurn()
        let delta: (String) -> [String: Any] = { ["type": "response.output_audio.delta", "response_id": $0, "delta": Data(count: 8).base64EncodedString()] }
        connection.handle(delta("resp_A"), arrivalUptime: now + 0.1)
        #expect(record.audioChunks == 0)
        #expect(connection.turn.firstAudioUptime == nil)
        connection.handle(["type": "response.created", "response": ["id": "resp_B"]], arrivalUptime: now + 0.2)
        connection.handle(delta("resp_B"), arrivalUptime: now + 0.3)
        #expect(record.audioChunks == 1)
        #expect(connection.turn.firstAudioUptime == now + 0.3)
    }

    @Test func openAIToolFollowUpIsThisTurnsResponseToo() async throws {
        let connection = RealtimeVoiceConnection(stack: .openAIRealtime, harnessAnswer: { _ in "{}" })
        let now = ProcessInfo.processInfo.systemUptime
        try await connection.beginTurn()
        try await connection.endTurn()
        let turn = connection.turn
        connection.handle(["type": "response.created", "response": ["id": "resp_A"]], arrivalUptime: now)
        connection.handle(["type": "response.output_item.done", "response_id": "resp_A",
                           "item": ["type": "function_call", "call_id": "call_1", "name": "bogus_tool", "arguments": "{}"]],
                          arrivalUptime: now + 0.1)
        connection.handle(["type": "response.done", "response": ["id": "resp_A"]], arrivalUptime: now + 0.2)
        let deadline = ProcessInfo.processInfo.systemUptime + 4
        while turn.toolResultSentUptime == nil, ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(turn.toolResultSentUptime != nil)
        let followUp = ProcessInfo.processInfo.systemUptime
        connection.handle(["type": "response.created", "response": ["id": "resp_B"]], arrivalUptime: followUp)
        connection.handle(["type": "response.output_audio.delta", "response_id": "resp_B", "delta": Data(count: 8).base64EncodedString()],
                          arrivalUptime: followUp + 0.1)
        connection.handle(["type": "response.done", "response": ["id": "resp_B"]], arrivalUptime: followUp + 0.2)
        #expect(turn.responseIDs == ["resp_A", "resp_B"])
        #expect(turn.finishedUptime == followUp + 0.2)
    }

    @Test func anErrorForgetsOnlyTheResponseCreateItRefused() async throws {
        let connection = RealtimeVoiceConnection(stack: .openAIRealtime, harnessAnswer: { _ in "{}" })
        let now = ProcessInfo.processInfo.systemUptime
        try await connection.beginTurn()
        try await connection.endTurn()
        // An error about something else: the create is still in flight and still T1's.
        connection.handle(["type": "error", "error": ["code": "something_else", "event_id": "not_a_create"]], arrivalUptime: now)
        try await connection.beginTurn()
        try await connection.endTurn()
        let second = connection.turn
        connection.handle(["type": "response.created", "response": ["id": "resp_A"]], arrivalUptime: now + 0.1)
        connection.handle(["type": "response.created", "response": ["id": "resp_B"]], arrivalUptime: now + 0.2)
        connection.handle(["type": "response.done", "response": ["id": "resp_A"]], arrivalUptime: now + 0.3)
        #expect(second.finishedUptime == nil)
        connection.handle(["type": "response.done", "response": ["id": "resp_B"]], arrivalUptime: now + 0.4)
        #expect(second.finishedUptime == now + 0.4)
        // The error that names this turn's create removes exactly that one.
        try await connection.beginTurn()
        try await connection.endTurn()
        let refused = try #require(connection.pendingResponseCreateEventIDs.last)
        connection.handle(["type": "error", "error": ["code": "conversation_already_has_active_response", "event_id": refused]], arrivalUptime: now + 1)
        #expect(connection.pendingResponseCreateEventIDs.isEmpty)
    }

    @Test func aSilentTurnEndsOnNoReplyNotIdle() async throws {
        let connection = RealtimeVoiceConnection(stack: .geminiLive, harnessAnswer: { _ in "{}" })
        try await connection.beginTurn()
        try await connection.endTurn()
        // No suspension from here: the notch is shared, and nothing else may move it in between.
        JarvisNotch.shared.handle(.hotkeyDown)
        JarvisNotch.shared.handle(.hotkeyUp)
        connection.handle(["serverContent": ["turnComplete": true]], arrivalUptime: ProcessInfo.processInfo.systemUptime)
        #expect(JarvisNotch.shared.state == .noReply)
    }
}

