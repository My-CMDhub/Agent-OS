//
//  AgentLoopOpenAITests.swift
//  leanring-buddyTests
//
//  The OpenAI fallback backend's translation both ways, when a Gemini failure
//  moves a step to it, and the comparison pin. Whether the worker's key reaches
//  gpt-5-mini, and what it answers, is a live run's, not this file's.
//

import Foundation
import Testing
@testable import Clicky

struct AgentLoopOpenAITests {

    private func messages(_ request: [String: Any]) -> [[String: Any]] { request["messages"] as? [[String: Any]] ?? [] }
    private func message(_ all: [[String: Any]], _ index: Int) -> [String: Any] { all.indices.contains(index) ? all[index] : [:] }

    private let history: [String: Any] = [
        "max_tokens": 4096,
        "system": [["type": "text", "text": "You are the task runner."]],
        "tools": [["name": "scroll", "description": "d", "input_schema": ["type": "object", "properties": [:], "required": []]],
                  ["type": "web_search_20250305", "name": "web_search", "max_uses": 3]],
        "messages": [
            ["role": "user", "content": [["type": "text", "text": "goal"],
                                         ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": "QUJD"]]]],
            ["role": "assistant", "content": [["type": "text", "text": "Scrolling."],
                                              ["type": "tool_use", "id": "call_1", "name": "scroll", "input": ["direction": "down"], "thoughtSignature": "SIG"],
                                              ["type": "tool_use", "id": "local-2", "name": "read_page", "input": [:]]]],
            ["role": "user", "content": [["type": "tool_result", "tool_use_id": "call_1", "content": "{\"ok\":true}"],
                                         ["type": "tool_result", "tool_use_id": "local-2", "content": "{\"ok\":false}", "is_error": true],
                                         ["type": "text", "text": "Step 2"]]]
        ]
    ]

    @Test func aRequestTranslatesRolesImagesCallsAndResults() {
        let request = AgentLoopOpenAI.request(fromAnthropic: history, model: "gpt-5-mini")
        let all = messages(request)
        #expect(all.map { $0["role"] as? String } == ["system", "user", "assistant", "tool", "tool", "user"])
        #expect(message(all, 0)["content"] as? String == "You are the task runner.")
        let image = (message(all, 1)["content"] as? [[String: Any]])?.last?["image_url"] as? [String: Any]
        #expect(image?["url"] as? String == "data:image/jpeg;base64,QUJD")
        let assistant = message(all, 2)
        #expect(assistant["content"] as? String == "Scrolling.")
        let calls = assistant["tool_calls"] as? [[String: Any]] ?? []
        #expect(calls.compactMap { $0["id"] as? String } == ["call_1", "local-2"])
        #expect(calls.first?["thoughtSignature"] == nil && "\(calls)".contains("SIG") == false, "a Gemini signature never reaches OpenAI")
        let arguments = ((calls.first?["function"] as? [String: Any])?["arguments"] as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? [String: Any]
        #expect(arguments?["direction"] as? String == "down")
        // Each result answers its call by id, as role "tool", right after the calls.
        #expect(message(all, 3)["tool_call_id"] as? String == "call_1" && message(all, 3)["content"] as? String == "{\"ok\":true}")
        #expect(message(all, 4)["tool_call_id"] as? String == "local-2" && message(all, 4)["content"] as? String == "error: {\"ok\":false}")
        #expect((message(all, 5)["content"] as? [[String: Any]])?.first?["text"] as? String == "Step 2")
        let tools = request["tools"] as? [[String: Any]] ?? []
        #expect(tools.compactMap { ($0["function"] as? [String: Any])?["name"] as? String } == ["scroll"], "Anthropic server tools never reach OpenAI")
        #expect(request["tool_choice"] as? String == "auto" && request["max_completion_tokens"] as? Int == 4096)
        #expect(request["reasoning_effort"] as? String == "low")
        #expect(AgentLoopOpenAI.request(fromAnthropic: history, model: "gpt-4.1-mini")["reasoning_effort"] == nil, "4.1 does not reason")
    }

    @MainActor @Test func onlyTheLatestScreenshotTravels() {
        var body = history
        var turns = body["messages"] as? [[String: Any]] ?? []
        turns.append(["role": "assistant", "content": [["type": "text", "text": "(no reply)"]]])
        turns.append(["role": "user", "content": [["type": "image", "source": ["media_type": "image/jpeg", "data": "TEFURVNU"]]]])
        body["messages"] = AgentLoop.keepingLatestImage(turns)
        let images = messages(AgentLoopOpenAI.request(fromAnthropic: body, model: "gpt-5-mini")).flatMap { ($0["content"] as? [[String: Any]]) ?? [] }
            .compactMap { ($0["image_url"] as? [String: Any])?["url"] as? String }
        #expect(images == ["data:image/jpeg;base64,TEFURVNU"])
    }

    @MainActor @Test func aResponseTranslatesCallsAndTheirIdsRoundTrip() {
        let reply = AgentLoopOpenAI.anthropicReply(fromOpenAI: [
            "model": "gpt-5-mini-2025-08-07",
            "choices": [["finish_reason": "tool_calls", "message": ["role": "assistant", "content": "Scrolling.",
                "tool_calls": [["id": "call_abc", "type": "function", "function": ["name": "scroll", "arguments": "{\"direction\":\"down\"}"]]]]]],
            "usage": ["prompt_tokens": 100, "completion_tokens": 20]], model: "gpt-5-mini")
        let content = reply["content"] as? [[String: Any]] ?? []
        #expect(content.map { $0["type"] as? String } == ["text", "tool_use"])
        #expect(content.last?["id"] as? String == "call_abc")
        #expect((content.last?["input"] as? [String: Any])?["direction"] as? String == "down")
        #expect(reply["stop_reason"] as? String == "tool_use" && reply["model"] as? String == "gpt-5-mini-2025-08-07")
        #expect((reply["usage"] as? [String: Any])?["output_tokens"] as? Int == 20)
        // The id goes back out on the next request: the call and its result match.
        let next = AgentLoopOpenAI.request(fromAnthropic: ["messages": [
            ["role": "assistant", "content": AgentLoop.assistantContent(reply)],
            ["role": "user", "content": [["type": "tool_result", "tool_use_id": "call_abc", "content": "{}"]]]]], model: "gpt-5-mini")
        let all = messages(next)
        #expect(((message(all, 1)["tool_calls"] as? [[String: Any]])?.first?["id"] as? String) == "call_abc")
        #expect(message(all, 2)["tool_call_id"] as? String == "call_abc")

        func stop(_ choice: [String: Any]) -> String? { AgentLoopOpenAI.anthropicReply(fromOpenAI: ["choices": [choice]], model: "x")["stop_reason"] as? String }
        #expect(stop(["finish_reason": "stop", "message": ["refusal": "I can't help with that."]]) == "refusal")
        #expect(stop(["finish_reason": "content_filter", "message": [:]]) == "refusal")
        #expect(stop(["finish_reason": "length", "message": ["content": "half"]]) == "max_tokens")
        #expect(stop(["finish_reason": "stop", "message": ["content": "done", "refusal": NSNull()]]) == "end_turn")
    }

    /// G14 2026-10-12 failed only on Gemini's 503 "high demand": that, a spent
    /// quota and a timeout move the step; our own bad request never does.
    @Test func onlyBusyOrFailingOrSilentGeminiFallsBack() {
        for status in [429, 500, 502, 503, 504] { #expect(AgentLoopOpenAI.shouldFallBack(AgentModelError(status: status, body: "")), "\(status)") }
        for status in [400, 401, 403, 404, 413, -1] { #expect(!AgentLoopOpenAI.shouldFallBack(AgentModelError(status: status, body: "")), "\(status)") }
        #expect(AgentLoopOpenAI.shouldFallBack(URLError(.timedOut)))
        #expect(!AgentLoopOpenAI.shouldFallBack(URLError(.notConnectedToInternet)), "offline is offline for OpenAI too")
        #expect(!AgentLoopOpenAI.shouldFallBack(CancellationError()))
    }

    @Test func aComparisonRunPinsOpenAIOnlyToAListedModel() {
        #expect(AgentLoopOpenAI.models == ["gpt-5-mini", "gpt-4.1-mini"], "must match the worker's OPENAI_AGENT_MODELS")
        #expect(AgentLoopOpenAI.pinnedModel(arguments: ["--agent-model=openai:gpt-5-mini"]) == "gpt-5-mini")
        #expect(AgentLoopOpenAI.pinnedModel(arguments: ["--agent-model=openai:gpt-4.1-mini"]) == "gpt-4.1-mini")
        #expect(AgentLoopOpenAI.pinnedModel(arguments: ["--agent-model=openai:gpt-5"]) == nil, "an unlisted id never reaches the worker")
        #expect(AgentLoopOpenAI.pinnedModel(arguments: ["--agent-model=gpt-5-mini"]) == nil)
        #expect(AgentLoopOpenAI.pinnedModel(arguments: ["--agent-model=openai:gpt-5-mini", "--agent-model=gemini-3.8-flash"]) == nil, "the last pin wins")
        #expect(AgentModelProvider.from(nil, arguments: ["--agent-model=openai:gpt-5-mini"]) == .openai)
        #expect(AgentModelProvider.from("claude", arguments: ["--agent-model=openai:gpt-4.1-mini"]) == .openai)
        #expect(AgentModelProvider.from(nil, arguments: ["--agent-model=gemini-3.8-flash"]) == .gemini, "Gemini stays the default")
        #expect(AgentModelProvider.from(nil) == .gemini)
        #expect(AgentLoopModel.firstModel(.openai, arguments: ["--agent-model=openai:gpt-4.1-mini"]) == "gpt-4.1-mini")
        #expect(AgentLoopModel.firstModel(.openai, arguments: []) == "gpt-5-mini")
        #expect(AgentLoopModel.firstModel(.gemini, arguments: []) == "gemini-3.1-pro-preview")
    }

    @MainActor @Test func openAIGetsTheGeminiToolListWithWebLookup() {
        let names = ((AgentLoop.requestBody(messages: [], provider: .openai)["tools"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }
        #expect(names.contains("web_lookup") && !names.contains("web_search"))
    }
}
