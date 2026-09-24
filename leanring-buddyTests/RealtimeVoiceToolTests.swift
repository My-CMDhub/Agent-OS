//
//  RealtimeVoiceToolTests.swift
//  leanring-buddyTests
//
//  Pure logic behind `open_app`: each provider's tool-call event -> the harness
//  request line, the harness response -> what the model is told, the ticket
//  re-issue loop, the honesty heuristic and the picker's stored value. Whether
//  the models actually CALL the tool is proven by `--voice-tool-probe`, not here.
//

import Foundation
import Testing
@testable import Clicky

struct RealtimeVoiceToolTests {

    private func object(_ line: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]) ?? [:]
    }

    // MARK: Parsing

    @Test func openAIFunctionCallItemBecomesALaunchRequest() throws {
        let event: [String: Any] = [
            "type": "response.output_item.done",
            "item": ["type": "function_call", "call_id": "call_1", "name": "open_app", "arguments": "{\"name\":\" System Settings \"}"]
        ]
        let call = try #require(RealtimeOpenAppTool.parseOpenAI(event))
        #expect(call == RealtimeToolCall(callID: "call_1", name: "open_app", appName: "System Settings"))
        let line = try RealtimeOpenAppTool.harnessRequestLine(for: call).get()
        #expect(object(line)["verb"] as? String == "launch")
        #expect(object(line)["app"] as? String == "System Settings")
        #expect(object(line)["ticket"] == nil)
    }

    @Test func openAIIgnoresEverythingButAFinishedFunctionCall() {
        #expect(RealtimeOpenAppTool.parseOpenAI(["type": "response.function_call_arguments.done", "call_id": "c", "name": "open_app", "arguments": "{}"]) == nil)
        #expect(RealtimeOpenAppTool.parseOpenAI(["type": "response.output_item.done", "item": ["type": "message"]]) == nil)
    }

    @Test func geminiToolCallCarriesArgsAsAnObjectAndMayHoldSeveral() {
        let message: [String: Any] = ["toolCall": ["functionCalls": [
            ["id": "g1", "name": "open_app", "args": ["name": "Finder"]],
            ["id": "g2", "name": "open_app", "args": [String: Any]()]
        ]]]
        #expect(RealtimeOpenAppTool.parseGemini(message) == [
            RealtimeToolCall(callID: "g1", name: "open_app", appName: "Finder"),
            RealtimeToolCall(callID: "g2", name: "open_app", appName: nil)
        ])
        #expect(RealtimeOpenAppTool.parseGemini(["serverContent": [String: Any]()]).isEmpty)
    }

    @Test func aCallTheHarnessCannotTakeIsRefusedWithoutAskingIt() {
        let noName = RealtimeToolCall(callID: "c", name: "open_app", appName: nil)
        let otherTool = RealtimeToolCall(callID: "c", name: "delete_file", appName: "x")
        #expect(throws: RealtimeToolRefusal.self) { try RealtimeOpenAppTool.harnessRequestLine(for: noName).get() }
        #expect(throws: RealtimeToolRefusal.self) { try RealtimeOpenAppTool.harnessRequestLine(for: otherTool).get() }
    }

    // MARK: Result

    @Test func toolResultKeepsTheHarnessFieldsAndNeverInventsSuccess() {
        let ready = RealtimeOpenAppTool.toolResult(fromHarnessResponse: ["ok": true, "status": "ready", "launch": ["x": 1]])
        #expect(ready["ok"] as? Bool == true)
        #expect(ready["status"] as? String == "ready")
        #expect(ready["error"] is NSNull)
        #expect(ready["launch"] == nil)

        let refused = RealtimeOpenAppTool.toolResult(fromHarnessResponse: ["ok": false, "error": "notFound", "message": String(repeating: "m", count: 900)])
        #expect(refused["ok"] as? Bool == false)
        #expect(refused["error"] as? String == "notFound")
        #expect((refused["message"] as? String)?.count == 300)

        // A response with no `ok` or one we could not parse is a failure.
        #expect(RealtimeOpenAppTool.toolResult(fromHarnessResponse: ["status": "ready"])["ok"] as? Bool == false)
        #expect(RealtimeOpenAppTool.toolResult(fromHarnessResponse: [:])["error"] as? String == "unreadableHarnessResponse")
    }

    @Test func aTicketIsReissuedUntilTheOwnerAnswers() async {
        final class Lines: @unchecked Sendable { var sent: [String] = [] }
        let lines = Lines()
        let responses = [
            #"{"ok":false,"error":"confirmationRequired","ticket":"T1"}"#,
            #"{"ok":false,"error":"confirmationPending"}"#,
            #"{"ok":true,"status":"ready"}"#
        ]
        let call = RealtimeToolCall(callID: "c", name: "open_app", appName: "Terminal")
        let dispatch = await RealtimeOpenAppTool.dispatch(call, answer: { line in
            lines.sent.append(line)
            return responses[lines.sent.count - 1]
        }, pollMilliseconds: 1)
        #expect(lines.sent.count == 3)
        #expect(object(lines.sent[0])["ticket"] == nil)
        #expect(object(lines.sent[2])["ticket"] as? String == "T1")
        #expect(dispatch.waitedForConfirmation)
        #expect(dispatch.harnessConfirmed)
    }

    @Test func aDeniedTicketComesBackAsTheHarnessRefusal() async {
        final class Count: @unchecked Sendable { var value = 0 }
        let count = Count()
        let call = RealtimeToolCall(callID: "c", name: "open_app", appName: "Terminal")
        let dispatch = await RealtimeOpenAppTool.dispatch(call, answer: { _ in
            count.value += 1
            return count.value == 1 ? #"{"ok":false,"error":"confirmationRequired","ticket":"T"}"# : #"{"ok":false,"error":"confirmationDenied"}"#
        }, pollMilliseconds: 1)
        #expect(!dispatch.harnessConfirmed)
        #expect(dispatch.result["error"] as? String == "confirmationDenied")
    }

    // MARK: Honesty heuristic

    @Test func claimedSuccessIsFlaggedOnlyWithoutConfirmation() {
        #expect(RealtimeOpenAppTool.claimedSuccessWithoutConfirmation(transcript: "Done, I opened System Settings.", harnessConfirmed: false))
        #expect(RealtimeOpenAppTool.claimedSuccessWithoutConfirmation(transcript: "system settings \u{2014} it\u{2019}s open now", harnessConfirmed: false))
        #expect(!RealtimeOpenAppTool.claimedSuccessWithoutConfirmation(transcript: "Done, I opened System Settings.", harnessConfirmed: true))
        #expect(!RealtimeOpenAppTool.claimedSuccessWithoutConfirmation(transcript: "sure, i'll open system settings", harnessConfirmed: false))
        #expect(!RealtimeOpenAppTool.claimedSuccessWithoutConfirmation(transcript: "it didn't open, the app was not found", harnessConfirmed: false))
    }

    // MARK: Picker

    @Test func pickerDefaultsToOpenAIAndPersistsTheChoice() throws {
        let defaults = try #require(UserDefaults(suiteName: "RealtimeVoiceToolTests-\(UUID().uuidString)"))
        #expect(VoiceStackChoice.stored(in: defaults) == .openAIRealtime)
        VoiceStackChoice.geminiLive.store(in: defaults)
        #expect(defaults.string(forKey: "selectedVoiceStack") == "geminiLive")
        #expect(VoiceStackChoice.stored(in: defaults) == .geminiLive)
        defaults.set("claude-sonnet-4-6", forKey: "selectedVoiceStack")
        #expect(VoiceStackChoice.stored(in: defaults) == .openAIRealtime)
        #expect(VoiceStackChoice.allCases.map(\.pickerLabel) == ["OpenAI", "Gemini"])
        #expect(VoiceStackChoice.openAIRealtime.inputSampleRate == 24_000)
        #expect(VoiceStackChoice.geminiLive.inputSampleRate == 16_000)
    }
}
