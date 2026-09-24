//
//  RealtimeVoiceConnection.swift
//  leanring-buddy
//
//  One open speech-to-speech session — OpenAI Realtime or Gemini Live — with the
//  `open_app` tool declared and answered. Shared by the live push-to-talk loop
//  (`RealtimeVoiceSession`) and `--voice-tool-probe`, so the probe measures the
//  exact tool path the owner talks to.
//
//  Wire shapes are the bench's (`VoiceStackBenchmark.measureOpenAIRealtime` /
//  `measureSpeechToSpeech`), which were probed live 2026-09-23; this file adds
//  the tool declaration, the tool-call events and the result round trip.
//
//  A turn is over when the provider says its answer is done AND no tool call is
//  in flight AND — if a tool ran — the model has spoken since its result was
//  sent. The last clause exists because the model's first answer (the one that
//  CALLED the tool) also ends with a done event; finishing there would measure
//  the call, not the answer the user waits for.
//

import Foundation

/// Everything one turn did, in uptime seconds. The probe turns these into
/// milliseconds from `lastAudioSentUptime`, the push-to-talk release.
@MainActor
final class RealtimeTurnMarks {
    var lastAudioSentUptime: TimeInterval?
    var firstAudioUptime: TimeInterval?
    var toolCallUptime: TimeInterval?
    var toolCalls: [RealtimeToolCall] = []
    var dispatches: [RealtimeToolDispatch] = []
    var toolResultSentUptime: TimeInterval?
    var followUpFirstAudioUptime: TimeInterval?
    /// The first confirmed call's fresh look: "pending" while in flight, then
    /// "attached" or the refusal code; ms from the harness answer to the image
    /// sent, and the bytes sent.
    var freshLookOutcome: String?
    var freshLookMilliseconds: Int?
    var freshLookImageBytes: Int?
    var freshLookCompletedUptime: TimeInterval?
    /// Set when the turn finishes; audio after it is a reply nobody asked for.
    var finishedUptime: TimeInterval?
    var audioChunksAfterFinish = 0
    var transcript = ""
    var outputAudioMime: String?
    var toolsInFlight = 0
    /// Event names only, never content, each with its arrival in ms after the
    /// release — so a turn that stalls says what it last heard.
    var eventTrail: [String] = []
    let finished = VoiceBenchWaiter<TimeInterval>()

    /// The look runs past the spoken result, so a line written at turn end waits
    /// for it (bounded) rather than logging "pending".
    func waitForFreshLook(timeoutSeconds: Double = 5) async {
        let deadline = ProcessInfo.processInfo.systemUptime + timeoutSeconds
        while freshLookOutcome == "pending", ProcessInfo.processInfo.systemUptime < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Positive: the image landed while (or after) the model was already speaking.
    var freshLookArrivedAfterSpeechStartMs: Int? {
        guard let completed = freshLookCompletedUptime, let spoke = followUpFirstAudioUptime else { return nil }
        return Int(((completed - spoke) * 1000).rounded())
    }
}

@MainActor
final class RealtimeVoiceConnection {
    let stack: VoiceStackChoice
    private let harnessAnswer: @Sendable (String) -> String
    private var socket: VoiceBenchWebSocket?
    private let readyWaiter = VoiceBenchWaiter<TimeInterval>()
    private(set) var isOpen = false
    private(set) var turn = RealtimeTurnMarks()
    /// OpenAI only: `response.create` while a response is live is refused
    /// (`conversation_already_has_active_response`), so a tool result waits for it.
    private var openAIResponseActive = false
    /// OpenAI only, from each `response.done`'s usage; a response with no usage
    /// is charged the bench's ceiling, never 0.
    private(set) var estimatedOpenAIUSD = 0.0

    /// PCM16 mono 24 kHz, as it arrives.
    var onAudio: ((Data) -> Void)?
    var onTurnFinished: (() -> Void)?
    var onClosed: (() -> Void)?

    /// A model that keeps calling the tool is answered with an error after this
    /// many calls in one turn, not left to loop against the harness.
    static let maximumToolCallsPerTurn = 3
    static let openAIMaxOutputTokens = VoiceStackBenchmark.openAIRealtimeMaxOutputTokens
    /// The J.A.R.V.I.S. voices, live loop only — the bench keeps "marin" and
    /// Gemini's default as its control. OpenAI lists ten realtime voices and
    /// recommends marin or cedar for quality; cedar is the lower, more measured
    /// of the two. Gemini Live takes any of the 30 TTS voices; Charon is listed
    /// "Informative", a low, even delivery (both docs read 2026-09-24).
    static let openAIVoice = "cedar"
    static let geminiVoice = "Charon"

