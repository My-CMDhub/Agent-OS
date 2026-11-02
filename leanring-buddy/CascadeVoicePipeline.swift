//
//  CascadeVoicePipeline.swift
//  leanring-buddy
//
//  The third voice stack's three legs: mic PCM -> Deepgram streaming STT ->
//  claude-haiku-5-5 (through the worker's `/chat`) -> Deepgram streaming TTS.
//  It replaces only the provider socket: `RealtimeVoiceConnection` still owns the
//  turn, every tool guard, the card hand-off and the notch, so this file knows
//  nothing about tools beyond handing calls up and results back.
//
//  A socket pair per turn, taken at `beginTurn` (once the speech gate heard words):
//  a barge-in closes them, which is what makes a cut-off answer's audio impossible
//  to credit to the new turn. Opening is what costs (measured 2026-11-03 from
//  Sydney: token 0.5-1.0 s, handshake 0.6-1.0 s), so a spare pair is kept warm for
//  `warmSeconds` after each turn; a silent press sends them no audio and no words.
//  No key is in the app: Deepgram gets the worker's 60 s JWT, valid only to open a socket.
//
//  History rule (Haiku 5.5's preserved thinking: a replayed thinking block after a
//  changed prefix is a 400 on new accounts): messages are append-only INSIDE a
//  turn, so a tool round replays its thinking unchanged. Earlier images are dropped
//  and thinking stripped only when a new turn starts, from the front, before any
//  new thinking exists.
//

import Foundation

// MARK: - Pure pieces

/// Text as it streams -> sentences as they complete, so speech starts at the first one.
nonisolated struct CascadeSentenceSplitter {
    private var buffer = ""

    mutating func add(_ text: String) -> [String] {
        buffer += text
        var sentences: [String] = []
        while let sentence = VoiceBenchSentence.firstSentence(in: buffer, textIsComplete: false),
              let range = buffer.range(of: sentence) {
            sentences.append(sentence)
            buffer = String(buffer[range.upperBound...])
        }
        return sentences
    }

    /// The stream ended: whatever is left, even with no full stop.
    mutating func remainder() -> String? {
        defer { buffer = "" }
        let rest = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        return rest.contains(where: { $0.isLetter || $0.isNumber }) ? rest : nil
    }

    /// Markdown a model may still write, which TTS would read aloud or trip on.
    static func spoken(_ sentence: String) -> String {
        sentence.filter { !"*`#".contains($0) }
    }
}

nonisolated enum CascadeDeepgram {
    /// Its own session: a WebSocket holds a connection, the default is 6 per host, and a barge-in chain with spares
    /// reached it (live 2026-11-03, the probe's chain): the seventh handshake just waits, its Speak queued, no error, no audio.
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.httpMaximumConnectionsPerHost = 32
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        return URLSession(configuration: configuration)
    }()
    /// Aura-2's British baritone (developers.deepgram.com/docs/tts-models, read 2026-11-03).
    static let voice = "aura-2-draco-en"
    static let tokenMaximumAgeSeconds: TimeInterval = 45
    /// `from_finalize` is "not guaranteed if there is no significant amount of audio" (docs/finalize, read
    /// 2026-11-03), so the turn goes on with what it has. ponytail: guessed, tune from `cascadeSttFinalMs`.
    static let finalizeDeadlineSeconds: TimeInterval = 1.5
    /// Flushed that never comes must not hold the turn (20 flushes per 60 s is the documented limit; past it no Flushed).
    static let flushDeadlineSeconds: TimeInterval = 10
    /// Spare sockets live this long after a turn; past it the next press pays the handshake.
    /// ponytail: a conversation's gap, guessed. Idle costs a KeepAlive every 4 s (Deepgram drops a silent listen socket at 10 s).
    static let warmSeconds: TimeInterval = 120
    static let keepAliveSeconds: Double = 4

    struct Piece: Equatable {
        let transcript: String
        let isFinal: Bool
        let fromFinalize: Bool
    }

    static func piece(from message: [String: Any]) -> Piece? {
        guard message["type"] as? String == "Results" else { return nil }
        let alternatives = (message["channel"] as? [String: Any])?["alternatives"] as? [[String: Any]]
        return Piece(transcript: alternatives?.first?["transcript"] as? String ?? "",
                     isFinal: message["is_final"] as? Bool == true, fromFinalize: message["from_finalize"] as? Bool == true)
    }

    /// The bench's parameters, plus the installed app names as Nova-3 keyterms: the heard check needs
    /// "Cursor", not "Kasa" (the OpenAI stack's transcription prompt does the same).
    static func listenURL(sampleRate: Int, keyterms: [String]) -> URL {
        var components = URLComponents(string: "wss://api.deepgram.com/v1/listen")!
        components.queryItems = [
            URLQueryItem(name: "model", value: "nova-3"), URLQueryItem(name: "encoding", value: "linear16"),
            URLQueryItem(name: "sample_rate", value: String(sampleRate)), URLQueryItem(name: "channels", value: "1"),
            URLQueryItem(name: "interim_results", value: "true"), URLQueryItem(name: "smart_format", value: "true")
        ] + keyterms.prefix(40).map { URLQueryItem(name: "keyterm", value: $0) }
        return components.url!
    }

    /// PCM16 mono at the session player's rate.
    static func speakURL(sampleRate: Int) -> URL {
        var components = URLComponents(string: "wss://api.deepgram.com/v1/speak")!
        components.queryItems = [
            URLQueryItem(name: "model", value: voice), URLQueryItem(name: "encoding", value: "linear16"),
            URLQueryItem(name: "sample_rate", value: String(sampleRate))
        ]
        return components.url!
    }
}

