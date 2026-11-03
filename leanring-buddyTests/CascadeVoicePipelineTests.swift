//
//  CascadeVoicePipelineTests.swift
//  leanring-buddyTests
//
//  The cascade's pure pieces. Whether Deepgram and Haiku really answer so is what
//  `--notch-probe --notch-probe-stacks=cascade` proves live; these prove our reading.
//

import Foundation
import CoreGraphics
import ImageIO
import Testing
import UniformTypeIdentifiers
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
        #expect(speak.contains(CascadeDeepgram.speakPath()) && speak.contains("model=\(CascadeDeepgram.voice)") && speak.contains("speed=\(CascadeDeepgram.speed)")
            && speak.contains("encoding=linear16") && speak.contains("sample_rate=24000"))
    }

    /// `smart_format` fused "open linkedin dot com" into "Openlinkedin.com.", which the heard check rightly refuses.
    @Test func theOwnersWordsAreNotReformattedIntoAnAddress() {
        let listen = CascadeDeepgram.listenURL(sampleRate: 16_000, keyterms: []).absoluteString
        #expect(!listen.contains("smart_format") && listen.contains("punctuate=true") && !listen.contains("numerals"))
        // The guard itself did not move: words inside a word never name a site, spoken words do.
        #expect(RealtimeHeardCheck.siteRefusal(transcript: "Openlinkedin.com.", url: "https://www.linkedin.com") != nil)
        #expect(RealtimeHeardCheck.siteRefusal(transcript: "Open linkedin dot com.", url: "https://www.linkedin.com") == nil)
        #expect(RealtimeHeardCheck.siteRefusal(transcript: "Open evil dot com.", url: "https://www.linkedin.com") != nil)
    }

    /// "stop" sent as one burst came back empty 7 of 8; at 2x, 15 of 15 right. A clip's send takes half its length.
    @Test func audioGoesAtTwiceRealTime() {
        #expect(CascadeDeepgram.sendRate == 2)
        #expect(abs(CascadeDeepgram.sendSeconds(bytes: 16_000, sampleRate: 16_000) - 0.25) < 1e-9)
    }

    @Test func theFinalDeadlineCountsWhatIsStillToSendAndARetrysHandshake() {
        let plain = CascadeDeepgram.finalDeadlineSeconds(unsentBytes: 0, sampleRate: 16_000, isRetry: false)
        #expect(plain == CascadeDeepgram.finalWaitSeconds)
        // 1 s of audio left at 2x.
        #expect(abs(CascadeDeepgram.finalDeadlineSeconds(unsentBytes: 32_000, sampleRate: 16_000, isRetry: false) - plain - 0.5) < 1e-9)
        #expect(CascadeDeepgram.finalDeadlineSeconds(unsentBytes: 0, sampleRate: 16_000, isRetry: true) == plain + CascadeDeepgram.retryHandshakeSeconds)
        // Never a long silent wait: a 10 s hold, all unsent, on a retry.
        #expect(CascadeDeepgram.finalDeadlineSeconds(unsentBytes: 320_000, sampleRate: 16_000, isRetry: true) < 10)
    }

    @Test func noFinalUsesWordsOnceReleasedRetriesOnceThenGivesUp() {
        #expect(CascadeDeepgram.noFinal(wordsSoFar: "open saf", released: true, retried: false) == .useWordsSoFar)
        #expect(CascadeDeepgram.noFinal(wordsSoFar: "open saf", released: true, retried: true) == .useWordsSoFar)
        // Still holding: the rest of the words need a socket.
        #expect(CascadeDeepgram.noFinal(wordsSoFar: "open saf", released: false, retried: false) == .retry)
        #expect(CascadeDeepgram.noFinal(wordsSoFar: " ", released: true, retried: false) == .retry)
        #expect(CascadeDeepgram.noFinal(wordsSoFar: "", released: true, retried: true) == .giveUp)
    }

    @Test func aSpareThatStoppedAnsweringIsStale() {
        // A handshake's worst is well inside it; an unanswered upgrade or a missed ping is not.
        #expect(!CascadeDeepgram.isStale(openedUptime: 100, provenUptime: nil, now: 103))
        #expect(CascadeDeepgram.isStale(openedUptime: 100, provenUptime: nil, now: 107))
        #expect(!CascadeDeepgram.isStale(openedUptime: 100, provenUptime: 150, now: 154))
        #expect(CascadeDeepgram.isStale(openedUptime: 100, provenUptime: 150, now: 157))
    }

    /// A voiced press that came back with no words during a task is said out loud, and never stops the task.
    @Test func noWordsDuringARunningTaskAreToldNotGuessed() {
        #expect(RealtimeVoiceSession.unheardDuringTask(heard: "", superseded: false, gotReply: false, taskRunning: true))
        #expect(!RealtimeVoiceSession.unheardDuringTask(heard: "Stop.", superseded: false, gotReply: false, taskRunning: true))
        #expect(!RealtimeVoiceSession.unheardDuringTask(heard: "", superseded: false, gotReply: false, taskRunning: false))
        #expect(!RealtimeVoiceSession.unheardDuringTask(heard: "", superseded: true, gotReply: false, taskRunning: true))
        #expect(!RealtimeVoiceSession.unheardDuringTask(heard: "", superseded: false, gotReply: true, taskRunning: true))
        #expect(!RealtimeVoiceSession.ownerWordsStopTask(""))
    }

    @Test func aScreenshotGoesSmallerAndACloseUpAsItCame() throws {
        func jpeg(_ width: Int, _ height: Int) throws -> Data {
            let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                                 space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let image = try #require(context.makeImage())
            let data = NSMutableData()
            let destination = try #require(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, nil)
            #expect(CGImageDestinationFinalize(destination))
            return data as Data
        }
        func size(_ data: Data) throws -> (Int, Int) {
            let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
            let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
            return (try #require(properties[kCGImagePropertyPixelWidth] as? Int), try #require(properties[kCGImagePropertyPixelHeight] as? Int))
        }
        let small = try size(CascadeClaude.voiceImage(jpeg(1920, 1200)))
        #expect(small.0 == CascadeClaude.imageLongEdge && small.1 == 640)   // The aspect holds: positions are fractions of the image.
        let closeUp = try jpeg(320, 200)
        #expect(CascadeClaude.voiceImage(closeUp) == closeUp)
        #expect(CascadeClaude.voiceImage(Data("not an image".utf8)) == Data("not an image".utf8))
    }

    @Test func onlyTheCascadeIsAskedForAnIntentLine() {
        for format in [RealtimePointFormat.live, .native, .fractions] {
            #expect(RealtimeOpenAppTool.systemPrompt(pointFormat: format, stack: .cascade).contains("intent only"))
            #expect(!RealtimeOpenAppTool.systemPrompt(pointFormat: format, stack: .geminiLive).contains("intent only"))
        }
        // It claims nothing the honesty checks would read as done.
        #expect(!RealtimeOpenAppTool.claimsCompletion("Pressing that now."))
        #expect(RealtimeOpenAppTool.firstPersonClaims("Typing it in, sir.").isEmpty)
    }

    @Test func theCacheBreakpointMovesToTheNewTurnsLastBlock() {
        let old: [String: Any] = ["role": "user", "content": [["type": "text", "text": "a", "cache_control": ["type": "ephemeral"]]]]
        let reply: [String: Any] = ["role": "assistant", "content": [["type": "text", "text": "b"]]]
        let new: [String: Any] = ["role": "user", "content": [["type": "image"], ["type": "text", "text": "c"]]]
        let moved = CascadeClaude.movingBreakpoint(toLastBlockOf: [old, reply, new])
        func blocks(_ index: Int) -> [[String: Any]] { moved[index]["content"] as? [[String: Any]] ?? [] }
        #expect(blocks(0)[0]["cache_control"] == nil)
        #expect(blocks(2)[0]["cache_control"] == nil)
        #expect(blocks(2)[1]["cache_control"] != nil)
    }

    @Test func auraEndsASentenceOnFlushedAndLivesOnV1() {
        #expect(CascadeDeepgram.endsASentence(["type": "Flushed"], voice: "aura-2-draco-en"))
        #expect(!CascadeDeepgram.endsASentence(["type": "Metadata"], voice: "aura-2-draco-en"))
        #expect(CascadeDeepgram.speakPath(voice: "aura-2-draco-en") == "/v1/speak")
        #expect(ConfirmationClips.speakURL(voice: "aura-2-draco-en").path == "/v1/speak")
        #expect(CascadeDeepgram.speakPath(voice: "flux-colin-en") == "/v2/speak")
    }

    @Test func fluxEndsASentenceOnItsMetadataNotFlushed() {
        let flux = "flux-tanner-en"
        #expect(CascadeDeepgram.endsASentence(["type": "SpeechMetadata"], voice: flux))
        #expect(!CascadeDeepgram.endsASentence(["type": "Flushed"], voice: flux))
        #expect(!CascadeDeepgram.endsASentence(["type": "SpeechStarted"], voice: flux))
        #expect(CascadeDeepgram.endsASentence(["type": "Warning", "code": "NO_SYNTHESIZABLE_TEXT"], voice: flux))
        #expect(!CascadeDeepgram.endsASentence(["type": "Warning", "code": "INPUT_MARKUP_STRIPPED"], voice: flux))
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