    init(stack: VoiceStackChoice, harnessAnswer: @escaping @Sendable (String) -> String) {
        self.stack = stack
        self.harnessAnswer = harnessAnswer
    }

    private var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }

    // MARK: Connect

    /// Token + socket + session config, until the server acknowledges it
    /// (~2 s, which is why the live loop pre-warms). The ephemeral secret only
    /// has to be valid at connect time (OpenAI 60 s, Gemini newSessionExpireTime
    /// 60 s — `worker/src/index.ts`); an open session outlives it.
    func connect() async throws {
        switch stack {
        case .openAIRealtime:
            let tokenResponse = try await VoiceStackBenchmark.fetchWorkerJSON(routePath: "/openai-realtime-token", stage: "openAIToken")
            guard let ephemeralKey = tokenResponse["token"] as? String else { throw VoiceBenchFailure(kind: "openAIToken:noToken") }
            var components = URLComponents(string: "wss://api.openai.com/v1/realtime")!
            components.queryItems = [URLQueryItem(name: "model", value: VoiceStackBenchmark.openAIRealtimeModel)]
            var request = URLRequest(url: components.url!)
            request.setValue("Bearer \(ephemeralKey)", forHTTPHeaderField: "Authorization")
            try await open(request)
            try await socket?.sendJSON([
                "type": "session.update",
                "session": [
                    "type": "realtime",
                    "instructions": RealtimeOpenAppTool.systemPrompt,
                    "output_modalities": ["audio"],
                    "max_output_tokens": Self.openAIMaxOutputTokens,
                    "tools": [RealtimeOpenAppTool.openAIDeclaration],
                    "tool_choice": "auto",
                    "audio": [
                        // Push-to-talk: we commit, the server's VAD does not decide.
                        "input": ["format": ["type": "audio/pcm", "rate": 24_000], "turn_detection": NSNull()],
                        // The rate is required even though 24 kHz is the only one (probed 2026-09-23).
                        "output": ["format": ["type": "audio/pcm", "rate": 24_000], "voice": Self.openAIVoice]
                    ]
                ]
            ])
        case .geminiLive:
            let tokenResponse = try await VoiceStackBenchmark.fetchWorkerJSON(routePath: "/gemini-live-token", stage: "geminiToken")
            guard let ephemeralToken = tokenResponse["token"] as? String else { throw VoiceBenchFailure(kind: "geminiToken:noToken") }
            var components = URLComponents(string: VoiceStackBenchmark.geminiLiveConstrainedURL)!
            components.queryItems = [URLQueryItem(name: "access_token", value: ephemeralToken)]
            try await open(URLRequest(url: components.url!))
            try await socket?.sendJSON([
                "setup": [
                    "model": "models/\(VoiceStackBenchmark.geminiLiveModel)",
                    "generationConfig": [
                        "responseModalities": ["AUDIO"], "thinkingConfig": ["thinkingLevel": "MINIMAL"],
                        "speechConfig": ["voiceConfig": ["prebuiltVoiceConfig": ["voiceName": Self.geminiVoice]]]
                    ],
                    "systemInstruction": ["parts": [["text": RealtimeOpenAppTool.systemPrompt]]],
                    "tools": [RealtimeOpenAppTool.geminiDeclaration],
                    "realtimeInputConfig": ["automaticActivityDetection": ["disabled": true]],
                    // What the model said, for the probe's answers file and the honesty check.
                    "outputAudioTranscription": [String: Any]()
                ]
            ])
        }
        _ = try await readyWaiter.value(timeoutSeconds: 10, timeoutKind: "\(stack.rawValue):setupTimeout")
        isOpen = true
    }

