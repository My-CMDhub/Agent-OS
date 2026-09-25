//
//  RealtimeVoiceConnection.swift
//  leanring-buddy
//
//  One open speech-to-speech session — OpenAI Realtime or Gemini Live — with the
//  voice tools (`open_app`, `focus_app`, `find_menu_items`, `press_menu`)
//  declared and answered. Shared by the live push-to-talk loop
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
    /// One per call, in arrival order — the decision trace's rows.
    var decisions: [RealtimeToolDecision] = []
    /// The latest finished find_menu_items' candidates: what a press chose from.
    var latestMenuOffer: [RealtimeMenuCandidate]?
    var toolResultSentUptime: TimeInterval?
    /// First audio after the LATEST tool result — with find -> press, the words
    /// about the press, not a "one moment" between the two calls.
    var followUpFirstAudioUptime: TimeInterval?
    /// The first confirmed call's fresh look: "pending" while in flight, then
    /// "attached" or the refusal code; ms from the harness answer to the image
    /// sent, and the bytes sent.
    var freshLookOutcome: String?
    var freshLookMilliseconds: Int?
    var freshLookImageBytes: Int?
    var freshLookCompletedUptime: TimeInterval?
    /// When the notch first showed this turn's intent — before the harness request.
    var intentShownUptime: TimeInterval?
    /// Set when the turn finishes; audio after it is a reply nobody asked for.
    var finishedUptime: TimeInterval?
    var audioChunksAfterFinish = 0
    var transcript = ""
    /// What the OWNER said, from the provider's separate transcription model
    /// (not the model that reasons). Owner-only: the heard check and the 0600
    /// answers files read it; no counts-only log ever does.
    var heardText = ""
    /// When this turn's transcript was complete: OpenAI's completed (or failed)
    /// event for this turn's audio item; Gemini's last piece, once quiet
    /// (`heardCompletedUptime(now:)`).
    var heardCompleteUptime: TimeInterval?
    /// Gemini only: each input-transcription piece's arrival.
    var heardPieceUptimes: [TimeInterval] = []
    /// OpenAI only: the committed audio item, so a late transcript of an
    /// earlier turn is never read as this one's.
    var audioItemID: String?
    /// Gemini only: input-transcription pieces that arrive before this are the
    /// PREVIOUS turn's and are dropped (`beginTurn`).
    var staleHeardPiecesUntilUptime: TimeInterval?
    /// Calls this turn the heard check refused. After one, a call whose app
    /// was only guessed from the words is refused too (`unconfirmedRetry`).
    var heardRefusals = 0
    /// The latest call's work. Each call awaits the one before it, so calls
    /// reach the harness in the order the model emitted them — each waits a
    /// different time for the transcript, and focus -> press must not become
    /// press -> focus.
    var lastCallTask: Task<Void, Never>?
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

    /// Gemini sends no end marker for input transcription (ai.google.dev/api/live,
    /// read 2026-09-25: `text` and `languageCode` only), so its transcript counts
    /// as complete once a piece has arrived and none followed for this long.
    static let geminiHeardQuietSeconds: Double = 0.3

    func heardCompletedUptime(now: TimeInterval) -> TimeInterval? {
        if let heardCompleteUptime { return heardCompleteUptime }
        // Quiet counted from the release too: pieces arrive while the owner is
        // still speaking, and a pause mid-sentence is not the end of it.
        // A microsecond of slack: `released + 0.3 - released` is 0.29999... at
        // some uptimes, and the boundary must not depend on which.
        guard let last = heardPieceUptimes.last, let released = lastAudioSentUptime,
              now - max(last, released) >= Self.geminiHeardQuietSeconds - 1e-6 else { return nil }
        return last
    }

    /// The transcript once complete, or nil at `deadlineUptime`. Polled: a
    /// tool call usually arrives BEFORE the transcript (measured, see
    /// `RealtimeHeardCheck.transcriptDeadlineAfterReleaseSeconds`).
    func waitForHeard(until deadlineUptime: TimeInterval) async -> String? {
        while heardCompletedUptime(now: ProcessInfo.processInfo.systemUptime) == nil,
              ProcessInfo.processInfo.systemUptime < deadlineUptime {
            try? await Task.sleep(for: .milliseconds(10))
        }
        guard heardCompletedUptime(now: ProcessInfo.processInfo.systemUptime) != nil else { return nil }
        return heardText
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
    /// OpenAI only: each committed audio item's turn, so a transcript that
    /// lands after the next turn began still reaches the turn it transcribes.
    private var turnsByAudioItemID: [String: RealtimeTurnMarks] = [:]
    private var turnAwaitingCommit: RealtimeTurnMarks?
    /// OpenAI only, from each `response.done`'s usage; a response with no usage
    /// is charged the bench's ceiling, never 0.
    private(set) var estimatedOpenAIUSD = 0.0

    /// Probe only: replaces the app name of every `open_app` call, so a forced
    /// failure (an app that does not exist) runs the real harness path.
    var appNameOverride: String?
    /// Probe only: the menu fixtures turn the post-launch look off, so a probe
    /// that brings the owner's Chrome or TextEdit forward never photographs it.
    var sendsFreshLook = true

    /// PCM16 mono 24 kHz, as it arrives.
    var onAudio: ((Data) -> Void)?
    var onTurnFinished: (() -> Void)?
    var onClosed: (() -> Void)?

    /// A model that keeps calling tools is answered with an error after this
    /// many calls in one turn, not left to loop against the harness. focus ->
    /// find -> press is three, so five leaves one retry and no more.
    static let maximumToolCallsPerTurn = 5
    static let supersededError = "superseded"
    static let openAIMaxOutputTokens = VoiceStackBenchmark.openAIRealtimeMaxOutputTokens
    /// The J.A.R.V.I.S. voices, live loop only — the bench keeps "marin" and
    /// Gemini's default as its control. OpenAI lists ten realtime voices and
    /// recommends marin or cedar for quality; cedar is the lower, more measured
    /// of the two. Gemini Live takes any of the 30 TTS voices; Charon is listed
    /// "Informative", a low, even delivery (both docs read 2026-09-24).
    static let openAIVoice = "cedar"
    /// Input transcription: separate from the realtime model, billed apart.
    static let openAITranscriptionModel = "gpt-4o-mini-transcribe"
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
                    "tools": RealtimeVoiceVerbs.openAIDeclarations,
                    "tool_choice": "auto",
                    "audio": [
                        // Push-to-talk: we commit, the server's VAD does not decide.
                        // The owner's words, from a separate transcription model, for the
                        // heard-vs-named check (`RealtimeHeardCheck`). The GA shape and
                        // model the bench has used live since 2026-09-23.
                        "input": ["format": ["type": "audio/pcm", "rate": 24_000], "turn_detection": NSNull(),
                                  "transcription": ["model": Self.openAITranscriptionModel]],
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
                    "tools": [RealtimeVoiceVerbs.geminiDeclaration],
                    "realtimeInputConfig": ["automaticActivityDetection": ["disabled": true]],
                    // What the model said, for the probe's answers file and the honesty check.
                    "outputAudioTranscription": [String: Any](),
                    // What the OWNER said, for the heard-vs-named check (the bench's since 2026-09-23).
                    "inputAudioTranscription": [String: Any]()
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

    /// Gemini's input transcription has no item id, so a piece is placed by
    /// when it arrives. Measured 2026-09-25 over 79 Gemini fixture turns: a
    /// turn's LAST piece lands at most 387 ms after its release, and its FIRST
    /// at least 1,735 ms after its activityStart. So when a turn begins while
    /// the previous transcript is still open, pieces in its first second are
    /// the previous turn's — dropped, never appended to this one.
    static let geminiStaleHeardPieceSeconds: Double = 1.0

    func beginTurn() async throws {
        let previous = turn
        turn = RealtimeTurnMarks()
        if stack == .geminiLive, previous.lastAudioSentUptime != nil, previous.heardCompletedUptime(now: uptime) == nil {
            turn.staleHeardPiecesUntilUptime = uptime + Self.geminiStaleHeardPieceSeconds
        }
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
        turnAwaitingCommit = turn
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

    /// Internal, not private, so a test can feed the provider's events.
    func handle(_ message: [String: Any], arrivalUptime: TimeInterval) {
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
        case "input_audio_buffer.committed":
            guard let itemID = message["item_id"] as? String else { break }
            let owner = turnAwaitingCommit ?? turn
            turnAwaitingCommit = nil
            owner.audioItemID = itemID
            turnsByAudioItemID[itemID] = owner
        case "conversation.item.input_audio_transcription.completed", "conversation.item.input_audio_transcription.failed":
            // To the turn whose audio it transcribes, even if another has begun since.
            guard let itemID = message["item_id"] as? String, let owner = turnsByAudioItemID.removeValue(forKey: itemID),
                  owner.heardCompleteUptime == nil else { break }
            owner.heardText = message["transcript"] as? String ?? ""
            owner.heardCompleteUptime = arrivalUptime
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
        if let heardPiece = (serverContent["inputTranscription"] as? [String: Any])?["text"] as? String,
           arrivalUptime >= turn.staleHeardPiecesUntilUptime ?? -.infinity {
            turn.heardText += heardPiece
            turn.heardPieceUptimes.append(arrivalUptime)
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
        if turn.firstAudioUptime == nil {
            turn.firstAudioUptime = arrivalUptime
            if turn.toolCalls.isEmpty { JarvisNotch.shared.handle(.firstAudioWithoutTool) }
        }
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
        // A find with no press leaves its "Looking for…" up; the turn is over.
        // Proof and didn't-take hold their own time and ignore this.
        JarvisNotch.shared.handle(.turnEnded)
        onTurnFinished?()
    }

    // MARK: Tool calls

    private func receivedToolCalls(_ calls: [RealtimeToolCall], arrivalUptime: TimeInterval) {
        let turn = self.turn
        if turn.toolCallUptime == nil { turn.toolCallUptime = arrivalUptime }
        for providerCall in calls {
            let call = appNameOverride.map { RealtimeToolCall(callID: providerCall.callID, name: providerCall.name, appName: $0) } ?? providerCall
            turn.toolCalls.append(call)
            let decisionIndex = turn.decisions.count
            turn.decisions.append(RealtimeToolDecision(call: call, callUptime: arrivalUptime, offeredBeforeCall: turn.latestMenuOffer))
            turn.toolsInFlight += 1
            let overLimit = turn.toolCalls.count > Self.maximumToolCallsPerTurn
            let previousCall = turn.lastCallTask
            turn.lastCallTask = Task { @MainActor [weak self] in
                await previousCall?.value
                var dispatch: RealtimeToolDispatch
                if overLimit {
                    let refusal = RealtimeToolRefusal(error: "tooManyToolCalls", message: "only \(Self.maximumToolCallsPerTurn) tool calls are allowed per turn")
                    dispatch = RealtimeToolDispatch(result: RealtimeOpenAppTool.toolResult(for: refusal), harnessMilliseconds: 0,
                                                    waitedForConfirmation: false, harnessResponse: nil)
                } else {
                    // `dispatch` hops off main for every harness call.
                    guard let harnessAnswer = self?.harnessAnswer else { return }
                    // Before the request, so the owner sees the intent while it runs;
                    // from the tool's own argument, never from anything said aloud.
                    let isKnownTool = RealtimeVoiceVerbs.allToolNames.contains(call.name)
                    // The owner's words against the tool's app, before anything is focused,
                    // opened, searched or pressed.
                    let heard = await Self.heardCheck(for: call, in: turn)
                    // The owner pressed the key again while this call waited: whatever
                    // it would do answers a turn nobody is waiting on. Never run it.
                    guard self?.turn === turn else {
                        let refusal = RealtimeToolRefusal(error: Self.supersededError,
                                                          message: "the owner started a new request before this call ran; nothing was done")
                        var superseded = RealtimeToolDispatch(result: RealtimeOpenAppTool.toolResult(for: refusal), harnessMilliseconds: 0,
                                                              waitedForConfirmation: false, harnessResponse: nil)
                        superseded.heardCheck = heard?.trace
                        turn.dispatches.append(superseded)
                        turn.decisions[decisionIndex].dispatch = superseded
                        turn.toolsInFlight -= 1
                        // No result is sent: it would start a reply inside the new turn.
                        return
                    }
                    if isKnownTool {
                        JarvisNotch.shared.handle(.toolCall(title: RealtimeVoiceVerbs.intentTitle(for: call)))
                        if turn.intentShownUptime == nil { turn.intentShownUptime = self?.uptime }
                    }
                    if let refusal = heard?.refusal {
                        dispatch = RealtimeToolDispatch(result: refusal, harnessMilliseconds: 0, waitedForConfirmation: false, harnessResponse: nil)
                        JarvisNotch.shared.handle(.harnessAnswered(ok: false, subject: RealtimeOpenAppTool.captionName(heard?.heardApp ?? ""),
                                                                   error: refusal["error"] as? String))
                    } else {
                        dispatch = await RealtimeOpenAppTool.dispatch(call, answer: harnessAnswer, onConfirmationRequired: {
                            if isKnownTool { JarvisNotch.shared.handle(.confirmationRequired) }
                        })
                        // Proof only from the harness's own ok: true.
                        if isKnownTool, let answered = RealtimeOpenAppTool.notchAnswer(for: call, dispatch: dispatch) {
                            JarvisNotch.shared.handle(answered)
                        }
                    }
                    dispatch.heardCheck = heard?.trace
                }
                turn.dispatches.append(dispatch)
                turn.decisions[decisionIndex].dispatch = dispatch
                if let offer = dispatch.menuOffer { turn.latestMenuOffer = offer.candidates }
                // The harness's verification is the proof, so the result goes now and
                // the model confirms the outcome. The model's only picture is the
                // key-down one, of the app in front BEFORE this launch, so the new
                // app is looked at in parallel and added as context once it arrives,
                // without asking for a reply (owner's ruling 2026-09-24).
                if dispatch.harnessConfirmed, call.name == RealtimeOpenAppTool.name, turn.freshLookOutcome == nil,
                   self?.sendsFreshLook == true, let harnessAnswer = self?.harnessAnswer {
                    turn.freshLookOutcome = "pending"
                    Task { @MainActor [weak self] in await self?.addFreshLook(afterLaunchResponse: dispatch.harnessResponse, answer: harnessAnswer, to: turn) }
                }
                await self?.sendToolResult(dispatch.result, for: call, in: turn)
            }
        }
    }

    /// Waits (bounded) for this turn's transcript, then decides. nil for a call
    /// that names no app (it is refused as `missingAppName` anyway).
    private static func heardCheck(for call: RealtimeToolCall, in turn: RealtimeTurnMarks) async
        -> (refusal: [String: Any]?, heardApp: String?, trace: [String: Any])? {
        guard RealtimeHeardCheck.appliesTo(toolName: call.name), let named = call.appName else { return nil }
        let waitStart = ProcessInfo.processInfo.systemUptime
        let released = turn.lastAudioSentUptime ?? waitStart
        let transcript = await turn.waitForHeard(until: released + RealtimeHeardCheck.transcriptDeadlineAfterReleaseSeconds)
        let waitedMs = Int(((ProcessInfo.processInfo.systemUptime - waitStart) * 1000).rounded())
        // The app list reads the file system: off main.
        let afterHeardRefusal = turn.heardRefusals > 0
        let menuWords = RealtimeVoiceVerbs.foldedTokens(([call.words ?? ""] + (call.path ?? [])).joined(separator: " "))
        let (decision, namedAppIsRunning) = await Task.detached { () -> (RealtimeHeardCheck.Decision, Bool) in
            let decision = RealtimeHeardCheck.decide(transcript: transcript, named: named, among: RealtimeVoiceVerbs.installedAppNames(),
                                                     afterHeardRefusal: afterHeardRefusal, toolName: call.name, menuWords: menuWords)
            // Only asked when it decides: open_app with no transcript.
            guard decision.outcome == .transcriptMissing, call.name == RealtimeOpenAppTool.name else { return (decision, true) }
            return (decision, RealtimeVoiceVerbs.isRunning(named: named))
        }.value
        let arrivalMs = turn.heardCompletedUptime(now: ProcessInfo.processInfo.systemUptime).map { Int((($0 - released) * 1000).rounded()) }
        let refusal = RealtimeHeardCheck.refusal(for: decision, toolName: call.name, named: named, namedAppIsRunning: namedAppIsRunning)
        if refusal != nil { turn.heardRefusals += 1 }
        return (refusal, decision.heardApps.first,
                RealtimeHeardCheck.traceObject(decision, named: named, transcriptArrivalMs: arrivalMs, waitedMs: waitedMs))
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
                turn.followUpFirstAudioUptime = nil
                try await socket?.sendJSON(["type": "response.create"])
            case .geminiLive:
                turn.toolsInFlight -= 1
                turn.toolResultSentUptime = uptime
                turn.followUpFirstAudioUptime = nil
                try await socket?.sendJSON(["toolResponse": ["functionResponses": [["id": call.callID, "name": call.name, "response": result]]]])
            }
        } catch {
            turn.finished.settle(.failure(VoiceBenchFailure(kind: "\(stack.rawValue):toolResultSendFailed")))
        }
    }
}