/// The Messages API's stream -> text as it comes, and the whole message at `message_stop`:
/// thinking blocks with their signatures untouched, tool_use blocks with `input` assembled from its deltas.
nonisolated struct CascadeClaudeStream {
    struct Finished {
        let content: [[String: Any]]
        let stopReason: String?
        let refusalCategory: String?
        let usage: [String: Int]
    }

    enum Event {
        case text(String)
        case finished(Finished)
        case failed(String)
    }

    private var blocks: [Int: [String: Any]] = [:]
    private var toolInputs: [Int: String] = [:]
    private var stopReason: String?
    private var refusalCategory: String?
    private var usage: [String: Int] = [:]

    /// One SSE `data:` payload, without the prefix.
    mutating func feed(data: String) -> [Event] {
        guard let event = try? JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any] else { return [] }
        let index = event["index"] as? Int ?? 0
        switch event["type"] as? String {
        case "message_start":
            addUsage((event["message"] as? [String: Any])?["usage"] as? [String: Any])
        case "content_block_start":
            blocks[index] = event["content_block"] as? [String: Any] ?? [:]
        case "content_block_delta":
            let delta = event["delta"] as? [String: Any] ?? [:]
            switch delta["type"] as? String {
            case "text_delta":
                let text = delta["text"] as? String ?? ""
                blocks[index, default: ["type": "text"]]["text"] = (blocks[index]?["text"] as? String ?? "") + text
                return [.text(text)]
            case "thinking_delta":
                blocks[index, default: ["type": "thinking"]]["thinking"] = (blocks[index]?["thinking"] as? String ?? "") + (delta["thinking"] as? String ?? "")
            case "signature_delta":
                blocks[index]?["signature"] = delta["signature"]
            case "input_json_delta":
                toolInputs[index, default: ""] += delta["partial_json"] as? String ?? ""
            default: break
            }
        case "content_block_stop":
            if blocks[index]?["type"] as? String == "tool_use" {
                // No arguments arrive as no deltas. A broken one becomes {}: the tool answers it with an error.
                let json = toolInputs[index] ?? ""
                blocks[index]?["input"] = json.isEmpty ? [String: Any]()
                    : (try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]) ?? [String: Any]()
            }
        case "message_delta":
            let delta = event["delta"] as? [String: Any]
            if let reason = delta?["stop_reason"] as? String { stopReason = reason }
            refusalCategory = (delta?["stop_details"] as? [String: Any])?["category"] as? String
            addUsage(event["usage"] as? [String: Any])
        case "message_stop":
            return [.finished(Finished(content: blocks.keys.sorted().compactMap { blocks[$0] }, stopReason: stopReason,
                                       refusalCategory: refusalCategory, usage: usage))]
        case "error":
            return [.failed((event["error"] as? [String: Any])?["type"] as? String ?? "unknown")]
        default: break
        }
        return []
    }

    private mutating func addUsage(_ fields: [String: Any]?) {
        for (key, value) in fields ?? [:] { if let number = value as? Int { usage[key] = number } }
    }
}