    private func open(_ request: URLRequest) async throws {
        let socket = VoiceBenchWebSocket(request: request, session: VoiceStackBenchmark.benchURLSession)
        self.socket = socket
        socket.start(onMessage: { [weak self] message, arrivalUptime in
            self?.handle(message, arrivalUptime: arrivalUptime)
        }, onEnd: { [weak self] error in
            guard let self else { return }
            let failureKind = socket.failureKind(for: error, stage: self.stack.rawValue)
            self.isOpen = false
            self.readyWaiter.settle(.failure(VoiceBenchFailure(kind: failureKind)))
            self.turn.finished.settle(.failure(VoiceBenchFailure(kind: failureKind)))
            self.onClosed?()
        })
    }

    func close() {
        isOpen = false
        socket?.close()
        socket = nil
    }

    // MARK: A turn

    /// Before `beginTurn`, off the audio clock, as the bench does it — and after a
    /// verified `open_app`, as context the model is not asked to answer.
    func sendScreenshot(_ jpegData: Data) async throws {
        let base64Image = jpegData.base64EncodedString()
        switch stack {
        case .openAIRealtime:
            try await socket?.sendJSON([
                "type": "conversation.item.create",
                "item": ["type": "message", "role": "user", "content": [["type": "input_image", "image_url": "data:image/jpeg;base64," + base64Image]]]
            ])
        case .geminiLive:
            try await socket?.sendJSON(["realtimeInput": ["video": ["mimeType": "image/jpeg", "data": base64Image]]])
        }
    }

    func beginTurn() async throws {
        turn = RealtimeTurnMarks()
        switch stack {
        case .openAIRealtime: try await socket?.sendJSON(["type": "input_audio_buffer.clear"])
        case .geminiLive: try await socket?.sendJSON(["realtimeInput": ["activityStart": [String: Any]()]])
        }
    }

    /// PCM16 mono at `stack.inputSampleRate`.
    func appendAudio(_ pcmData: Data) async throws {
        switch stack {
        case .openAIRealtime:
            try await socket?.sendJSON(["type": "input_audio_buffer.append", "audio": pcmData.base64EncodedString()])
        case .geminiLive:
            try await socket?.sendJSON(["realtimeInput": ["audio": ["mimeType": "audio/pcm;rate=16000", "data": pcmData.base64EncodedString()]]])
        }
    }

    /// The push-to-talk release, stated to the server.
    func endTurn() async throws {
        turn.lastAudioSentUptime = uptime
        switch stack {
        case .openAIRealtime:
            try await socket?.sendJSON(["type": "input_audio_buffer.commit"])
            try await socket?.sendJSON(["type": "response.create"])
        case .geminiLive:
            try await socket?.sendJSON(["realtimeInput": ["activityEnd": [String: Any]()]])
        }
    }

    /// Barge-in. Gemini needs nothing: the next `activityStart` interrupts it.
    /// ponytail: OpenAI's server-side transcript still holds the unplayed tail of
    /// the cancelled answer; `conversation.item.truncate` fixes that if it matters.
    func cancelResponse() {
        guard stack == .openAIRealtime, openAIResponseActive else { return }
        Task { try? await socket?.sendJSON(["type": "response.cancel"]) }
    }

    // MARK: Server events

    private func handle(_ message: [String: Any], arrivalUptime: TimeInterval) {
        recordEvent(message, arrivalUptime: arrivalUptime)
        switch stack {
        case .openAIRealtime: handleOpenAI(message, arrivalUptime: arrivalUptime)
        case .geminiLive: handleGemini(message, arrivalUptime: arrivalUptime)
        }
    }

    private func handleOpenAI(_ message: [String: Any], arrivalUptime: TimeInterval) {
        switch message["type"] as? String {
        case "session.updated":
            readyWaiter.settle(.success(arrivalUptime))
        case "response.created":
            openAIResponseActive = true
        case "response.output_audio.delta":
            if let audio = Data(base64Encoded: message["delta"] as? String ?? "") { receivedAudio(audio, arrivalUptime: arrivalUptime) }
        case "response.output_audio_transcript.delta":
            turn.transcript += message["delta"] as? String ?? ""
        case "response.output_item.done":
            if let call = RealtimeOpenAppTool.parseOpenAI(message) { receivedToolCalls([call], arrivalUptime: arrivalUptime) }
        case "response.done":
            openAIResponseActive = false
            let response = message["response"] as? [String: Any]
            if let usage = response?["usage"] as? [String: Any],
               let responseUSD = VoiceBenchRealtimeCost.estimatedUSD(flattenedUsage: VoiceBenchRealtimeCost.flattenedUsage(usage)) {
                estimatedOpenAIUSD += responseUSD
            } else {
                estimatedOpenAIUSD += VoiceStackBenchmark.openAIRealtimeMissingUsageCeilingUSD
            }
            receivedTurnDone(arrivalUptime: arrivalUptime)
        case "error":
            // Console only: the message is the server's text.
            let serverError = message["error"] as? [String: Any]
            print("🎙️ realtime: OpenAI error \(serverError?["code"] ?? "-"): \(serverError?["message"] ?? "-")")
            let failure = VoiceBenchFailure(kind: "openAI:serverError:\(serverError?["code"] as? String ?? "-")")
            readyWaiter.settle(.failure(failure))
            turn.finished.settle(.failure(failure))
        default:
            break
        }
    }

