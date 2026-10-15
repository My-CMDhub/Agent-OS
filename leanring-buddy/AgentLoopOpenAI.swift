//
//  AgentLoopOpenAI.swift
//  leanring-buddy
//
//  The agent loop's OpenAI backend: a FALLBACK, never the default (owner
//  2026-10-13, after G14 failed only on Gemini's HTTP 503 "high demand"). A
//  Gemini step that cannot be answered (429/5xx/timeout) is retried once here
//  and the task stays here; `--agent-model=openai:<id>` runs a whole run here
//  for settled comparisons. Like AgentLoopGemini, this file only translates the
//  loop's Anthropic-shaped body to Chat Completions and the answer back, so
//  every guard is the same code. Through the worker's `/openai-agent`
//  (allow-listed models, fields and function tools; no key in the app).
//

import Foundation

nonisolated enum AgentLoopOpenAI {
    /// Must match the worker's OPENAI_AGENT_MODELS. The first is the fallback.
    static let models = ["gpt-5-mini", "gpt-4.1-mini", "gpt-5.6-luna"]
    static let defaultModel = models[0]
    static let route = "/openai-agent"
    static let pinPrefix = "openai:"

    /// `--agent-model=openai:<id>` with a listed id; nil otherwise (an unlisted id never reaches the worker).
    static func pinnedModel(arguments: [String] = CommandLine.arguments) -> String? {
        AgentLoopGemini.pinnedModel(prefix: pinPrefix, models: models, arguments: arguments)
    }

    /// Gemini could not answer this step and another provider might: busy or
    /// spent (429), its own failure (500/502/503/504), or no answer in time.
    /// Every other 4xx is our request's fault and would fail on OpenAI too.
    static func shouldFallBack(_ error: Error) -> Bool {
        if let error = error as? AgentModelError { return [429, 500, 502, 503, 504].contains(error.status) }
        return (error as? URLError)?.code == .timedOut
    }

    // MARK: Request

    /// The loop's Anthropic-shaped body as a Chat Completions request. Thinking,
    /// Anthropic server tools and Gemini signatures are dropped.
    static func request(fromAnthropic body: [String: Any], model: String) -> [String: Any] {
        let system = (body["system"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined(separator: "\n") ?? ""
        var messages: [[String: Any]] = [["role": "system", "content": system]]
        for message in body["messages"] as? [[String: Any]] ?? [] {
            let blocks = message["content"] as? [[String: Any]] ?? (message["content"] as? String).map { [["type": "text", "text": $0]] } ?? []
            if message["role"] as? String == "assistant" {
                let text = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined(separator: "\n")
                let calls = blocks.filter { $0["type"] as? String == "tool_use" }.map { block -> [String: Any] in
                    let input = block["input"] ?? [String: Any]()
                    let arguments = (try? JSONSerialization.data(withJSONObject: input)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
                    return ["id": block["id"] as? String ?? "", "type": "function",
                            "function": ["name": block["name"] as? String ?? "", "arguments": arguments]]
                }
                var assistant: [String: Any] = ["role": "assistant", "content": text.isEmpty ? NSNull() : text]
                if !calls.isEmpty { assistant["tool_calls"] = calls }
                if !text.isEmpty || !calls.isEmpty { messages.append(assistant) }
                continue
            }
            // Tool results must directly follow the assistant's calls, so they go first, each its own "tool" message.
            var parts: [[String: Any]] = []
            for block in blocks {
                switch block["type"] as? String {
                case "tool_result":
                    let text = block["content"] as? String ?? ""
                    messages.append(["role": "tool", "tool_call_id": block["tool_use_id"] as? String ?? "",
                                     "content": block["is_error"] as? Bool == true ? "error: \(text)" : text])
                case "text":
                    parts.append(["type": "text", "text": block["text"] as? String ?? ""])
                case "image":
                    let source = block["source"] as? [String: Any] ?? [:]
                    let url = "data:\(source["media_type"] as? String ?? "image/jpeg");base64,\(source["data"] as? String ?? "")"
                    parts.append(["type": "image_url", "image_url": ["url": url]])
                default:
                    continue
                }
            }
            if !parts.isEmpty { messages.append(["role": "user", "content": parts]) }
        }
        let tools = (body["tools"] as? [[String: Any]] ?? []).filter { $0["type"] == nil }.map { tool -> [String: Any] in
            ["type": "function", "function": ["name": tool["name"] ?? "", "description": tool["description"] ?? "",
                                              "parameters": tool["input_schema"] ?? [String: Any]()]]
        }
        var request: [String: Any] = ["messages": messages, "max_completion_tokens": body["max_tokens"] ?? 4096]
        if !tools.isEmpty {
            request["tools"] = tools
            request["tool_choice"] = "auto"
        }
        // Speed over depth for one step at a time, as Gemini 3's thinkingLevel low; 4.1 does not reason.
        if model.hasPrefix("gpt-5") { request["reasoning_effort"] = "low" }
        return request
    }

    // MARK: Response

    /// A Chat Completions answer in the loop's reply shape.
    static func anthropicReply(fromOpenAI response: [String: Any], model: String) -> [String: Any] {
        let choice = (response["choices"] as? [[String: Any]])?.first
        let message = choice?["message"] as? [String: Any]
        var content: [[String: Any]] = []
        if let text = message?["content"] as? String, !text.isEmpty { content.append(["type": "text", "text": text]) }
        for call in message?["tool_calls"] as? [[String: Any]] ?? [] {
            let function = call["function"] as? [String: Any]
            let arguments = (function?["arguments"] as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? [String: Any]
            content.append(["type": "tool_use", "id": call["id"] as? String ?? AgentLoopGemini.localIDPrefix + UUID().uuidString,
                            "name": function?["name"] as? String ?? "", "input": arguments ?? [:]])
        }
        let finish = choice?["finish_reason"] as? String
        let refused = message?["refusal"] is String || finish == "content_filter"
        let stop = refused ? "refusal"
            : finish == "length" ? "max_tokens"
            : content.contains { $0["type"] as? String == "tool_use" } ? "tool_use" : "end_turn"
        let usage = response["usage"] as? [String: Any]
        return ["stop_reason": stop, "content": content, "model": response["model"] as? String ?? model,
                "usage": ["input_tokens": usage?["prompt_tokens"] ?? NSNull(), "output_tokens": usage?["completion_tokens"] ?? NSNull()]]
    }
}