nonisolated enum CascadeClaude {
    static let model = AgentLoopModel.haiku
    /// Room for adaptive thinking plus a spoken reply; the persona keeps replies short.
    static let maxTokens = 1024
    /// focus -> find -> press is three, `maximumToolCallsPerTurn` is five; one more each for a reply and a re-ask.
    static let maximumRequestsPerTurn = 8
    static let refusalLine = "I'm afraid I can't help with that one."
    /// Trimmed from the front at a turn's start, past this.
    static let maximumHistoryMessages = 40

    /// Adaptive thinking at low effort. Measured 2026-11-03 through the worker: thinking off is ~450 ms faster to first text
    /// (564-663 ms against 1,109-1,141), but "open settings" then spoke and called nothing (0 of 1; adaptive 3 of 3), and a
    /// voice that does not act costs more than 450 ms. `--cascade-thinking-off` re-measures. ponytail: n is small.
    static func requestBody(system: String, tools: [[String: Any]], messages: [[String: Any]],
                            thinkingOn: Bool = !CommandLine.arguments.contains("--cascade-thinking-off")) -> [String: Any] {
        var body: [String: Any] = [
            "model": model, "max_tokens": maxTokens, "stream": true,
            "system": [["type": "text", "text": system, "cache_control": ["type": "ephemeral"]]],
            "tools": tools, "tool_choice": ["type": "auto"],
            "output_config": ["effort": "low"],
            "messages": messages
        ]
        if !thinkingOn { body["thinking"] = ["type": "disabled"] }
        return body
    }

    /// The message as history keeps it: an empty text block is a 400, and max_tokens leaves a tool_use unrunnable.
    static func historyContent(_ finished: Finished) -> [[String: Any]] {
        finished.content.filter { block in
            switch block["type"] as? String {
            case "text": return !(block["text"] as? String ?? "").isEmpty
            case "tool_use": return finished.stopReason != "max_tokens"
            default: return true
            }
        }
    }
    typealias Finished = CascadeClaudeStream.Finished

    /// Thinking blocks of finished turns go (from the front, which the API allows); an assistant left empty goes too.
    static func strippingThinking(_ messages: [[String: Any]]) -> [[String: Any]] {
        messages.compactMap { message in
            guard message["role"] as? String == "assistant", let content = message["content"] as? [[String: Any]] else { return message }
            let kept = content.filter { !["thinking", "redacted_thinking"].contains($0["type"] as? String ?? "") }
            if kept.isEmpty { return nil }
            var message = message
            message["content"] = kept
            return message
        }
    }

    /// At most `limit` messages, starting at a user message that answers no tool_use: the first must be a user's.
    static func trimmed(_ messages: [[String: Any]], limit: Int = maximumHistoryMessages) -> [[String: Any]] {
        guard messages.count > limit else { return messages }
        let tail = messages.suffix(limit)
        let start = tail.firstIndex { message in
            guard message["role"] as? String == "user" else { return false }
            let content = message["content"] as? [[String: Any]] ?? []
            return !content.contains { $0["type"] as? String == "tool_result" }
        }
        return start.map { Array(messages[$0...]) } ?? Array(tail)
    }

    static func imageBlock(_ jpeg: Data) -> [String: Any] {
        ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": jpeg.base64EncodedString()]]
    }
}

// MARK: - The legs