    private func handleGemini(_ message: [String: Any], arrivalUptime: TimeInterval) {
        if message["setupComplete"] != nil {
            readyWaiter.settle(.success(arrivalUptime))
        }
        let calls = RealtimeOpenAppTool.parseGemini(message)
        if !calls.isEmpty { receivedToolCalls(calls, arrivalUptime: arrivalUptime) }
        guard let serverContent = message["serverContent"] as? [String: Any] else { return }
        if let spokenPiece = (serverContent["outputTranscription"] as? [String: Any])?["text"] as? String {
            turn.transcript += spokenPiece
        }
        if let parts = (serverContent["modelTurn"] as? [String: Any])?["parts"] as? [[String: Any]] {
            for part in parts {
                guard let inlineData = part["inlineData"] as? [String: Any],
                      let mimeType = inlineData["mimeType"] as? String, mimeType.hasPrefix("audio/"),
                      let audio = Data(base64Encoded: inlineData["data"] as? String ?? "") else { continue }
                if turn.outputAudioMime == nil { turn.outputAudioMime = mimeType }
                receivedAudio(audio, arrivalUptime: arrivalUptime)
            }
        }
        if serverContent["turnComplete"] as? Bool == true {
            receivedTurnDone(arrivalUptime: arrivalUptime)
        }
    }

    private func recordEvent(_ message: [String: Any], arrivalUptime: TimeInterval) {
        guard let released = turn.lastAudioSentUptime, turn.eventTrail.count < 200 else { return }
        var names: [String]
        if let type = message["type"] as? String {
            names = [type]
        } else {
            names = message.keys.sorted()
            if let serverContent = message["serverContent"] as? [String: Any] { names += serverContent.keys.sorted().map { "serverContent." + $0 } }
        }
        // Audio and transcript deltas would drown the trail; their first arrival is already a mark.
        names.removeAll { $0.hasSuffix(".delta") || $0 == "serverContent" || $0 == "serverContent.outputTranscription" }
        guard !names.isEmpty else { return }
        let elapsedMilliseconds = Int(((arrivalUptime - released) * 1000).rounded())
        let entry = names.joined(separator: "+") + "@\(elapsedMilliseconds)"
        if turn.eventTrail.last?.hasPrefix(names.joined(separator: "+") + "@") == true, names == ["serverContent.modelTurn"] { return }
        turn.eventTrail.append(entry)
    }

    private func receivedAudio(_ audio: Data, arrivalUptime: TimeInterval) {
        if turn.finishedUptime != nil { turn.audioChunksAfterFinish += 1 }
        if turn.firstAudioUptime == nil { turn.firstAudioUptime = arrivalUptime }
        if turn.toolResultSentUptime != nil, turn.followUpFirstAudioUptime == nil { turn.followUpFirstAudioUptime = arrivalUptime }
        onAudio?(audio)
    }

    private func receivedTurnDone(arrivalUptime: TimeInterval) {
        let turn = self.turn
        guard turn.toolsInFlight == 0 else { return }
        if !turn.toolCalls.isEmpty {
            guard let resultSent = turn.toolResultSentUptime, arrivalUptime > resultSent, turn.followUpFirstAudioUptime != nil else { return }
        }
        if turn.finishedUptime == nil { turn.finishedUptime = arrivalUptime }
        turn.finished.settle(.success(arrivalUptime))
        onTurnFinished?()
    }

    // MARK: Tool calls

