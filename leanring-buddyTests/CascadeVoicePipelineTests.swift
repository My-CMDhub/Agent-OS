//
//  CascadeVoicePipelineTests.swift
//  leanring-buddyTests
//
//  The cascade's pure pieces. Whether Deepgram and Haiku really answer so is what
//  `--notch-probe --notch-probe-stacks=cascade` proves live; these prove our reading.
//

import Foundation
import Testing
@testable import Clicky

struct CascadeVoicePipelineTests {
    // MARK: Sentences

    @Test func sentencesLeaveAsTheyCompleteAndADecimalIsNotOne() {
        var splitter = CascadeSentenceSplitter()
        #expect(splitter.add("Version 3.") == [])
        #expect(splitter.add("5 is out. Shall") == ["Version 3.5 is out."])
        #expect(splitter.add(" I? Yes! And") == ["Shall I?", "Yes!"])
        #expect(splitter.remainder() == "And")
        #expect(splitter.remainder() == nil)
    }

    @Test func aRemainderWithNothingToSayIsNotSpoken() {
        var splitter = CascadeSentenceSplitter()
        #expect(splitter.add("...") == [])
        #expect(splitter.remainder() == nil)
        #expect(CascadeSentenceSplitter.spoken("**Done**, `sir`.") == "Done, sir.")
    }

    // MARK: Claude's stream

    private func feed(_ lines: [String]) -> [CascadeClaudeStream.Event] {
        var stream = CascadeClaudeStream()
        return lines.flatMap { stream.feed(data: $0) }
    }

    private func finished(_ events: [CascadeClaudeStream.Event]) -> CascadeClaudeStream.Finished? {
        for case .finished(let finished) in events { return finished }
        return nil
    }

    @Test func textStreamsAndThinkingComesBackUntouched() throws {
        let events = feed([
            #"{"type":"message_start","message":{"usage":{"input_tokens":10,"cache_read_input_tokens":900}}}"#,
            #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"","signature":""}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"SIG"}}"#,
            #"{"type":"content_block_stop","index":0}"#,
            #"{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}"#,
            #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Hello"}}"#,
            #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":" sir."}}"#,
            #"{"type":"content_block_stop","index":1}"#,
            #"{"type":"ping"}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":7}}"#,
            #"{"type":"message_stop"}"#
        ])
        var texts: [String] = []
        for case .text(let text) in events { texts.append(text) }
        #expect(texts == ["Hello", " sir."])
        let message = try #require(finished(events))
        #expect(message.stopReason == "end_turn")
        #expect(message.usage == ["input_tokens": 10, "cache_read_input_tokens": 900, "output_tokens": 7])
        #expect(message.content.map { $0["type"] as? String } == ["thinking", "text"])
        // An empty thinking text is the default display, and the block must survive it.
        #expect(message.content[0]["thinking"] as? String == "")
        #expect(message.content[0]["signature"] as? String == "SIG")
        #expect(message.content[1]["text"] as? String == "Hello sir.")
    }

    @Test func toolInputIsAssembledFromItsDeltas() throws {
        let events = feed([
            #"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_1","name":"open_app","input":{}}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"na"}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"me\":\"Safari\"}"}}"#,
            #"{"type":"content_block_stop","index":0}"#,
            #"{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_2","name":"brief_sessions","input":{}}}"#,
            #"{"type":"content_block_stop","index":1}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":9}}"#,
            #"{"type":"message_stop"}"#
        ])
        let message = try #require(finished(events))
        #expect(message.stopReason == "tool_use")
        #expect((message.content[0]["input"] as? [String: Any])?["name"] as? String == "Safari")
        // A tool with no arguments sends no delta; its input is still an object, or the replay is a 400.
        #expect((message.content[1]["input"] as? [String: Any])?.isEmpty == true)
        let call = RealtimeToolCall.parsed(callID: "toolu_1", name: "open_app", arguments: message.content[0]["input"] as? [String: Any])
        #expect(call.appName == "Safari")
    }