@MainActor
final class CascadeVoicePipeline {
    // Set once by the connection: all it needs to know of a reply.
    var currentTurn: () -> RealtimeTurnMarks? = { nil }
    var onAudio: (Data, TimeInterval) -> Void = { _, _ in }
    var onToolCalls: ([RealtimeToolCall], TimeInterval) -> Void = { _, _ in }
    var onTurnDone: (_ arrival: TimeInterval, _ givingUpOnFollowUp: Bool) -> Void = { _, _ in }
    var onFailed: (String) -> Void = { _ in }

    private let system: String
    private let tools: [[String: Any]]
    private let inputSampleRate: Int
    private let keyterms: [String]
    private var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private var grant: (token: String, fetchedUptime: TimeInterval)?
    private var stt: VoiceBenchWebSocket?
    /// Whose words `stt` is hearing: a warm socket is opened before its turn exists.
    private weak var sttMarks: RealtimeTurnMarks?
    private var finals: [String] = []
    private var warmListening: VoiceBenchWebSocket?
    private var warmSpeaking: VoiceBenchWebSocket?
    private var warmKeeper: Task<Void, Never>?
    private var tts: VoiceBenchWebSocket?
    private var ttsSends: Task<Void, Never>?
    /// A frame may end mid-sample; the next starts with its other byte.
    private var oddByte: UInt8?

    private var history: [[String: Any]] = []
    private var turnStartIndex = 0
    private var pendingImages: [Data] = []
    private var pendingContext: [String] = []
    /// tool_use ids of the last assistant message, in order; results as they come.
    private var unansweredToolUses: [String] = []
    private var toolResults: [String: [String: Any]] = [:]

    private var requestTask: Task<Void, Never>?
    private var requestsThisTurn = 0
    private var splitter = CascadeSentenceSplitter()
    /// Text of the request in flight, nil once it finished: what a barge-in keeps of it.
    private var partialText: String?
    private var sentenceCount = 0
    private var flushedCount = 0
    private var modelDone = false
    private var givingUp = false

    init(system: String, tools: [[String: Any]], inputSampleRate: Int, keyterms: [String]) {
        self.system = system
        self.tools = tools
        self.inputSampleRate = inputSampleRate
        self.keyterms = keyterms
    }

    // MARK: Connection

    func connect() async throws {
        _ = try await validToken()
        warmUp()
    }

    func close() {
        cancelReply()
        stt?.close()
        stt = nil
        closeWarm()
    }

    private func closeWarm() {
        warmKeeper?.cancel()
        warmKeeper = nil
        warmListening?.close()
        warmListening = nil
        warmSpeaking?.close()
        warmSpeaking = nil
    }

    /// A spare pair for the next turn, and the deadline restarted.
    private func warmUp() {
        warmKeeper?.cancel()
        warmKeeper = Task { @MainActor [weak self] in
            guard let self, let token = try? await self.validToken(), !Task.isCancelled else { return }
            if self.warmListening == nil { self.warmListening = self.openListening(token: token) }
            if self.warmSpeaking == nil { self.warmSpeaking = self.openSpeech(token: token) }
            let deadline = self.uptime + CascadeDeepgram.warmSeconds
            while self.uptime < deadline {
                try? await Task.sleep(for: .seconds(CascadeDeepgram.keepAliveSeconds))
                guard !Task.isCancelled else { return }
                try? await self.warmListening?.sendJSON(["type": "KeepAlive"])
            }
            self.warmKeeper = nil
            self.closeWarm()
        }
    }

    private func validToken() async throws -> String {
        if let grant, uptime - grant.fetchedUptime < CascadeDeepgram.tokenMaximumAgeSeconds { return grant.token }
        let response = try await VoiceStackBenchmark.fetchWorkerJSON(routePath: "/deepgram-token", stage: "cascade:token")
        guard let token = response["access_token"] as? String else { throw VoiceBenchFailure(kind: "cascade:token:noAccessToken") }
        grant = (token, uptime)
        return token
    }

    private func deepgramSocket(_ url: URL, token: String) -> VoiceBenchWebSocket {
        var request = URLRequest(url: url)
        // A grant JWT is presented as Bearer; the long-lived key would be `Token`.
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return VoiceBenchWebSocket(request: request, session: CascadeDeepgram.session)
    }

    // MARK: Context