    private func receivedToolCalls(_ calls: [RealtimeToolCall], arrivalUptime: TimeInterval) {
        let turn = self.turn
        if turn.toolCallUptime == nil { turn.toolCallUptime = arrivalUptime }
        for call in calls {
            turn.toolCalls.append(call)
            turn.toolsInFlight += 1
            let overLimit = turn.toolCalls.count > Self.maximumToolCallsPerTurn
            Task { @MainActor [weak self] in
                let dispatch: RealtimeToolDispatch
                if overLimit {
                    let refusal = RealtimeToolRefusal(error: "tooManyToolCalls", message: "only \(Self.maximumToolCallsPerTurn) tool calls are allowed per turn")
                    dispatch = RealtimeToolDispatch(result: RealtimeOpenAppTool.toolResult(for: refusal), harnessMilliseconds: 0,
                                                    waitedForConfirmation: false, harnessResponse: nil)
                } else {
                    // `dispatch` hops off main for every harness call.
                    guard let harnessAnswer = self?.harnessAnswer else { return }
                    dispatch = await RealtimeOpenAppTool.dispatch(call, answer: harnessAnswer)
                }
                turn.dispatches.append(dispatch)
                // The harness's verification is the proof, so the result goes now and
                // the model confirms the outcome. The model's only picture is the
                // key-down one, of the app in front BEFORE this launch, so the new
                // app is looked at in parallel and added as context once it arrives,
                // without asking for a reply (owner's ruling 2026-09-24).
                if dispatch.harnessConfirmed, call.name == RealtimeOpenAppTool.name, turn.freshLookOutcome == nil,
                   let harnessAnswer = self?.harnessAnswer {
                    turn.freshLookOutcome = "pending"
                    Task { @MainActor [weak self] in await self?.addFreshLook(afterLaunchResponse: dispatch.harnessResponse, answer: harnessAnswer, to: turn) }
                }
                await self?.sendToolResult(dispatch.result, for: call, in: turn)
            }
        }
    }

    /// Context only: OpenAI gets a user image item and no `response.create`;
    /// Gemini a `realtimeInput` frame with no activity markers. The probe counts
    /// any audio after the turn finished, which is what a reply to it would be.
    private func addFreshLook(afterLaunchResponse launchResponse: [String: Any]?,
                              answer: @escaping @Sendable (String) -> String, to turn: RealtimeTurnMarks) async {
        let lookStart = uptime
        var look = await RealtimeOpenAppTool.freshLook(afterLaunchResponse: launchResponse, answer: answer)
        if case .image(let jpeg) = look {
            do { try await sendScreenshot(jpeg) } catch { look = .unavailable(error: "imageSendFailed") }
        }
        turn.freshLookOutcome = look.outcome
        turn.freshLookCompletedUptime = uptime
        turn.freshLookMilliseconds = Int(((uptime - lookStart) * 1000).rounded())
        if case .image(let jpeg) = look { turn.freshLookImageBytes = jpeg.count }
        if case .unavailable(let error) = look { print("🎙️ realtime: no fresh look after open_app: \(error)") }
    }

    private func sendToolResult(_ result: [String: Any], for call: RealtimeToolCall, in turn: RealtimeTurnMarks) async {
        // Decremented BEFORE the send that can start the follow-up, so that
        // follow-up's done event can never find this call still "in flight".
        do {
            switch stack {
            case .openAIRealtime:
                let output = String(decoding: (try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])) ?? Data("{}".utf8), as: UTF8.self)
                try await socket?.sendJSON(["type": "conversation.item.create",
                                            "item": ["type": "function_call_output", "call_id": call.callID, "output": output]])
                turn.toolsInFlight -= 1
                // One follow-up for all the calls of a response, once that response is over.
                guard turn.toolsInFlight == 0 else { return }
                let waitDeadline = uptime + 5
                while openAIResponseActive, uptime < waitDeadline { try await Task.sleep(for: .milliseconds(20)) }
                turn.toolResultSentUptime = uptime
                try await socket?.sendJSON(["type": "response.create"])
            case .geminiLive:
                turn.toolsInFlight -= 1
                turn.toolResultSentUptime = uptime
                try await socket?.sendJSON(["toolResponse": ["functionResponses": [["id": call.callID, "name": call.name, "response": result]]]])
            }
        } catch {
            turn.finished.settle(.failure(VoiceBenchFailure(kind: "\(stack.rawValue):toolResultSendFailed")))
        }
    }
}