    @Test func aRefusalAndAnErrorAreNotAReply() throws {
        let refused = try #require(finished(feed([
            #"{"type":"message_delta","delta":{"stop_reason":"refusal","stop_details":{"type":"refusal","category":"cyber"}},"usage":{"output_tokens":0}}"#,
            #"{"type":"message_stop"}"#
        ])))
        #expect(refused.stopReason == "refusal")
        #expect(refused.refusalCategory == "cyber")
        var failed: String?
        for case .failed(let type) in feed([#"{"type":"error","error":{"type":"overloaded_error","message":"x"}}"#]) { failed = type }
        #expect(failed == "overloaded_error")
        #expect(feed(["not json"]).isEmpty)
    }

    // MARK: History

    @Test func historyDropsWhatTheAPIRefuses() {
        let cutOff = CascadeClaudeStream.Finished(content: [["type": "text", "text": ""], ["type": "thinking", "thinking": "", "signature": "S"],
                                                            ["type": "tool_use", "id": "t"]],
                                                  stopReason: "max_tokens", refusalCategory: nil, usage: [:])
        #expect(CascadeClaude.historyContent(cutOff).map { $0["type"] as? String } == ["thinking"])
    }

    @Test func aNewTurnStripsThinkingOfFinishedTurns() {
        let history: [[String: Any]] = [
            ["role": "user", "content": [["type": "text", "text": "hi"]]],
            ["role": "assistant", "content": [["type": "thinking", "thinking": "", "signature": "S"], ["type": "text", "text": "hello"]]],
            ["role": "assistant", "content": [["type": "redacted_thinking", "data": "D"]]]
        ]
        let stripped = CascadeClaude.strippingThinking(history)
        #expect(stripped.count == 2)
        #expect((stripped[1]["content"] as? [[String: Any]])?.map { $0["type"] as? String } == ["text"])
    }

    @Test func trimmingNeverStartsOnAToolResult() {
        let result: [String: Any] = ["role": "user", "content": [["type": "tool_result", "tool_use_id": "t", "content": "{}"]]]
        let owner: [String: Any] = ["role": "user", "content": [["type": "text", "text": "hi"]]]
        let assistant: [String: Any] = ["role": "assistant", "content": [["type": "text", "text": "ok"]]]
        let trimmed = CascadeClaude.trimmed([owner, assistant, result, assistant, owner, assistant], limit: 4)
        #expect(trimmed.count == 2)
        #expect((trimmed[0]["content"] as? [[String: Any]])?.first?["type"] as? String == "text")
        #expect(CascadeClaude.trimmed([owner, assistant], limit: 4).count == 2)
    }

    @Test func theRequestIsHaikuAtLowEffortWithACachedPrefixAndNoSampling() throws {
        let body = CascadeClaude.requestBody(system: "S", tools: [], messages: [], thinkingOn: false)
        #expect(body["model"] as? String == "claude-haiku-5-5")
        #expect(body["stream"] as? Bool == true)
        #expect((body["output_config"] as? [String: Any])?["effort"] as? String == "low")
        #expect((body["thinking"] as? [String: Any])?["type"] as? String == "disabled")
        #expect(CascadeClaude.requestBody(system: "S", tools: [], messages: [], thinkingOn: true)["thinking"] == nil)
        #expect(body["temperature"] == nil)
        let system = try #require((body["system"] as? [[String: Any]])?.first)
        #expect((system["cache_control"] as? [String: Any])?["type"] as? String == "ephemeral")
    }

    @Test func theVoiceToolListIsTheVoiceModelsOwn() {
        let names = RealtimeVoiceVerbs.anthropicVoiceDeclarations().compactMap { $0["name"] as? String }
        #expect(names.contains(RealtimeVoiceVerbs.doTaskName))
        #expect(names.contains(RealtimeOpenAppTool.name))
        #expect(!RealtimeVoiceVerbs.anthropicDeclarations().compactMap { $0["name"] as? String }.contains(RealtimeVoiceVerbs.doTaskName))
    }

    // MARK: Wire shapes

    @Test func deepgramResultsReadAsPieces() {
        let final: [String: Any] = ["type": "Results", "is_final": true, "from_finalize": true,
                                    "channel": ["alternatives": [["transcript": "open safari"]]]]
        #expect(CascadeDeepgram.piece(from: final) == CascadeDeepgram.Piece(transcript: "open safari", isFinal: true, fromFinalize: true))
        let interim: [String: Any] = ["type": "Results", "is_final": false, "channel": ["alternatives": [["transcript": "open"]]]]
        #expect(CascadeDeepgram.piece(from: interim) == CascadeDeepgram.Piece(transcript: "open", isFinal: false, fromFinalize: false))
        #expect(CascadeDeepgram.piece(from: ["type": "Metadata"]) == nil)
    }

    @Test func deepgramURLsCarryTheRatesThePlayerAndMicUse() throws {
        let listen = CascadeDeepgram.listenURL(sampleRate: 16_000, keyterms: ["Cursor", "Google Chrome"]).absoluteString
        #expect(listen.contains("model=nova-3") && listen.contains("sample_rate=16000") && listen.contains("keyterm=Google%20Chrome"))
        let speak = CascadeDeepgram.speakURL(sampleRate: VoiceStackChoice.outputSampleRate).absoluteString
        #expect(speak.contains("aura-2-") && speak.contains("encoding=linear16") && speak.contains("sample_rate=24000"))
    }

    @Test func aToolResultIsAMessagesAPIBlockAndScrubbed() {
        let call = RealtimeToolCall(callID: "toolu_1", name: "open_app", appName: "Safari")
        let block = RealtimeVoiceConnection.toolResultMessage(stack: .cascade, result: ["ok": true], call: call)
        #expect(block["type"] as? String == "tool_result")
        #expect(block["tool_use_id"] as? String == "toolu_1")
        #expect(block["content"] as? String == #"{"ok":true}"#)
        #expect(RealtimeVoiceConnection.contextTextMessage(stack: .cascade, text: "line")["text"] as? String == "line")
    }
}

struct CascadeFailureTests {
    @Test func everyLegsFailureHasANotchLine() {
        for kind in ["cascade:stt:http401", "cascade:claude:http529", "cascade:claude:overloaded_error", "cascade:tts:close1011",
                     "cascade:token:http500", "cascade:timeout"] {
            let line = JarvisNotchReason.plain(forTurnFailure: kind)
            #expect(line != nil)
            #expect((line?.count ?? 99) <= JarvisNotchReason.maximumLength)
        }
        #expect(JarvisNotchReason.plain(forTurnFailure: "turnTimeout") == nil)
    }
}

extension CascadeFailureTests {
    /// A WebSocket holds a connection: past this a handshake waits silently (the live silent turn, 2026-11-03).
    @Test func theCascadesSocketsAreNotHeldToTheDefaultPerHostLimit() {
        #expect(CascadeDeepgram.session.configuration.httpMaximumConnectionsPerHost >= 16)
    }
}