    func add(image jpeg: Data) { pendingImages.append(jpeg) }
    func add(context text: String) { pendingContext.append(text) }

    /// The press (before anything of the new turn arrives): the reply stops here. What the cut-off turn
    /// gathered goes if its request never left; a line told to an answered turn stays for the next.
    func cancelForPress() {
        if stt != nil {
            pendingImages = []
            pendingContext = []
            stt?.close()
            stt = nil
        }
        cancelReply()
        warmUp()
    }

    private func cancelReply() {
        requestTask?.cancel()
        requestTask = nil
        if let partialText, !partialText.isEmpty {
            history.append(["role": "assistant", "content": [["type": "text", "text": partialText]]])
        }
        partialText = nil
        tts?.close()
        tts = nil
        ttsSends?.cancel()
        ttsSends = nil
        oddByte = nil
        splitter = CascadeSentenceSplitter()
        sentenceCount = 0
        flushedCount = 0
        modelDone = false
        givingUp = false
    }

    // MARK: Owner turn

    func beginOwnerTurn(marks: RealtimeTurnMarks) async throws {
        cancelReply()
        stt?.close()
        stt = nil
        finals = []
        sttMarks = marks
        let listening: VoiceBenchWebSocket
        if let warm = warmListening {
            listening = warm
            warmListening = nil
        } else {
            listening = openListening(token: try await validToken())
        }
        stt = listening
        tts = try await takeSpeech()
    }

    private func takeSpeech() async throws -> VoiceBenchWebSocket {
        oddByte = nil
        if let warm = warmSpeaking {
            warmSpeaking = nil
            return warm
        }
        return openSpeech(token: try await validToken())
    }

    private func openListening(token: String) -> VoiceBenchWebSocket {
        let listening = deepgramSocket(CascadeDeepgram.listenURL(sampleRate: inputSampleRate, keyterms: keyterms), token: token)
        listening.start(onMessage: { [weak self] message, arrival in
            guard let self, self.stt === listening, let marks = self.sttMarks, let piece = CascadeDeepgram.piece(from: message) else { return }
            if piece.isFinal, !piece.transcript.isEmpty { self.finals.append(piece.transcript) }
            // Partials too, as Gemini's pieces: "stop" stops a task while the owner still says it.
            marks.heardText = (self.finals + (piece.isFinal ? [] : [piece.transcript])).joined(separator: " ")
            if piece.fromFinalize { self.heardAll(marks: marks, arrival: arrival) }
        }, onEnd: { [weak self] error in
            guard let self else { return }
            if self.warmListening === listening { self.warmListening = nil }
            guard self.stt === listening else { return }
            if let marks = self.sttMarks, marks.lastAudioSentUptime != nil {
                self.heardAll(marks: marks, arrival: self.uptime)
            } else {
                self.onFailed(listening.failureKind(for: error, stage: "cascade:stt"))
            }
        })
        return listening
    }

    /// Queued by the socket until its handshake is done, in order.
    func sendAudio(_ pcmChunk: Data) async throws {
        try await stt?.task.send(.data(pcmChunk))
    }

    /// The release. `marks.lastAudioSentUptime` is set: the clock runs.
    func endOwnerTurn(marks: RealtimeTurnMarks) async throws {
        guard let listening = stt else { return heardAll(marks: marks, arrival: uptime) }
        try await listening.sendJSON(["type": "Finalize"])
        Task { @MainActor [weak self, weak marks] in
            try? await Task.sleep(for: .seconds(CascadeDeepgram.finalizeDeadlineSeconds))
            guard let self, let marks, self.stt === listening else { return }
            marks.events.append(("stt.noFinalize", self.uptime))
            self.heardAll(marks: marks, arrival: self.uptime)
        }
    }

    /// The owner's words are in: the heard check can read them, and the model is asked.
    private func heardAll(marks: RealtimeTurnMarks, arrival: TimeInterval) {
        guard let listening = stt else { return }
        stt = nil
        Task { try? await listening.sendJSON(["type": "CloseStream"]); listening.close() }
        marks.heardCompleteUptime = arrival
        marks.cascadeSttFinalUptime = arrival
        marks.events.append(("stt.final", arrival))
        guard currentTurn() === marks, !marks.supersededByPress else { return }
        let words = SecretScanner.redact(marks.heardText.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !words.isEmpty else {
            // The gate heard a voice and Deepgram no words: nothing to ask; the notch says "No reply".
            marks.events.append(("stt.empty", arrival))
            pendingImages = []
            pendingContext = []
            cancelReply()
            warmUp()
            return onTurnDone(arrival, false)
        }
        beginHistoryTurn(lastText: words)
        startRequest(marks: marks)
    }

    // MARK: System turn

    func beginSystemTurn(text: String, marks: RealtimeTurnMarks) async throws {
        cancelForPress()
        tts = try await takeSpeech()
        guard currentTurn() === marks else { return }
        beginHistoryTurn(lastText: text)
        startRequest(marks: marks)
    }

    // MARK: History

    /// The one place history is edited: nothing thinking-bound of this turn exists yet.
    private func beginHistoryTurn(lastText: String) {
        answerToolUsesLeftOpen()
        var content = pendingImages.map(CascadeClaude.imageBlock)
        content += pendingContext.map { ["type": "text", "text": $0] }
        content.append(["type": "text", "text": lastText])
        pendingImages = []
        pendingContext = []
        requestsThisTurn = 0
        history = AgentLoop.keepingLatestImage(CascadeClaude.trimmed(CascadeClaude.strippingThinking(history) + [["role": "user", "content": content]]))
        turnStartIndex = history.count - 1
    }

    /// A press while a call ran: every tool_use still needs its result, or the next request is a 400.
    private func answerToolUsesLeftOpen() {
        guard !unansweredToolUses.isEmpty else { return }
        history.append(["role": "user", "content": unansweredToolUses.map { id in
            toolResults[id] ?? ["type": "tool_result", "tool_use_id": id,
                                "content": "the owner started a new request before this call's result was read"]
        }])
        unansweredToolUses = []
        toolResults = [:]
    }

    /// `block`: `RealtimeVoiceConnection.toolResultMessage`'s. One the owner already moved past reaches the
    /// next request as context, so the model still knows what was actually done.
    func add(toolResult block: [String: Any]) {
        guard let id = block["tool_use_id"] as? String else { return }
        if unansweredToolUses.contains(id) {
            toolResults[id] = block
        } else {
            pendingContext.append("system context, not the owner's words: a tool call from an earlier request finished after the owner "
                + "moved on. Its result: \(block["content"] as? String ?? "{}")")
        }
    }

    /// All of an assistant message's results are in: they go in one user message, first (the API's rule).
    func continueAfterTools(marks: RealtimeTurnMarks) {
        var content = unansweredToolUses.compactMap { toolResults[$0] }
        content += pendingImages.map(CascadeClaude.imageBlock)
        content += pendingContext.map { ["type": "text", "text": $0] }
        pendingImages = []
        pendingContext = []
        unansweredToolUses = []
        toolResults = [:]
        history.append(["role": "user", "content": content])
        guard requestsThisTurn < CascadeClaude.maximumRequestsPerTurn else {
            marks.events.append(("claude.requestCap", uptime))
            givingUp = true
            return modelFinished(marks: marks)
        }
        startRequest(marks: marks)
    }

    // MARK: Claude

    private func startRequest(marks: RealtimeTurnMarks) {
        requestsThisTurn += 1
        partialText = ""
        splitter = CascadeSentenceSplitter()
        if marks.cascadeRequestUptime == nil { marks.cascadeRequestUptime = uptime }
        let body = CascadeClaude.requestBody(system: system, tools: tools, messages: history)
        requestTask = Task { @MainActor [weak self, weak marks] in
            guard let self, let marks else { return }
            await self.stream(body, marks: marks)
        }
    }

    private func stream(_ body: [String: Any], marks: RealtimeTurnMarks) async {
        do {
            var request = URLRequest(url: WorkerConfiguration.routeURL("/chat"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            WorkerConfiguration.attachClientKey(to: &request)
            // Sorted: the same tools and system are the same bytes, which is what the prompt cache matches.
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
            let (bytes, response) = try await VoiceStackBenchmark.benchURLSession.bytes(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard (200...299).contains(status) else {
                bytes.task.cancel()
                throw VoiceBenchFailure(kind: "cascade:claude:http\(status)")
            }
            var parser = CascadeClaudeStream()
            for try await line in bytes.lines {
                guard !Task.isCancelled else { return }
                guard line.hasPrefix("data:") else { continue }
                let arrival = uptime
                for event in parser.feed(data: String(line.dropFirst(5))) {
                    switch event {
                    case .text(let text): received(text: text, marks: marks, arrival: arrival)
                    case .finished(let finished): return finishedMessage(finished, marks: marks, arrival: arrival)
                    case .failed(let type): throw VoiceBenchFailure(kind: "cascade:claude:\(type)")
                    }
                }
            }
            throw VoiceBenchFailure(kind: "cascade:claude:streamEnded")
        } catch {
            guard !Task.isCancelled else { return }
            onFailed((error as? VoiceBenchFailure)?.kind ?? VoiceBenchRun.errorKind(for: error, stage: "cascade:claude"))
        }
    }

    private func received(text: String, marks: RealtimeTurnMarks, arrival: TimeInterval) {
        if marks.cascadeFirstTextUptime == nil {
            marks.cascadeFirstTextUptime = arrival
            marks.events.append(("claude.firstText", arrival))
        }
        partialText = (partialText ?? "") + text
        marks.transcript += text
        for sentence in splitter.add(text) { speak(sentence, marks: marks) }
    }

    private func finishedMessage(_ finished: CascadeClaudeStream.Finished, marks: RealtimeTurnMarks, arrival: TimeInterval) {
        let spokeThisRequest = !(partialText ?? "").isEmpty
        partialText = nil
        marks.events.append(("claude.stop:\(finished.stopReason ?? "-")", arrival))
        for (key, value) in finished.usage { marks.cascadeUsage[key, default: 0] += value }
        marks.cascadeThinkingBlocks += finished.content.filter { $0["type"] as? String == "thinking" }.count
        if let rest = splitter.remainder() { speak(rest, marks: marks) }

        if finished.stopReason == "refusal" {
            // No fallback on this model. Neither the request nor its reply stays: replayed, it would be refused again.
            marks.events.append(("claude.refusal:\(finished.refusalCategory ?? "-")", arrival))
            history.removeSubrange(min(turnStartIndex, history.count)...)
            unansweredToolUses = []
            toolResults = [:]
            marks.transcript += CascadeClaude.refusalLine
            speak(CascadeClaude.refusalLine, marks: marks)
            return modelFinished(marks: marks)
        }
        let content = CascadeClaude.historyContent(finished)
        if !content.isEmpty { history.append(["role": "assistant", "content": content]) }

        let calls = content.filter { $0["type"] as? String == "tool_use" }.compactMap { block -> RealtimeToolCall? in
            guard let id = block["id"] as? String, let name = block["name"] as? String else { return nil }
            return RealtimeToolCall.parsed(callID: id, name: name, arguments: block["input"] as? [String: Any])
        }
        if finished.stopReason == "tool_use", !calls.isEmpty {
            unansweredToolUses = calls.map(\.callID)
            return onToolCalls(calls, arrival)
        }
        // After tool results, an answer with no words: asked once more, as the OpenAI path does.
        if !marks.toolCalls.isEmpty, !spokeThisRequest {
            guard !marks.emptyFollowUpReasked, requestsThisTurn < CascadeClaude.maximumRequestsPerTurn else {
                givingUp = true
                return modelFinished(marks: marks)
            }
            marks.emptyFollowUpReasked = true
            marks.events.append(("emptyFollowUp", arrival))
            marks.toolResultSentUptime = uptime
            history.append(["role": "user", "content": [["type": "text", "text": RealtimeVoiceConnection.emptyFollowUpReaskText]]])
            return startRequest(marks: marks)
        }
        modelFinished(marks: marks)
    }

    // MARK: Speech

    private func openSpeech(token: String) -> VoiceBenchWebSocket {
        let speaking = deepgramSocket(CascadeDeepgram.speakURL(sampleRate: VoiceStackChoice.outputSampleRate), token: token)
        speaking.start(onMessage: { [weak self] message, arrival in
            guard let self, self.tts === speaking else { return }
            switch message["type"] as? String {
            case "Flushed":
                self.flushedCount += 1
                self.finishIfSpoken(arrival: arrival)
            case "Warning":
                self.currentTurn()?.events.append(("tts.warning:\(message["code"] as? String ?? "-")", arrival))
            default: break
            }
        }, onEnd: { [weak self] error in
            guard let self else { return }
            if self.warmSpeaking === speaking { self.warmSpeaking = nil }
            guard self.tts === speaking else { return }
            // Idle through a long hold or a card: Deepgram may close it, and the next sentence opens another.
            self.tts = nil
            if self.flushedCount < self.sentenceCount { self.onFailed(speaking.failureKind(for: error, stage: "cascade:tts")) }
        }, onBinary: { [weak self] audio, arrival in
            guard let self, self.tts === speaking else { return }
            self.receivedSpeech(audio, arrival: arrival)
        })
        return speaking
    }

    private func receivedSpeech(_ frame: Data, arrival: TimeInterval) {
        var audio = Data(capacity: frame.count + 1)
        if let oddByte { audio.append(oddByte) }
        audio.append(frame)
        oddByte = audio.count % 2 == 1 ? audio.removeLast() : nil
        if !audio.isEmpty { onAudio(audio, arrival) }
    }

    /// Each sentence is flushed: audio starts at the first, while Claude still writes the rest.
    private func speak(_ sentence: String, marks: RealtimeTurnMarks) {
        let text = SecretScanner.redact(CascadeSentenceSplitter.spoken(sentence))
        guard !text.isEmpty else { return }
        if marks.cascadeFirstSpeakUptime == nil { marks.cascadeFirstSpeakUptime = uptime }
        sentenceCount += 1
        // In order: two Tasks' sends may overtake each other.
        let previous = ttsSends
        ttsSends = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled else { return }
            do {
                if self.tts == nil { self.tts = try await self.takeSpeech() }
                guard let speaking = self.tts, !Task.isCancelled else { return }
                try await speaking.sendJSON(["type": "Speak", "text": text])
                try await speaking.sendJSON(["type": "Flush"])
            } catch {
                guard !Task.isCancelled else { return }
                self.onFailed((error as? VoiceBenchFailure)?.kind ?? self.tts?.failureKind(for: error, stage: "cascade:tts")
                    ?? VoiceBenchRun.errorKind(for: error, stage: "cascade:tts"))
            }
        }
    }

    private func modelFinished(marks: RealtimeTurnMarks) {
        modelDone = true
        finishIfSpoken(arrival: uptime)
        guard modelDone else { return }
        let speaking = tts
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(CascadeDeepgram.flushDeadlineSeconds))
            guard let self, self.tts === speaking, self.modelDone else { return }
            marks.events.append(("tts.noFlushed", self.uptime))
            // Not one sample of what it was asked to say: that is a failed leg, never a silent turn.
            if marks.firstAudioUptime == nil { return self.onFailed("cascade:tts:noAudio") }
            self.givingUp = self.givingUp || !marks.toolCalls.isEmpty
            self.flushedCount = self.sentenceCount
            self.finishIfSpoken(arrival: self.uptime)
        }
    }

    /// The model is done and every sentence's audio has arrived: the turn is over.
    private func finishIfSpoken(arrival: TimeInterval) {
        guard modelDone, flushedCount >= sentenceCount else { return }
        let speaking = tts
        let gaveUp = givingUp
        tts = nil
        modelDone = false
        givingUp = false
        Task { try? await speaking?.sendJSON(["type": "Close"]); speaking?.close() }
        warmUp()
        onTurnDone(arrival, gaveUp)
    }

    /// The turn failed: the connection fails it on the shared path. Nothing is left running.
    func stopAfterFailure() {
        stt?.close()
        stt = nil
        cancelReply()
        warmUp()
    }
}
