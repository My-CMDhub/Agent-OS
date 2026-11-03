//
//  RealtimeVoiceConnection.swift
//  leanring-buddy
//
//  One open speech-to-speech session — OpenAI Realtime or Gemini Live — with the
//  voice tools (`open_app`, `focus_app`, `find_menu_items`, `press_menu`,
//  `find_on_screen`, `point_at`) declared and answered. Shared by the live push-to-talk loop
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

import AppKit
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
    /// The latest finished find_menu_items' candidates, the bundle it resolved
    /// to (an offer is pressed only in its own app) and when: what a press chose from.
    var latestMenuOffer: RealtimeStandingOffer?
    /// The most recent earlier turn's `latestMenuOffer`, carried at `beginTurn`
    /// across turns that made none: a press may use it only as
    /// `RealtimeOpenAppTool.pressOffer` allows (90 s, the owner's words).
    var previousTurnMenuOffer: RealtimeStandingOffer?
    /// Agent steps: the front app's affordance map the model was shown (`AffordanceMap.offer`); a press of a mapped path needs no find.
    var affordanceMenuOffer: RealtimeStandingOffer?
    /// The same pair for find_on_screen's controls (`RealtimeOpenAppTool.pointOffer`).
    var latestScreenOffer: RealtimeStandingOffer?
    var previousTurnScreenOffer: RealtimeStandingOffer?
    /// The key-down screenshot's display (AppKit): what point_at's x and y are fractions of.
    var screenshotDisplayFrame: CGRect?
    /// That screenshot's size in pixels: what a native OpenAI position is in (`RealtimePointFormat`).
    var screenshotPixelSize: CGSize?
    /// What the credential guard did to the key-down screenshot: `clean`, `redacted`
    /// or `withheld` (`ScreenSecretGuard.Report.outcome`); nil when none was taken.
    var screenshotGuard: String?
    /// The element under the owner's mouse at key-down (`underPointer`).
    var keyDownPointer: RealtimeScreenTarget?
    /// What the previous answer SAID (`transcript`), carried only when the owner
    /// heard all of it — the plain-yes gate reads it (`confirmedByPlainYes`).
    var previousTurnSaid: String?
    /// A turn the owner did not speak (`beginSystemTurn`): it carries the owner
    /// turn's offers, and the next owner turn reads the OWNER turn's words through
    /// it (`ownerTurnTranscript`), never the system turn's own reply.
    var isSystemTurn = false
    /// An agent-loop step (`AgentLoop.liveExecute`): the "heard" words are the
    /// task's goal, a sentence of instructions, not a one-step request.
    var isAgentStep = false
    /// Agent steps: the apps this run itself opened or focused (ok open_app,
    /// focus_app, open_url): the only ones an unclear app word may act in.
    var agentOpenedBundles: Set<String> = []
    /// Agent steps: the app in front when the task began — the owner's own.
    var agentStartBundle: String?
    /// A system turn that may only speak (the agent loop's lines): every tool call in it is refused.
    var speechOnly = false
    /// This owner turn started a task: from then on it calls nothing (`turnRefusal`).
    var taskStarted = false
    /// The app in front at the owner's key-down (the frontmost read): a task this turn starts began there.
    var keyDownFrontBundle: String?
    /// What "this" meant this turn (`OwnerFocusTracker`), resolved at the release: a task this turn starts is told it.
    var ownerFocus: OwnerFocusNote?
    var ownerTurnTranscript = ""
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
    /// Event names only, never content, from `beginTurn` on — what arrives while
    /// the key is still held is exactly what a stalled turn needs to show.
    var events: [(name: String, uptime: TimeInterval)] = []
    /// Completions that belonged to an earlier turn and were not counted here.
    var staleCompletionsIgnored = 0
    /// OpenAI only: the responses this turn's own `response.create`s started.
    var responseIDs: Set<String> = []
    /// Gemini only: when `interrupted` arrived in this turn. The next `turnComplete`
    /// — and any audio or call before it — is the cut-off answer's, not this turn's.
    var geminiInterruptedUptime: TimeInterval?
    /// The owner pressed again (`supersedeForPress`): nothing that still arrives
    /// for this turn is played, finished or dispatched, and no result it produces
    /// asks for a reply.
    var supersededByPress = false
    /// OpenAI only: the follow-up after the tool results came back empty and
    /// was asked for once more (`openAIFollowUpWasEmpty`).
    var emptyFollowUpReasked = false
    /// When a call of this turn handed its approval card's question to the model
    /// (`handCardToVoice`): every later call of the turn is refused `cardPending`.
    var cardAskedUptime: TimeInterval?
    /// Cards handed to the model and not yet answered: the turn's end leaves the notch on "needs you".
    var cardsAwaitingOwner = 0
    /// The card was answered while the model was still saying its ask: the rest of that is not played.
    var replyMuted = false
    /// The session's id for this turn (voice-live.log), for the card's outcome line.
    var turnID: String?
    /// Cascade only (`CascadeVoicePipeline`): the release -> first audio legs, and Claude's usage summed over the turn's requests.
    var cascadeSttFinalUptime: TimeInterval?
    var cascadeRequestUptime: TimeInterval?
    var cascadeFirstTextUptime: TimeInterval?
    var cascadeFirstSpeakUptime: TimeInterval?
    var cascadeUsage: [String: Int] = [:]
    var cascadeThinkingBlocks = 0
    /// Front and worker only: what Gemini's own ear made of this turn, beside `heardText` (Nova-3's): for the register, never authority.
    var geminiHeardText = ""
    var geminiHeardPieceUptimes: [TimeInterval] = []
    /// Nova-3 gave no answer, so Gemini's ear stands in for this turn (`frontEarFailed`).
    var heardFallback = false
    /// How this turn was routed (`FrontVerdict`): act | chat | queued | unheard, who said so, and what that took.
    var frontRoute: String?
    var frontRouteSource: String?
    var frontRouteMilliseconds: Int?
    /// What to say in exact words if Gemini cannot say this turn (`frontUnreachable`).
    var frontPlain: String?
    /// gemini | deepgram: who actually spoke it.
    var frontVia: String?
    /// This press opened an activity on Gemini's socket; it may still be owed an end.
    var frontActivityOpen = false
    /// That socket is gone, or never was: Gemini has not heard this turn, whatever has come back since.
    var frontActivityLost = false
    let finished = VoiceBenchWaiter<TimeInterval>()

    /// Each event with its arrival in ms after the release, negative before it.
    var eventTrail: [String] {
        guard let origin = lastAudioSentUptime ?? events.first?.uptime else { return [] }
        return events.map { "\($0.name)@\(Int((($0.uptime - origin) * 1000).rounded()))" }
    }

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

/// How a turn the owner did not speak is put to the provider (`systemTurnMessages`).
enum RealtimeSystemTurnVariant: String, CaseIterable, Sendable { case textOnly, textThenCreate, clientContent }

@MainActor
final class RealtimeVoiceConnection {
    let stack: VoiceStackChoice
    private let harnessAnswer: @Sendable (String) -> String
    private var socket: VoiceBenchWebSocket?
    private var readyWaiter = VoiceBenchWaiter<TimeInterval>()
    private(set) var isOpen = false
    private(set) var turn = RealtimeTurnMarks()
    /// OpenAI only: `response.create` while a response is live is refused
    /// (`conversation_already_has_active_response`), so a tool result waits for it.
    private var openAIResponseActive = false
    /// OpenAI only: each committed audio item's turn, so a transcript that
    /// lands after the next turn began still reaches the turn it transcribes.
    private var turnsByAudioItemID: [String: RealtimeTurnMarks] = [:]
    private var turnAwaitingCommit: RealtimeTurnMarks?
    /// OpenAI only: each `response.create` sent, oldest first, with its `event_id`.
    /// The server answers them in order, so each `response.created` names the
    /// head's response; an error naming a create's `event_id` removes that one.
    private var turnsAwaitingResponseCreated: [(eventID: String, turn: RealtimeTurnMarks)] = []
    var pendingResponseCreateEventIDs: [String] { turnsAwaitingResponseCreated.map(\.eventID) }
    /// OpenAI only, from each `response.done`'s usage; a response with no usage
    /// is charged the bench's ceiling, never 0.
    private(set) var estimatedOpenAIUSD = 0.0
    /// OpenAI only: input audio appended this turn, for the transcription charge.
    private var turnInputAudioBytes = 0
    /// Cascade only: its three legs in place of the provider socket.
    private var cascade: CascadeVoicePipeline?
    /// Cascade only: asks the model the moment the words are complete, so a poll on them would land after the request left.
    var contextForHeardWords: ((RealtimeTurnMarks) -> String?)?

    // Front and worker only (`FrontAndWorker.swift`). `isOpen` is the ear's and this object's; Gemini comes and goes under it,
    // and a turn survives that: the words are Nova-3's and the exact-words voice is Deepgram's.
    /// Gemini's socket is up and its setup acknowledged.
    private(set) var frontIsUp = false
    /// Nova-3's final is in: who answers this turn, and what Gemini is told. The session starts the worker inside this.
    var onFrontTurn: ((RealtimeTurnMarks, _ frontUp: Bool) async -> FrontTurnPlan)?
    var onTaskStatus: (() -> String?)?
    /// Gemini's socket went or came: dropped:why, up, up:resumed, reconnectFailed.
    var onFrontSocket: ((String) -> Void)?
    /// Gemini's session handle: a reconnect keeps the conversation (`sessionResumptionUpdate`).
    private var frontResumeHandle: String?
    private var frontKeeper: Task<Void, Never>?
    /// `--front-probe`: Gemini answers nothing (silent, not gone), and its reconnects fail.
    var frontDeafForProbe = false
    var frontUnreachableForProbe = false
    func killFrontForProbe() { socket?.task.cancel(with: .goingAway, reason: nil) }
    func breakEarForProbe() { cascade?.ignoresAudioForProbe = true }

    /// What can speak in the conversation's voice right now.
    var speaksInOwnVoice: Bool { stack == .frontAndWorker ? frontIsUp : isOpen }

    /// Probe only: replaces the app name of every `open_app` call, so a forced
    /// failure (an app that does not exist) runs the real harness path.
    var appNameOverride: String?
    /// Probe only: the menu fixtures turn the post-launch look off, so a probe
    /// that brings the owner's Chrome or TextEdit forward never photographs it.
    var sendsFreshLook = true
    /// How positions are asked for and read (`RealtimePointFormat`); set before `connect`.
    var pointFormat = RealtimePointFormat.live

    /// PCM16 mono 24 kHz, as it arrives.
    var onAudio: ((Data) -> Void)?
    var onTurnFinished: (() -> Void)?
    var onClosed: (() -> Void)?
    /// A card the model asked about was answered (`cardAnswered`): `text` is the system line telling it the
    /// outcome; `askStillCurrent` — the asking turn is still the current one, so what still plays of its ask
    /// is moot; `line` is the outcome's voice-live.log record. nil (a probe's bare connection): the line goes
    /// to the model as context only.
    var onCardAnswered: ((_ text: String, _ askStillCurrent: Bool, _ line: [String: Any]) -> Void)?

    /// A model that keeps calling tools is answered with an error after this
    /// many calls in one turn, not left to loop against the harness. focus ->
    /// find -> press is three, so five leaves one retry and no more.
    static let maximumToolCallsPerTurn = 5
    /// A position's hit test: 0.25 s of AX messaging timeout, plus room to walk up.
    static let hitTestDeadlineSeconds: Double = 0.4
    static let supersededError = "superseded"
    static let openAICancelNotActiveCode = "response_cancel_not_active"
    static let openAIMaxOutputTokens = VoiceStackBenchmark.openAIRealtimeMaxOutputTokens
    /// The J.A.R.V.I.S. voices, live loop only — the bench keeps "marin" and
    /// Gemini's default as its control. OpenAI lists ten realtime voices and
    /// recommends marin or cedar for quality; cedar is the lower, more measured
    /// of the two. Gemini Live takes any of the 30 TTS voices; Charon is listed
    /// "Informative", a low, even delivery (both docs read 2026-09-24).
    static let openAIVoice = "cedar"
    /// Input transcription: separate from the realtime model, billed apart.
    static let openAITranscriptionModel = "gpt-4o-mini-transcribe"
    /// Its published estimate, US$0.003 per minute of input audio
    /// (developers.openai.com/api/docs/pricing, read 2026-09-25). `response.done`
    /// usage covers only the realtime model, so this is added per committed turn.
    static let openAITranscriptionUSDPerMinute = 0.003

    /// The transcription charge for `pcmBytes` of PCM16 mono at 24 kHz.
    nonisolated static func openAITranscriptionUSD(pcmBytes: Int) -> Double {
        Double(pcmBytes) / (2 * 24_000) / 60 * openAITranscriptionUSDPerMinute
    }
    static let geminiVoice = "Charon"
    /// The owner speaks English. Left to automatic detection Gemini's transcription named a tap "¿Qué es eso?" (live 2026-11-01)
    /// and "open settings" "¿Qué es el número de serie?" (A10 2026-11-03), and the guards and the reply followed it.
    static let ownerLanguageCodes = ["en-AU"]

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
            // Installed app names bias the owner's-words transcriber toward "Cursor" over "Kasa".
            let appVocabulary = RealtimeHeardCheck.transcriptionVocabulary(
                from: RealtimeVoiceVerbs.installedAppNames(),
                runningPaths: Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.standardizedFileURL.path }))
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
                    "instructions": RealtimeOpenAppTool.systemPrompt(pointFormat: pointFormat, stack: stack),
                    "output_modalities": ["audio"],
                    "max_output_tokens": Self.openAIMaxOutputTokens,
                    "tools": RealtimeVoiceVerbs.openAIDeclarations(pointFormat: pointFormat),
                    "tool_choice": "auto",
                    "audio": [
                        // Push-to-talk: we commit, the server's VAD does not decide.
                        // The owner's words, from a separate transcription model, for the
                        // heard-vs-named check (`RealtimeHeardCheck`). The GA shape and
                        // model the bench has used live since 2026-09-23.
                        "input": ["format": ["type": "audio/pcm", "rate": 24_000], "turn_detection": NSNull(),
                                  "transcription": ["model": Self.openAITranscriptionModel,
                                                    "prompt": RealtimeHeardCheck.transcriptionPrompt(vocabulary: appVocabulary)]],
                        // The rate is required even though 24 kHz is the only one (probed 2026-09-23).
                        "output": ["format": ["type": "audio/pcm", "rate": 24_000], "voice": Self.openAIVoice]
                    ]
                ]
            ])
        case .cascade:
            let pipeline = CascadeVoicePipeline(
                system: RealtimeOpenAppTool.systemPrompt(pointFormat: pointFormat, stack: stack),
                tools: RealtimeVoiceVerbs.anthropicVoiceDeclarations(),
                inputSampleRate: stack.inputSampleRate,
                keyterms: RealtimeHeardCheck.transcriptionVocabulary(
                    from: RealtimeVoiceVerbs.installedAppNames(),
                    runningPaths: Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.standardizedFileURL.path })))
            pipeline.currentTurn = { [weak self] in self?.turn }
            pipeline.contextForHeardWords = { [weak self] marks in self?.contextForHeardWords?(marks) }
            pipeline.onAudio = { [weak self] audio, arrival in self?.receivedAudio(audio, arrivalUptime: arrival) }
            pipeline.onToolCalls = { [weak self] calls, arrival in self?.receivedToolCalls(calls, arrivalUptime: arrival) }
            pipeline.onTurnDone = { [weak self] arrival, givingUp in self?.receivedTurnDone(arrivalUptime: arrival, givingUpOnFollowUp: givingUp) }
            pipeline.onFailed = { [weak self, weak pipeline] kind in
                pipeline?.stopAfterFailure()
                self?.turn.finished.settle(.failure(VoiceBenchFailure(kind: kind)))
            }
            try await pipeline.connect()
            cascade = pipeline
            readyWaiter.settle(.success(uptime))
        case .frontAndWorker:
            // The ear must exist; Gemini may arrive after it (`keepFrontUp`), and a press meanwhile goes by Deepgram's voice.
            let pipeline = CascadeVoicePipeline(
                system: "", tools: [], inputSampleRate: stack.inputSampleRate,
                keyterms: RealtimeHeardCheck.transcriptionVocabulary(
                    from: RealtimeVoiceVerbs.installedAppNames(),
                    runningPaths: Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.standardizedFileURL.path })))
            pipeline.earOnly = true
            pipeline.currentTurn = { [weak self] in self?.turn }
            pipeline.onHeard = { [weak self] marks, _ in self?.frontHeard(marks) }
            pipeline.onEarFailed = { [weak self] marks, why in self?.frontEarFailed(marks, why: why) }
            pipeline.onAudio = { [weak self] audio, arrival in self?.receivedAudio(audio, arrivalUptime: arrival) }
            pipeline.onTurnDone = { [weak self] arrival, _ in self?.receivedTurnDone(arrivalUptime: arrival, givingUpOnFollowUp: true) }
            pipeline.onFailed = { [weak self, weak pipeline] kind in
                pipeline?.stopAfterFailure()
                self?.turn.finished.settle(.failure(VoiceBenchFailure(kind: kind)))
            }
            try await pipeline.connect()
            cascade = pipeline
            isOpen = true
            keepFrontUp()
            await waitForFront(seconds: FrontWatchdog.frontReconnectSeconds)
            return
        case .geminiLive:
            try await openGemini(setup: [
                "systemInstruction": ["parts": [["text": RealtimeOpenAppTool.systemPrompt(pointFormat: pointFormat, stack: stack)]]],
                "tools": [RealtimeVoiceVerbs.geminiDeclaration(pointFormat: pointFormat)]
            ])
        }
        _ = try await readyWaiter.value(timeoutSeconds: 10, timeoutKind: "\(stack.rawValue):setupTimeout")
        isOpen = true
    }

    /// Token, socket, setup. `setup`: what differs between Gemini's two stacks.
    private func openGemini(setup: [String: Any]) async throws {
        let tokenResponse = try await VoiceStackBenchmark.fetchWorkerJSON(routePath: "/gemini-live-token", stage: "geminiToken")
        guard let ephemeralToken = tokenResponse["token"] as? String else { throw VoiceBenchFailure(kind: "geminiToken:noToken") }
        var components = URLComponents(string: VoiceStackBenchmark.geminiLiveConstrainedURL)!
        components.queryItems = [URLQueryItem(name: "access_token", value: ephemeralToken)]
        try await open(URLRequest(url: components.url!))
        let common: [String: Any] = [
            "model": "models/\(VoiceStackBenchmark.geminiLiveModel)",
            "generationConfig": [
                "responseModalities": ["AUDIO"], "thinkingConfig": ["thinkingLevel": "MINIMAL"],
                "speechConfig": ["voiceConfig": ["prebuiltVoiceConfig": ["voiceName": Self.geminiVoice]]]
            ],
            "realtimeInputConfig": ["automaticActivityDetection": ["disabled": true]],
            // What the model said, for the probe's answers file and the honesty check.
            "outputAudioTranscription": [String: Any](),
            // What the OWNER said, for the heard-vs-named check (the bench's since 2026-09-23).
            // No `customVocabulary`: documented, accepted, and still "Kasa" 8/8 (probes C92505CE, B59C0B0F).
            "inputAudioTranscription": ["languageCodes": Self.ownerLanguageCodes]
        ]
        try await socket?.sendJSON(["setup": common.merging(setup) { _, new in new }])
    }

    // MARK: Front and worker

    /// Gemini's half of the front: a resumable session with no tool that acts. `contextWindowCompression` because a session
    /// without it ends at 15 minutes of audio; the resumption handle carries the conversation across the ~10 minute connection cap.
    private func openFront() async throws {
        guard !frontUnreachableForProbe else { throw VoiceBenchFailure(kind: "front:unreachableForProbe") }
        readyWaiter = VoiceBenchWaiter()
        try await openGemini(setup: [
            "systemInstruction": ["parts": [["text": FrontPrompt.system]]],
            "tools": [RealtimeVoiceVerbs.frontGeminiDeclaration],
            "sessionResumption": frontResumeHandle.map { ["handle": $0] } ?? [String: Any](),
            "contextWindowCompression": ["slidingWindow": [String: Any]()]
        ])
        _ = try await readyWaiter.value(timeoutSeconds: 10, timeoutKind: "front:setupTimeout")
        frontIsUp = true
        turn.events.append((frontResumeHandle == nil ? "front.up" : "front.up:resumed", uptime))
        onFrontSocket?(frontResumeHandle == nil ? "up" : "up:resumed")
    }

    /// While this connection lives, Gemini is reconnecting or up. One at a time; a failure backs off, and never fails anything else.
    private func keepFrontUp() {
        guard frontKeeper == nil, isOpen else { return }
        frontKeeper = Task { @MainActor [weak self] in
            var attempt = 0
            while let self, self.isOpen, !self.frontIsUp, !Task.isCancelled {
                let wait = FrontWatchdog.reconnectBackoff[min(attempt, FrontWatchdog.reconnectBackoff.count - 1)]
                if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                attempt += 1
                do { try await self.openFront() } catch {
                    self.turn.events.append(("front.reconnectFailed", self.uptime))
                    self.onFrontSocket?("reconnectFailed")
                }
            }
            self?.frontKeeper = nil
        }
    }

    private func waitForFront(seconds: TimeInterval) async {
        let deadline = uptime + seconds
        while !frontIsUp, uptime < deadline { try? await Task.sleep(for: .milliseconds(100)) }
    }

    /// Gemini is gone, or as good as: whatever it owed the current turn is said another way, and the reconnect starts.
    private func frontDropped(why: String) {
        frontIsUp = false
        let gone = socket
        socket = nil
        gone?.close()
        turn.frontActivityLost = true
        readyWaiter.settle(.failure(VoiceBenchFailure(kind: "front:\(why)")))
        turn.events.append(("front.dropped:\(why)", uptime))
        onFrontSocket?("dropped:\(why)")
        frontUnreachable(turn)
        keepFrontUp()
    }

    /// The turn Gemini was to speak, if it has not. A press still held or a route still out needs nothing:
    /// both read `frontIsUp` when they get there. An owner turn already speaking just ends; a status is the owner's to hear whole.
    private func frontUnreachable(_ marks: RealtimeTurnMarks) {
        guard marks.frontVia == "gemini", marks.finishedUptime == nil, !marks.supersededByPress else { return }
        let say = marks.isSystemTurn || marks.firstAudioUptime == nil ? marks.frontPlain : nil
        guard let say else { return receivedTurnDone(arrivalUptime: uptime, givingUpOnFollowUp: true) }
        marks.frontVia = "deepgram"
        marks.events.append(("front.plain", uptime))
        cascade?.speakPlain(say, marks: marks)
    }

    /// No first audio inside the bound: Gemini is treated as gone, not waited on.
    private func armFrontSilence(_ marks: RealtimeTurnMarks) {
        Task { @MainActor [weak self, weak marks] in
            try? await Task.sleep(for: .seconds(FrontWatchdog.frontSilentSeconds))
            guard let self, let marks, self.turn === marks, !marks.supersededByPress, marks.firstAudioUptime == nil, marks.toolCalls.isEmpty,
                  marks.finishedUptime == nil, self.frontIsUp else { return }
            self.frontDropped(why: "silent")
        }
    }

    /// Nova-3's final: stop words first, then who answers, then Gemini's turn may end. Until now it has had no `activityEnd`, so it
    /// cannot have answered: there is one answer to a turn. A press since then owns everything.
    private func frontHeard(_ marks: RealtimeTurnMarks) {
        guard turn === marks, !marks.supersededByPress else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let line = self.contextForHeardWords?(marks) { try? await self.sendContextText(line) }
            let plan = await self.onFrontTurn?(marks, self.frontIsUp && !marks.frontActivityLost) ?? FrontTurnPlan(lines: [], plain: nil)
            guard self.turn === marks, !marks.supersededByPress else { return }
            marks.frontPlain = plan.plain
            for line in plan.lines where self.frontIsUp && !marks.frontActivityLost { try? await self.sendContextText(line) }
            self.endFrontActivity(marks)
        }
    }

    /// The turn goes to Gemini to answer, or if it cannot, to the exact words.
    private func endFrontActivity(_ marks: RealtimeTurnMarks) {
        guard frontIsUp, !marks.frontActivityLost else {
            guard let plain = marks.frontPlain else { return receivedTurnDone(arrivalUptime: uptime, givingUpOnFollowUp: true) }
            marks.frontVia = "deepgram"
            return cascade?.speakPlain(plain, marks: marks) ?? ()
        }
        marks.frontVia = "gemini"
        Task { try? await socket?.sendJSON(["realtimeInput": ["activityEnd": [String: Any]()]]) }
        armFrontSilence(marks)
    }

    /// Nova-3 gave no answer. Gemini's ear stands in for this turn and it decides as a plain Gemini turn does: never blocked, and the
    /// line in voice-live.log says so. Words Nova-3 said it did NOT hear are a different thing (`FrontPrompt.unheardLine`): room
    /// noise is what Gemini's ear imagines words in, 10 of 10 (register).
    private func frontEarFailed(_ marks: RealtimeTurnMarks, why: String) {
        guard turn === marks, !marks.supersededByPress else { return }
        marks.events.append(("ear.failed:\(why)", uptime))
        marks.heardFallback = true
        marks.heardText = marks.geminiHeardText
        marks.heardPieceUptimes = marks.geminiHeardPieceUptimes
        if marks.lastAudioSentUptime != nil { finishEarlessTurn(marks) }
    }

    private func finishEarlessTurn(_ marks: RealtimeTurnMarks) {
        guard frontIsUp, !marks.frontActivityLost else {
            // No ear and no voice: nothing to act on, and it says so rather than go quiet.
            return turn.finished.settle(.failure(VoiceBenchFailure(kind: "front:noEarNoVoice")))
        }
        marks.frontRoute = "fallback"
        marks.frontRouteSource = "geminiEar"
        marks.frontPlain = FrontPrompt.plainLostChat
        Task { @MainActor [weak self] in
            guard let self, self.turn === marks else { return }
            try? await self.sendContextText(FrontPrompt.earFailedLine)
            self.endFrontActivity(marks)
        }
    }

    /// Context about the machine: the front has no eyes (`FrontAndWorker.swift`), so on that stack it stays with the worker.
    func sendMachineContext(_ text: String) async throws {
        guard stack != .frontAndWorker else { return }
        try await sendContextText(text)
    }

    private func open(_ request: URLRequest) async throws {
        let socket = VoiceBenchWebSocket(request: request, session: VoiceStackBenchmark.benchURLSession)
        self.socket = socket
        socket.start(onMessage: { [weak self] message, arrivalUptime in
            self?.handle(message, arrivalUptime: arrivalUptime)
        }, onEnd: { [weak self] error in
            guard let self else { return }
            let failureKind = socket.failureKind(for: error, stage: self.stack.rawValue)
            if self.stack == .frontAndWorker {
                // A socket already replaced (a swap, `close`) ended as it should.
                if self.socket === socket { self.frontDropped(why: failureKind) }
                return
            }
            self.isOpen = false
            self.readyWaiter.settle(.failure(VoiceBenchFailure(kind: failureKind)))
            self.turn.finished.settle(.failure(VoiceBenchFailure(kind: failureKind)))
            self.onClosed?()
        })
    }

    func close() {
        isOpen = false
        frontIsUp = false
        frontKeeper?.cancel()
        socket?.close()
        socket = nil
        cascade?.close()
    }

    // MARK: A turn

    /// Before `beginTurn`, off the audio clock, as the bench does it — and after a
    /// verified `open_app`, as context the model is not asked to answer.
    func sendScreenshot(_ jpegData: Data) async throws {
        let base64Image = jpegData.base64EncodedString()
        switch stack {
        case .cascade:
            cascade?.add(image: jpegData)
        case .frontAndWorker:
            break   // No eyes: its words about the machine come only from the worker.
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

    /// `previousReplyWasHeard`: the previous answer's audio had finished playing
    /// when the owner pressed. Its transcript runs ahead of the audio, so a press
    /// mid-answer leaves words in it the owner never heard; then no plain yes
    /// can confirm what it named. Defaults to false: only the live loop knows.
    func beginTurn(previousReplyWasHeard: Bool = false) async throws {
        let previous = turn
        turn = RealtimeTurnMarks()
        // The most recent offer of each kind, however many turns back: its age
        // (`previousTurnOfferMaximumAgeSeconds`) and the owner's words decide.
        turn.previousTurnScreenOffer = previous.latestScreenOffer ?? previous.previousTurnScreenOffer
        // A system turn (a spoken correction) stands for the owner turn before it.
        let said = previous.isSystemTurn ? previous.ownerTurnTranscript : previous.transcript
        if previousReplyWasHeard, !said.isEmpty { turn.previousTurnSaid = said }
        // Also a barged-in turn's: barging in is how an owner says "yes, that one"
        // while the question is still being asked. But only a find that finished
        // BEFORE the press made an offer: one cut off before it ran, or still
        // running when the owner pressed, never set `latestMenuOffer`, because
        // the model never got its result.
        turn.previousTurnMenuOffer = previous.latestMenuOffer ?? previous.previousTurnMenuOffer
        turnInputAudioBytes = 0
        if stack == .geminiLive, !previous.isSystemTurn, previous.lastAudioSentUptime != nil, previous.heardCompletedUptime(now: uptime) == nil {
            turn.staleHeardPiecesUntilUptime = uptime + Self.geminiStaleHeardPieceSeconds
        }
        if stack == .frontAndWorker { turn.staleHeardPiecesUntilUptime = uptime + Self.geminiStaleHeardPieceSeconds }
        switch stack {
        case .openAIRealtime: try await socket?.sendJSON(["type": "input_audio_buffer.clear"])
        case .geminiLive: try await socket?.sendJSON(["realtimeInput": ["activityStart": [String: Any]()]])
        case .cascade: try await cascade?.beginOwnerTurn(marks: turn)
        case .frontAndWorker:
            // Neither half's failure stops the other: Gemini's socket reports its own end, and an ear that cannot open has `frontEarFailed`.
            if frontIsUp {
                turn.frontActivityOpen = true
                try? await socket?.sendJSON(["realtimeInput": ["activityStart": [String: Any]()]])
            } else {
                turn.frontActivityLost = true
                keepFrontUp()
            }
            do { try await cascade?.beginOwnerTurn(marks: turn) } catch { frontEarFailed(turn, why: "beginTurn") }
        }
    }

    /// PCM16 mono at `stack.inputSampleRate`.
    func appendAudio(_ pcmData: Data) async throws {
        switch stack {
        case .openAIRealtime:
            turnInputAudioBytes += pcmData.count
            try await socket?.sendJSON(["type": "input_audio_buffer.append", "audio": pcmData.base64EncodedString()])
        case .geminiLive:
            try await socket?.sendJSON(["realtimeInput": ["audio": ["mimeType": "audio/pcm;rate=16000", "data": pcmData.base64EncodedString()]]])
        case .cascade:
            cascade?.sendAudio(pcmData)
        case .frontAndWorker:
            try? await socket?.sendJSON(["realtimeInput": ["audio": ["mimeType": "audio/pcm;rate=16000", "data": pcmData.base64EncodedString()]]])
            cascade?.sendAudio(pcmData)
        }
    }

    /// The push-to-talk release, stated to the server.
    func endTurn() async throws {
        turn.lastAudioSentUptime = uptime
        turnAwaitingCommit = turn
        switch stack {
        case .openAIRealtime:
            estimatedOpenAIUSD += Self.openAITranscriptionUSD(pcmBytes: turnInputAudioBytes)
            try await socket?.sendJSON(["type": "input_audio_buffer.commit"])
            try await sendResponseCreate(for: turn)
        case .geminiLive:
            try await socket?.sendJSON(["realtimeInput": ["activityEnd": [String: Any]()]])
        case .cascade:
            cascade?.endOwnerTurn(marks: turn)
        case .frontAndWorker:
            // No `activityEnd` yet: `frontHeard` sends it once the words are routed.
            if turn.heardFallback { finishEarlessTurn(turn) } else { cascade?.endOwnerTurn(marks: turn) }
        }
    }

    /// Barge-in. Gemini needs nothing: the next `activityStart` interrupts it.
    /// ponytail: OpenAI's server-side transcript still holds the unplayed tail of
    /// the cancelled answer; `conversation.item.truncate` fixes that if it matters.
    /// Also while a `response.create` is sent and not yet acknowledged: that
    /// answer is about to start. A cancel with nothing active comes back
    /// `response_cancel_not_active`, which is harmless.
    func cancelResponse() {
        cascade?.cancelForPress()
        guard stack == .openAIRealtime, openAIResponseActive || !turnsAwaitingResponseCreated.isEmpty else { return }
        Task { try? await socket?.sendJSON(["type": "response.cancel"]) }
    }

    /// The press, BEFORE `beginTurn` replaces `turn`: live `beginTurn` waits for
    /// the key-down capture first (~230-350 ms, review 2026-09-29), and in that
    /// window the answer being cut off would still play, finish (idling the
    /// companion and pre-warming while the key is held) and run its calls.
    func supersedeForPress() {
        turn.supersededByPress = true
        cancelResponse()
        // A status cut off here has nothing more to wait for; its queue must not sit out a timeout behind it.
        if stack == .frontAndWorker, turn.isSystemTurn { turn.finished.settle(.success(uptime)) }
    }

    /// Context the model reads and is not asked to answer: OpenAI, a user text
    /// item with no `response.create`; Gemini, `realtimeInput.text` — its only
    /// mid-session text path on 3.1 Flash Live (`clientContent` is initial
    /// history only there, and would interrupt). Sent after `beginTurn`, so on
    /// Gemini it lands inside the owner's own activity rather than opening a
    /// turn of its own. UNMEASURED as of 2026-09-30: a reply to it would show as
    /// `ignored:audio` before the release in the turn's eventTrail.
    ///
    /// Every text path to the model passes here or `systemTurnMessages`, so a
    /// key in an element name or a tool's line is redacted once, at the wire.
    nonisolated static func contextTextMessage(stack: VoiceStackChoice, text: String) -> [String: Any] {
        let text = SecretScanner.redact(text)
        switch stack {
        case .openAIRealtime:
            return ["type": "conversation.item.create",
                    "item": ["type": "message", "role": "user", "content": [["type": "input_text", "text": text]]]]
        case .geminiLive, .frontAndWorker:
            return ["realtimeInput": ["text": text]]
        case .cascade:
            return ["type": "text", "text": text]
        }
    }

    /// A turn the owner did not speak: the session engine's "step 2 done; say the next step".
    /// Which variant makes each provider answer is what `--speak-probe` measures (2026-10-01).
    nonisolated static func systemTurnMessages(stack: VoiceStackChoice, text: String,
                                               variant: RealtimeSystemTurnVariant) -> [[String: Any]] {
        let text = SecretScanner.redact(text)
        switch (stack, variant) {
        case (.openAIRealtime, .textThenCreate):
            return [contextTextMessage(stack: stack, text: text), ["type": "response.create"]]
        case (.openAIRealtime, _):
            return [contextTextMessage(stack: stack, text: text)]
        case (.geminiLive, .clientContent), (.frontAndWorker, .clientContent):
            return [["clientContent": ["turns": [["role": "user", "parts": [["text": text]]]], "turnComplete": true]]]
        case (.geminiLive, _), (.cascade, _), (.frontAndWorker, _):
            return [contextTextMessage(stack: stack, text: text)]
        }
    }

    /// Fresh marks whose release is now, so the reply's audio counts for this turn.
    /// Never claims `turnAwaitingCommit`: no audio is committed, and an owner turn
    /// whose commit is still in flight must keep its own transcript.
    /// It inherits the owner turn's standing offers, as `beginTurn` carries them
    /// (review 2026-10-02: a correction between "find X" and "yes, that one" lost
    /// the offer), and takes no heard piece: the owner said nothing in it, so a
    /// late Gemini piece is the owner turn's.
    /// `plain`: front and worker only, the same news as exact words, for when Gemini cannot say it.
    func beginSystemTurn(text: String, variant: RealtimeSystemTurnVariant, speechOnly: Bool = false, plain: String? = nil) async throws {
        let previous = turn
        turn = RealtimeTurnMarks()
        turn.isSystemTurn = true
        turn.speechOnly = speechOnly
        turn.ownerTurnTranscript = previous.isSystemTurn ? previous.ownerTurnTranscript : previous.transcript
        turn.previousTurnScreenOffer = previous.latestScreenOffer ?? previous.previousTurnScreenOffer
        turn.previousTurnMenuOffer = previous.latestMenuOffer ?? previous.previousTurnMenuOffer
        turn.staleHeardPiecesUntilUptime = .infinity
        turn.lastAudioSentUptime = uptime   // nothing after this is "before the release"
        if stack == .cascade { return try await cascade?.beginSystemTurn(text: SecretScanner.redact(text), marks: turn) ?? () }
        if stack == .frontAndWorker {
            let marks = turn
            marks.frontPlain = plain
            // A dropped socket gets a few seconds to come back, and the line then goes as it would have.
            if !frontIsUp {
                keepFrontUp()
                await waitForFront(seconds: FrontWatchdog.frontReconnectSeconds)
                guard turn === marks, !marks.supersededByPress else { return marks.finished.settle(.success(uptime)) }
            }
            guard frontIsUp else {
                marks.events.append(("front.plain", uptime))
                return endFrontActivity(marks)
            }
            marks.frontVia = "gemini"
            armFrontSilence(marks)
        }
        for message in Self.systemTurnMessages(stack: stack, text: text, variant: variant) {
            if message["type"] as? String == "response.create" {
                try await sendResponseCreate(for: turn)
            } else {
                try await socket?.sendJSON(message)
            }
        }
    }

    /// After `beginTurn`, before the audio (`contextTextMessage`).
    func sendContextText(_ text: String) async throws {
        if stack == .cascade, let line = Self.contextTextMessage(stack: stack, text: text)["text"] as? String { return cascade?.add(context: line) ?? () }
        try await socket?.sendJSON(Self.contextTextMessage(stack: stack, text: text))
    }

    private func sendResponseCreate(for turn: RealtimeTurnMarks) async throws {
        let eventID = "create_" + UUID().uuidString
        turnsAwaitingResponseCreated.append((eventID, turn))
        try await socket?.sendJSON(["type": "response.create", "event_id": eventID])
    }

    // MARK: Server events

    /// Internal, not private, so a test can feed the provider's events.
    func handle(_ message: [String: Any], arrivalUptime: TimeInterval) {
        recordEvent(message, arrivalUptime: arrivalUptime)
        switch stack {
        case .openAIRealtime: handleOpenAI(message, arrivalUptime: arrivalUptime)
        case .geminiLive: handleGemini(message, arrivalUptime: arrivalUptime)
        case .frontAndWorker:
            if message["setupComplete"] != nil { return handleGemini(message, arrivalUptime: arrivalUptime) }
            guard !frontDeafForProbe else { return }
            if let update = message["sessionResumptionUpdate"] as? [String: Any], update["resumable"] as? Bool == true,
               let handle = update["newHandle"] as? String { frontResumeHandle = handle }
            if message["goAway"] != nil { frontGoingAway() }
            handleGemini(message, arrivalUptime: arrivalUptime)
        case .cascade: break   // Its legs call back directly (`connect`).
        }
    }

    private func handleOpenAI(_ message: [String: Any], arrivalUptime: TimeInterval) {
        switch message["type"] as? String {
        case "session.updated":
            readyWaiter.settle(.success(arrivalUptime))
        case "response.created":
            openAIResponseActive = true
            if let responseID = (message["response"] as? [String: Any])?["id"] as? String, !turnsAwaitingResponseCreated.isEmpty {
                turnsAwaitingResponseCreated.removeFirst().turn.responseIDs.insert(responseID)
            }
        case "response.output_audio.delta":
            guard openAIEventIsThisTurns(responseID: message["response_id"] as? String) else { return ignoreStale("audio", arrivalUptime: arrivalUptime) }
            if let audio = Data(base64Encoded: message["delta"] as? String ?? "") { receivedAudio(audio, arrivalUptime: arrivalUptime) }
        case "response.output_audio_transcript.delta":
            // The cut-off answer's words are not this turn's `said`.
            guard openAIEventIsThisTurns(responseID: message["response_id"] as? String) else { break }
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
            guard let call = RealtimeOpenAppTool.parseOpenAI(message) else { break }
            // A call of the cut-off answer would act for a request nobody is waiting on.
            guard openAIEventIsThisTurns(responseID: message["response_id"] as? String) else { return ignoreStale("toolCall", arrivalUptime: arrivalUptime) }
            receivedToolCalls([call], arrivalUptime: arrivalUptime)
        case "response.done":
            openAIResponseActive = false
            let response = message["response"] as? [String: Any]
            if let usage = response?["usage"] as? [String: Any],
               let responseUSD = VoiceBenchRealtimeCost.estimatedUSD(flattenedUsage: VoiceBenchRealtimeCost.flattenedUsage(usage)) {
                estimatedOpenAIUSD += responseUSD
            } else {
                estimatedOpenAIUSD += VoiceStackBenchmark.openAIRealtimeMissingUsageCeilingUSD
            }
            guard openAIEventIsThisTurns(responseID: response?["id"] as? String) else {
                turn.staleCompletionsIgnored += 1
                return ignoreStale("responseDone", arrivalUptime: arrivalUptime)
            }
            // Refused with nothing in it (live 2026-10-26 12:30, three silent turns): fail the
            // turn as an `error` event does, with the status and code only (never the message).
            if let refusal = Self.openAIResponseRefusal(response: response) {
                turn.events.append(("responseFailed:\(refusal.status):\(refusal.code ?? "-")", arrivalUptime))
                let failure = VoiceBenchFailure(kind: "openAI:responseFailed:\(refusal.code ?? refusal.status)")
                readyWaiter.settle(.failure(failure))
                turn.finished.settle(.failure(failure))
                return
            }
            let empty = Self.openAIFollowUpWasEmpty(response: response, turn: turn, arrivalUptime: arrivalUptime)
            if !empty, (response?["output"] as? [Any])?.isEmpty == true {
                turn.events.append(("emptyResponse:" + ((response?["status"] as? String) ?? "-"), arrivalUptime))
            }
            if empty {
                turn.events.append(("emptyFollowUp:" + ((response?["status"] as? String) ?? "-"), arrivalUptime))
                if !turn.emptyFollowUpReasked {
                    turn.emptyFollowUpReasked = true
                    let turn = self.turn
                    Task { @MainActor [weak self] in await self?.reaskAfterEmptyFollowUp(turn) }
                    return
                }
            }
            // Empty twice: the turn ends on what it has rather than hang until the owner presses.
            receivedTurnDone(arrivalUptime: arrivalUptime, givingUpOnFollowUp: empty)
        case "error":
            // Console only: the message is the server's text.
            let serverError = message["error"] as? [String: Any]
            print("🎙️ realtime: OpenAI error \(serverError?["code"] ?? "-"): \(serverError?["message"] ?? "-")")
            // A barge-in's `response.cancel` that lost the race to the answer's own
            // end: nothing was active to cancel, and nothing is wrong with the new turn.
            guard serverError?["code"] as? String != Self.openAICancelNotActiveCode else { break }
            let failure = VoiceBenchFailure(kind: "openAI:serverError:\(serverError?["code"] as? String ?? "-")")
            // A refused `response.create` never gets its `response.created`: forget that
            // one, named by its `event_id`, and no other still in flight.
            if let refusedEventID = serverError?["event_id"] as? String {
                turnsAwaitingResponseCreated.removeAll { $0.eventID == refusedEventID }
            }
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
        let serverContent = message["serverContent"] as? [String: Any]
        if serverContent?["interrupted"] as? Bool == true { turn.geminiInterruptedUptime = arrivalUptime }
        let isStale = !geminiEventIsThisTurns(arrivalUptime: arrivalUptime)
        let calls = RealtimeOpenAppTool.parseGemini(message)
        if !calls.isEmpty {
            // A call of the cut-off answer would act for a request nobody is waiting on.
            if isStale { ignoreStale("toolCall", arrivalUptime: arrivalUptime) } else { receivedToolCalls(calls, arrivalUptime: arrivalUptime) }
        }
        guard let serverContent else { return }
        if let spokenPiece = (serverContent["outputTranscription"] as? [String: Any])?["text"] as? String, !isStale {
            turn.transcript += spokenPiece
        }
        if let heardPiece = (serverContent["inputTranscription"] as? [String: Any])?["text"] as? String,
           arrivalUptime >= turn.staleHeardPiecesUntilUptime ?? -.infinity {
            // On the front Gemini's ear is logged beside Nova-3's and gives no authority, unless Nova-3 gave no answer.
            if stack == .frontAndWorker {
                turn.geminiHeardText += heardPiece
                turn.geminiHeardPieceUptimes.append(arrivalUptime)
            }
            if stack != .frontAndWorker || turn.heardFallback {
                turn.heardText += heardPiece
                turn.heardPieceUptimes.append(arrivalUptime)
            }
        }
        if let parts = (serverContent["modelTurn"] as? [String: Any])?["parts"] as? [[String: Any]] {
            for part in parts where !isStale {
                guard let inlineData = part["inlineData"] as? [String: Any],
                      let mimeType = inlineData["mimeType"] as? String, mimeType.hasPrefix("audio/"),
                      let audio = Data(base64Encoded: inlineData["data"] as? String ?? "") else { continue }
                if turn.outputAudioMime == nil { turn.outputAudioMime = mimeType }
                receivedAudio(audio, arrivalUptime: arrivalUptime)
            }
            if isStale { ignoreStale("audio", arrivalUptime: arrivalUptime) }
        }
        if serverContent["turnComplete"] as? Bool == true {
            guard !isStale else {
                turn.geminiInterruptedUptime = nil
                turn.staleCompletionsIgnored += 1
                return ignoreStale("turnComplete", arrivalUptime: arrivalUptime)
            }
            // Gemini ended the turn with no word: on the front what it owed is said another way, never skipped.
            if stack == .frontAndWorker, turn.firstAudioUptime == nil, turn.toolCalls.isEmpty, let plain = turn.frontPlain {
                turn.events.append(("front.emptyTurn", arrivalUptime))
                turn.frontVia = "deepgram"
                return cascade?.speakPlain(plain, marks: turn) ?? ()
            }
            receivedTurnDone(arrivalUptime: arrivalUptime)
        }
    }

    // MARK: Whose answer is this

    // A barge-in replaces `turn` while the cut-off answer is still arriving, and
    // its audio and done event then land in the NEW turn. Measured 2026-09-29 by
    // `--notch-probe`, Gemini, 20 presses 0.6 s into an answer: one more
    // `modelTurn` of the old answer, then `interrupted` 44-170 ms after the press
    // (median 78) and `turnComplete` 114-353 ms after it (median 199); 20 of 20
    // `interrupted` were followed by a `turnComplete`. Credited, that audio became
    // the new turn's "first audio" and that done its finish (finishedMs -1,574 to
    // -1,735), and the notch stayed on `thinking` — the owner's four silent turns
    // in voice-live.log 2026-09-28, each straight after a barge-in. So: nothing
    // before this turn's release is its answer (under push-to-talk the model
    // cannot answer a request not yet ended), and on Gemini an `interrupted` in
    // this turn consumes the next `turnComplete` — a tap shorter than ~350 ms is
    // released before it lands. OpenAI names its response on every event, so
    // there a done, delta or call counts only for a response this turn created.
    // And from the press itself (`supersedeForPress`), not only from `beginTurn`.

    /// An `interrupted` whose `turnComplete` never came must not swallow the
    /// next answer: it marks the old answer for this long only. 5.2x the widest
    /// measured `interrupted` -> `turnComplete` gap (286 ms, 20 of 20 barge-ins,
    /// 2026-09-29); an answer's first audio comes >= 906 ms after the release.
    static let geminiInterruptedStaleSeconds: Double = 1.5

    /// The server says this connection is ending soon (`goAway`, ~1 minute's notice). Replace it between answers, so no line goes into it.
    /// ponytail: 30 s is a bound on one answer, not measured; past it the swap happens anyway and `frontUnreachable` covers the turn.
    private func frontGoingAway() {
        let leaving = socket
        turn.events.append(("front.goAway", uptime))
        Task { @MainActor [weak self] in
            let deadline = ProcessInfo.processInfo.systemUptime + 30
            while let self, self.socket === leaving, ProcessInfo.processInfo.systemUptime < deadline, self.frontAnswering {
                try? await Task.sleep(for: .milliseconds(200))
            }
            guard let self, self.socket === leaving else { return }
            self.frontDropped(why: "goAway")
        }
    }

    /// A press is open or its answer is still to finish.
    private var frontAnswering: Bool {
        (turn.frontVia != nil || turn.frontActivityOpen) && turn.finishedUptime == nil && !turn.supersededByPress
    }

    private func geminiEventIsThisTurns(arrivalUptime: TimeInterval) -> Bool {
        guard !turn.supersededByPress, turn.lastAudioSentUptime != nil else { return false }
        return turn.geminiInterruptedUptime.map { arrivalUptime - $0 > Self.geminiInterruptedStaleSeconds } ?? true
    }

    private func openAIEventIsThisTurns(responseID: String?) -> Bool {
        guard !turn.supersededByPress, turn.lastAudioSentUptime != nil else { return false }
        return responseID.map { turn.responseIDs.contains($0) } ?? true
    }

    /// Into the trail, never into the turn: "ignored:turnComplete@-1642".
    private func ignoreStale(_ kind: String, arrivalUptime: TimeInterval, in marks: RealtimeTurnMarks? = nil) {
        let marks = marks ?? turn
        let name = "ignored:" + kind
        guard !marks.events.suffix(3).contains(where: { $0.name == name }), marks.events.count < 200 else { return }
        marks.events.append((name, arrivalUptime))
    }

    private func recordEvent(_ message: [String: Any], arrivalUptime: TimeInterval) {
        guard turn.events.count < 200 else { return }
        var names: [String]
        if let type = message["type"] as? String {
            // An error's code is the server's enum, never content.
            names = [type == "error" ? "error:" + ((message["error"] as? [String: Any])?["code"] as? String ?? "-") : type]
        } else {
            names = message.keys.sorted()
            if let serverContent = message["serverContent"] as? [String: Any] { names += serverContent.keys.sorted().map { "serverContent." + $0 } }
        }
        // Audio and transcript deltas would drown the trail; their first arrival is already a mark.
        names.removeAll { $0.hasSuffix(".delta") || $0 == "serverContent" || $0 == "serverContent.outputTranscription" }
        guard !names.isEmpty else { return }
        let name = names.joined(separator: "+")
        if turn.events.last?.name == name, names == ["serverContent.modelTurn"] { return }
        turn.events.append((name, arrivalUptime))
    }

    private func receivedAudio(_ audio: Data, arrivalUptime: TimeInterval) {
        if turn.finishedUptime != nil { turn.audioChunksAfterFinish += 1 }
        if turn.firstAudioUptime == nil {
            turn.firstAudioUptime = arrivalUptime
            if turn.toolCalls.isEmpty { JarvisNotch.shared.handle(.firstAudioWithoutTool) }
        }
        if turn.toolResultSentUptime != nil, turn.followUpFirstAudioUptime == nil { turn.followUpFirstAudioUptime = arrivalUptime }
        guard !turn.replyMuted else { return }
        onAudio?(audio)
    }

    /// OpenAI, live 2026-10-02 (rows 21, 22, 24, 25; 9 of 28 OpenAI tool turns
    /// in voice-live.log): after the tool results the follow-up response was
    /// created and finished 200-400 ms later with NO output — no audio, no call
    /// — and the turn then waited, silent, until the owner pressed again. The
    /// done event says so itself: `response.output` is an empty array.
    nonisolated static func openAIFollowUpWasEmpty(output: [Any]?, toolResultSentUptime: TimeInterval?, arrivalUptime: TimeInterval,
                                                   followUpHadAudio: Bool, toolsInFlight: Int) -> Bool {
        guard let output, output.isEmpty, let sent = toolResultSentUptime, arrivalUptime > sent else { return false }
        return !followUpHadAudio && toolsInFlight == 0
    }

    /// A `response.done` whose status is not "completed" and that carries no output:
    /// its status and `status_details.error` code (or type, or reason), else nil.
    /// A cancel of our own or by the owner speaking is not a refusal.
    nonisolated static func openAIResponseRefusal(response: [String: Any]?) -> (status: String, code: String?)? {
        guard let status = response?["status"] as? String, status != "completed",
              (response?["output"] as? [Any])?.isEmpty ?? true else { return nil }
        let details = response?["status_details"] as? [String: Any]
        let reason = details?["reason"] as? String
        if status == "cancelled", ["client_cancelled", "turn_detected"].contains(reason) { return nil }
        let error = details?["error"] as? [String: Any]
        return (status, (error?["code"] as? String) ?? (error?["type"] as? String) ?? reason)
    }

    private static func openAIFollowUpWasEmpty(response: [String: Any]?, turn: RealtimeTurnMarks, arrivalUptime: TimeInterval) -> Bool {
        openAIFollowUpWasEmpty(output: response?["output"] as? [Any], toolResultSentUptime: turn.toolResultSentUptime,
                               arrivalUptime: arrivalUptime, followUpHadAudio: turn.followUpFirstAudioUptime != nil,
                               toolsInFlight: turn.toolsInFlight)
    }

    static let emptyFollowUpReaskText = "system context, not the owner's words: the tool results above are this turn's outcome. "
        + "say what happened to the owner now, in one or two short sentences, from those results only."

    /// One more `response.create` after an empty follow-up, with a line saying
    /// what to say. Never into a turn the owner has since replaced.
    private func reaskAfterEmptyFollowUp(_ turn: RealtimeTurnMarks) async {
        guard self.turn === turn, !turn.supersededByPress else { return }
        do {
            try await sendContextText(Self.emptyFollowUpReaskText)
            turn.toolResultSentUptime = uptime
            turn.followUpFirstAudioUptime = nil
            try await sendResponseCreate(for: turn)
        } catch {
            turn.finished.settle(.failure(VoiceBenchFailure(kind: "\(stack.rawValue):reaskSendFailed")))
        }
    }

    private func receivedTurnDone(arrivalUptime: TimeInterval, givingUpOnFollowUp: Bool = false) {
        let turn = self.turn
        guard turn.toolsInFlight == 0 else { return }
        if !turn.toolCalls.isEmpty, !givingUpOnFollowUp {
            guard let resultSent = turn.toolResultSentUptime, arrivalUptime > resultSent, turn.followUpFirstAudioUptime != nil else { return }
        }
        if turn.finishedUptime == nil { turn.finishedUptime = arrivalUptime }
        turn.finished.settle(.success(arrivalUptime))
        // A find with no press leaves its "Looking for…" up; the turn is over.
        // Proof and didn't-take hold their own time and ignore this. A turn that
        // ends with no word and no call says so, rather than go quiet.
        // A card still up keeps "needs you" until its answer shows proof or didn't-take.
        if turn.cardsAwaitingOwner == 0 {
            JarvisNotch.shared.handle(turn.firstAudioUptime == nil && turn.toolCalls.isEmpty ? .noReply : .turnEnded)
        }
        onTurnFinished?()
    }

    // MARK: Tool calls

    /// do_task: the session starts the agent loop and answers at once
    /// (`RealtimeVoiceSession`), given the goal and the OWNER's own words.
    /// On the front the goal IS the owner's words: the model's never reaches the worker (`frontGoal`).
    var onDoTask: ((_ goal: String, _ heard: String, _ startBundle: String?, _ focus: OwnerFocusNote?) -> [String: Any])?
    /// Whether a task is running: then no system turn may call a tool.
    var isAgentLoopRunning: () -> Bool = { false }

    /// A call the turn itself rules out, before any other check. Review of
    /// d2fe0d7: page text the loop summarised could reach a system turn and have
    /// the voice start a new task, and narration turns kept acting while the loop
    /// acted — two planners at once. So: a task starts only from a turn the owner
    /// spoke, with their words transcribed (they, never the model's goal, are the
    /// task's heard words); a speech-only system turn, or any system turn while a
    /// task runs, calls nothing.
    /// Re-review of 2e45939 (C): an owner turn that started a task could still
    /// act beside it — in the same batch or a follow-up response — two planners
    /// again; so once its do_task started, the turn calls nothing.
    nonisolated static func turnRefusal(toolName: String, isSystemTurn: Bool, speechOnly: Bool, agentLoopRunning: Bool,
                                        heard: String?, taskStartedThisTurn: Bool = false) -> RealtimeToolRefusal? {
        if taskStartedThisTurn {
            return RealtimeToolRefusal(error: "taskStarted", message: "this request is under way now, so nothing more was done "
                + "in this turn; say only a few words, and progress comes in later system lines")
        }
        if isSystemTurn, speechOnly || agentLoopRunning || toolName == RealtimeVoiceVerbs.doTaskName {
            return RealtimeToolRefusal(error: "systemTurnCannotAct", message: "this turn was not the owner speaking, so nothing was done; "
                + "speak only, and act only when the owner asks")
        }
        // Owner 2026-10-08: a press no longer stops the task, so an owner turn beside it would be a second planner.
        if agentLoopRunning {
            return RealtimeToolRefusal(error: "taskRunning", message: "a task is still running, so nothing was done in this turn. "
                + "If the owner asked about it, answer from the task status line. If they asked for something new, ask them in a few "
                + "words whether to set the current task aside: it keeps running until they say stop or set it aside, then ask again")
        }
        guard toolName == RealtimeVoiceVerbs.doTaskName else { return nil }
        guard let heard, !heard.allSatisfy(\.isWhitespace) else {
            return RealtimeToolRefusal(error: RealtimeHeardCheck.unavailableError, message: "the owner's words were not transcribed in time, "
                + "so no task was started. Ask them, briefly, to say it again.")
        }
        return nil
    }

    private func receivedToolCalls(_ calls: [RealtimeToolCall], arrivalUptime: TimeInterval) {
        let turn = self.turn
        if turn.toolCallUptime == nil { turn.toolCallUptime = arrivalUptime }
        for providerCall in calls {
            // Every pointing format becomes fractions of the screenshot here.
            let readCall = RealtimePointFormat.normalised(providerCall, format: pointFormat, stack: stack, screenshotPixels: turn.screenshotPixelSize)
            let call = appNameOverride.map { RealtimeToolCall(callID: readCall.callID, name: readCall.name, appName: $0) } ?? readCall
            turn.toolCalls.append(call)
            let decisionIndex = turn.decisions.count
            turn.decisions.append(RealtimeToolDecision(call: call, callUptime: arrivalUptime, offeredBeforeCall: turn.latestMenuOffer?.candidates,
                                                       offeredElementsBeforeCall: turn.latestScreenOffer?.elements))
            turn.toolsInFlight += 1
            let overLimit = turn.toolCalls.count > Self.maximumToolCallsPerTurn
            let previousCall = turn.lastCallTask
            turn.lastCallTask = Task { @MainActor [weak self] in
                await Self.waitForPreviousCall(previousCall, in: turn)
                // No app named on a screen tool or a read: the app in front is meant.
                let call = await RealtimeOpenAppTool.withFrontmostApp(call)
                var dispatch: RealtimeToolDispatch
                if turn.cardAskedUptime != nil {
                    // A card of this turn is with the owner: the model asks now, and nothing more runs for it.
                    dispatch = RealtimeToolDispatch(result: RealtimeOpenAppTool.toolResult(for: Self.cardPendingRefusal), harnessMilliseconds: 0,
                                                    waitedForConfirmation: false, harnessResponse: nil)
                    turn.dispatches.append(dispatch)
                    turn.decisions[decisionIndex].dispatch = dispatch
                } else if overLimit {
                    turn.decisions[decisionIndex].offeredBeforeCall = turn.latestMenuOffer?.candidates
                    turn.decisions[decisionIndex].offeredElementsBeforeCall = turn.latestScreenOffer?.elements
                    let refusal = RealtimeToolRefusal(error: "tooManyToolCalls", message: "only \(Self.maximumToolCallsPerTurn) tool calls are allowed per turn")
                    dispatch = RealtimeToolDispatch(result: RealtimeOpenAppTool.toolResult(for: refusal), harnessMilliseconds: 0,
                                                    waitedForConfirmation: false, harnessResponse: nil)
                    turn.dispatches.append(dispatch)
                    turn.decisions[decisionIndex].dispatch = dispatch
                } else if let refusal = Self.turnRefusal(
                    toolName: call.name, isSystemTurn: turn.isSystemTurn, speechOnly: turn.speechOnly,
                    // A second request beside a running task queues on the front (`startOrQueueFront`): no second planner.
                    agentLoopRunning: self?.stack != .frontAndWorker && self?.isAgentLoopRunning() == true,
                    heard: call.name == RealtimeVoiceVerbs.doTaskName && !turn.isSystemTurn && !turn.taskStarted
                        ? await turn.waitForHeard(until: (turn.lastAudioSentUptime ?? ProcessInfo.processInfo.systemUptime)
                                                    + RealtimeHeardCheck.transcriptDeadlineAfterReleaseSeconds) : nil,
                    taskStartedThisTurn: turn.taskStarted) {
                    dispatch = RealtimeToolDispatch(result: RealtimeOpenAppTool.toolResult(for: refusal), harnessMilliseconds: 0,
                                                    waitedForConfirmation: false, harnessResponse: nil)
                    turn.dispatches.append(dispatch)
                    turn.decisions[decisionIndex].dispatch = dispatch
                } else if let handed = await self?.handedToTask(call, in: turn) {
                    dispatch = RealtimeToolDispatch(result: handed, harnessMilliseconds: 0, waitedForConfirmation: false, harnessResponse: nil)
                    turn.dispatches.append(dispatch)
                    turn.decisions[decisionIndex].dispatch = dispatch
                } else if call.name == RealtimeVoiceVerbs.doTaskName {
                    // Starts the loop and returns; the loop's own steps run every guard below,
                    // judged against the owner's words (`turnRefusal` waited for them).
                    let refusal = RealtimeToolRefusal(error: "missingGoal", message: "do_task needs the owner's request as its goal")
                    let heard = turn.heardText
                    let goal = self?.stack == .frontAndWorker ? Self.frontGoal(modelGoal: call.goal, heard: heard) : call.goal
                    let result = goal.flatMap { goal in self?.onDoTask?(goal, heard, turn.keyDownFrontBundle, turn.ownerFocus) }
                        ?? RealtimeOpenAppTool.toolResult(for: refusal)
                    if result["ok"] as? Bool == true { turn.taskStarted = true }
                    dispatch = RealtimeToolDispatch(result: result, harnessMilliseconds: 0, waitedForConfirmation: false, harnessResponse: nil)
                    turn.dispatches.append(dispatch)
                    turn.decisions[decisionIndex].dispatch = dispatch
                } else if call.name == RealtimeVoiceVerbs.taskStatusName {
                    let status = self?.onTaskStatus?() ?? "nothing is under way, and nothing has been done recently"
                    dispatch = RealtimeToolDispatch(result: ["ok": true, "status": status], harnessMilliseconds: 0, waitedForConfirmation: false, harnessResponse: nil)
                    turn.dispatches.append(dispatch)
                    turn.decisions[decisionIndex].dispatch = dispatch
                } else {
                    // `dispatch` hops off main for every harness call.
                    guard let harnessAnswer = self?.harnessAnswer else { return }
                    // A card: the model is told at once and asks in its own voice (`handCardToVoice`); this call
                    // still waits on the ticket, and its answer reaches the model as a system line (`cardAnswered`).
                    let handOff = CardHandOff()
                    let ran = await Self.runToolCall(call, decisionIndex: decisionIndex, in: turn, harnessAnswer: harnessAnswer,
                                                     onConfirmationRequired: { [weak self] in
                                                         guard handOff.send == nil, let self, self.turn === turn, !turn.supersededByPress else { return }
                                                         handOff.send = Task { @MainActor in await self.handCardToVoice(call, decisionIndex: decisionIndex, in: turn) }
                                                     },
                                                     isCurrent: { [weak self] in self?.turn === turn && !turn.supersededByPress })
                    if let send = handOff.send {
                        await send.value
                        turn.cardsAwaitingOwner -= 1
                        self?.cardAnswered(ran, call: call, in: turn)
                        return
                    }
                    guard let ran else {
                        // Superseded: recorded; no result is sent, it would start a reply inside the new turn.
                        turn.toolsInFlight -= 1
                        return
                    }
                    dispatch = ran
                }
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
                // Pressed again while the harness answered (a card, say): the action is
                // recorded as it happened, but its result must not start a reply inside
                // the new turn.
                let superseded = self?.turn !== turn || turn.supersededByPress
                await self?.sendToolResult(dispatch.result, for: call, in: turn, requestingReply: !superseded)
            }
        }
    }

    /// What the worker is given on the front: the owner's words as heard, whatever the model wrote (spec requirement 1).
    nonisolated static func frontGoal(modelGoal: String?, heard: String) -> String? {
        let words = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        return words.isEmpty ? nil : words
    }

    /// The first acting call of a turn whose words name two actions starts the task on those words instead, so
    /// the voice model cannot half-do the request in the wrong order (`RealtimeHeardCheck.namesTwoActions`). A look still
    /// runs: it changes nothing. nil: this call runs as it is. Not a new authority: the task runs on the owner's own words,
    /// through every guard its steps meet. No runner here (a probe), or one that refuses: the call runs.
    private func handedToTask(_ call: RealtimeToolCall, in turn: RealtimeTurnMarks) async -> [String: Any]? {
        guard !turn.isSystemTurn, !turn.speechOnly, let onDoTask, call.name != RealtimeVoiceVerbs.pointAtName,
              RealtimeVoiceVerbs.isActingTool(call.name) else { return nil }
        let released = turn.lastAudioSentUptime ?? ProcessInfo.processInfo.systemUptime
        guard let heard = await turn.waitForHeard(until: released + RealtimeHeardCheck.transcriptDeadlineAfterReleaseSeconds),
              RealtimeHeardCheck.namesTwoActions(heard),
              onDoTask(heard, heard, turn.keyDownFrontBundle, turn.ownerFocus)["ok"] as? Bool == true else { return nil }
        turn.taskStarted = true
        return RealtimeOpenAppTool.toolResult(for: Self.handedToTaskRefusal)
    }

    static let handedToTaskRefusal = RealtimeToolRefusal(
        error: "handedToTask", message: "this call did nothing by itself: the owner's request names more than one action, so all of it is under way "
            + "now, in the owner's order. Say only a few words; progress and the outcome come as system lines")

    // MARK: Approval cards (owner's live test 2026-10-31)

    /// Behind the call before it — unless a call of this turn hands its card to the model meanwhile: then
    /// this one goes at once (refused `cardPending`), or the model's ask would wait for the card's answer.
    private static func waitForPreviousCall(_ previous: Task<Void, Never>?, in turn: RealtimeTurnMarks) async {
        guard let previous else { return }
        let done = CardHandOff()
        Task { @MainActor in
            await previous.value
            done.previousFinished = true
        }
        while !done.previousFinished, turn.cardAskedUptime == nil { try? await Task.sleep(for: .milliseconds(20)) }
    }

    static let cardPendingRefusal = RealtimeToolRefusal(
        error: "cardPending", message: "nothing was done: an earlier step of this request is waiting on the owner's card. When they "
            + "answer it, a system line tells you what happened; after that the owner can ask for the rest")

    /// What the model gets the moment the card shows, in place of the held result. Live 2026-10-31 12:15:07Z:
    /// with the result held until the click, the model said "please click approve on screen" 3.9 s AFTER the
    /// owner clicked Allow (and after Claude had quit), and a canned nudge had spoken for it before.
    static let cardHandOffResult: [String: Any] = [
        "ok": false, "status": "awaitingOwner", "error": "confirmationRequired",
        "message": "a card is on screen now, asking the owner to allow this. Only their click on the card can allow it; words cannot. "
            + "Tell them now, in one short sentence, that it needs their click on the card. Do not call this tool again: when they "
            + "answer the card, a system line tells you what happened."
    ]

    /// The system line with the card's answer: what happened, from the harness's own result.
    /// `say: false`: a task's card, whose own lines report what comes next.
    nonisolated static func cardAnsweredText(result: [String: Any], say: Bool = true) -> String {
        let outcome: String
        switch result["error"] as? String {
        case "confirmationDenied": outcome = "the owner denied it on the card, so nothing was done"
        case "confirmationExpired", "confirmationPending": outcome = "the card expired without an answer, so nothing was done"
        default:
            outcome = result["ok"] as? Bool == true ? "the owner allowed it on the card, and it was done"
                : "the owner answered the card, and the action did not complete"
        }
        let json = String(decoding: (try? JSONSerialization.data(withJSONObject: SecretScanner.scrub(result), options: [.sortedKeys])) ?? Data("{}".utf8),
                          as: UTF8.self)
        return "system context, not the owner's words: \(outcome). The result: \(json). The card is gone: never ask for approval "
            + "again. " + (say ? "Say what happened in one short sentence, from the result only." : "The task's own lines report what comes next.")
    }

    /// "allowed" | "denied" | "expired" | "failed": the card's answer as the outcome line records it.
    nonisolated static func cardOutcome(result: [String: Any]) -> String {
        switch result["error"] as? String {
        case "confirmationDenied": return "denied"
        case "confirmationExpired", "confirmationPending": return "expired"
        default: return result["ok"] as? Bool == true ? "allowed" : "failed"
        }
    }

    /// The card is up: the model gets `cardHandOffResult` as the call's result now and asks in its own
    /// voice; the fallback clip stands back (`ConfirmationNudger.voiceAsked`).
    private func handCardToVoice(_ call: RealtimeToolCall, decisionIndex: Int, in turn: RealtimeTurnMarks) async {
        turn.cardAskedUptime = uptime
        turn.cardsAwaitingOwner += 1
        ConfirmationNudger.voiceAsked(.voiceTurn, turn: turn)
        turn.decisions[decisionIndex].dispatch = RealtimeToolDispatch(
            result: Self.cardHandOffResult, harnessMilliseconds: Int(((uptime - turn.decisions[decisionIndex].callUptime) * 1000).rounded()),
            waitedForConfirmation: true, harnessResponse: nil)
        await sendToolResult(Self.cardHandOffResult, for: call, in: turn, requestingReply: true)
    }

    /// The card was answered (or expired): the model is told what happened, so it never asks again. An ask
    /// still being said by the asking turn is cut (`replyMuted`; the session stops what is playing).
    private func cardAnswered(_ dispatch: RealtimeToolDispatch?, call: RealtimeToolCall, in turn: RealtimeTurnMarks) {
        let askStillCurrent = self.turn === turn && !turn.supersededByPress
        if askStillCurrent { turn.replyMuted = true }
        // nil: the owner pressed again before the call ran — nothing was done.
        let result = dispatch?.result ?? RealtimeOpenAppTool.toolResult(for: RealtimeToolRefusal(error: Self.supersededError, message: "nothing was done"))
        let text = Self.cardAnsweredText(result: result)
        func value(_ optional: Any?) -> Any { optional ?? NSNull() }
        let line: [String: Any] = [
            "kind": "cardOutcome", "turnId": value(turn.turnID), "stack": stack.rawValue, "tool": call.name,
            "outcome": Self.cardOutcome(result: result), "ok": value(result["ok"]), "error": value(result["error"]),
            "verification": value(result["verification"]), "harnessMs": value(dispatch?.harnessMilliseconds),
            "askSentMs": value(turn.cardAskedUptime.map { Int((($0 - (turn.lastAudioSentUptime ?? $0)) * 1000).rounded()) }),
            "answeredMs": value(turn.lastAudioSentUptime.map { Int(((uptime - $0) * 1000).rounded()) }),
            "askStillCurrent": askStillCurrent, "askAudioStarted": turn.followUpFirstAudioUptime != nil
        ]
        if let onCardAnswered {
            onCardAnswered(text, askStillCurrent, line)
        } else {
            Task { @MainActor [weak self] in try? await self?.sendContextText(text) }
        }
    }

    /// The text fields visible in `app` now, as a hint for a typing refusal (nil: none, or unreadable).
    static func visibleFieldsHint(app: String?, display: CGRect?, harnessAnswer: @escaping @Sendable (String) -> String) async -> String? {
        guard case .success(let line) = RealtimeOpenAppTool.harnessRequestLine(
            for: RealtimeToolCall(callID: "fields", name: RealtimeVoiceVerbs.findOnScreenName, appName: app, words: "field")) else { return nil }
        let screens = NSScreen.screens.map(\.frame)
        let fields = await Task.detached { () -> [String] in
            RealtimeScreenVerbs.visibleTextFieldNames(fromSnapshotResponse: RealtimeOpenAppTool.harnessResponseObject(harnessAnswer(line)),
                                                      screens: screens, screenshotDisplay: display)
        }.value
        return RealtimeOpenAppTool.unaimedTypingHint(fieldNames: fields)
    }

    /// The visible field the owner's words pick (`RealtimeOpenAppTool.fieldPicked`), or nil: the call then types into what has focus.
    private static func pageFieldNamed(by words: [String], app: String?, display: CGRect?,
                                       harnessAnswer: @escaping @Sendable (String) -> String) async -> String? {
        guard case .success(let line) = RealtimeOpenAppTool.harnessRequestLine(
            for: RealtimeToolCall(callID: "fields", name: RealtimeVoiceVerbs.findOnScreenName, appName: app, words: "field")) else { return nil }
        let screens = NSScreen.screens.map(\.frame)
        return await Task.detached { () -> String? in
            let response = RealtimeOpenAppTool.harnessResponseObject(harnessAnswer(line))
            return RealtimeOpenAppTool.fieldPicked(by: words, all: RealtimeScreenVerbs.visibleTextFieldNames(fromSnapshotResponse: response, screens: screens,
                                                                                                           screenshotDisplay: display),
                                                   inPage: RealtimeScreenVerbs.visiblePageFieldNames(fromSnapshotResponse: response, screens: screens,
                                                                                                     screenshotDisplay: display))
        }.value
    }

    /// One tool call through every guard the live turn has: the offers, the heard
    /// check (against `turn.heardText`), the site check, the screen-target
    /// resolution, the notch, `RealtimeOpenAppTool.dispatch` with its tickets, the
    /// auto-focus re-run, and the turn's records (dispatch, decision, offers).
    /// Shared by the voice turn and the agent loop (`AgentLoop`), which passes a
    /// marks object per step whose heard words are the task's goal — one path,
    /// so the loop can never be a weaker one. `call` already carries the app in
    /// front (`withFrontmostApp`). `checksSite: false` only for the loop's own
    /// search page, whose host is fixed in code. nil: `isCurrent` went false
    /// before the call ran (recorded as superseded; nothing was done).
    static func runToolCall(_ unresolvedCall: RealtimeToolCall, decisionIndex: Int, in turn: RealtimeTurnMarks,
                            harnessAnswer: @escaping @Sendable (String) -> String, checksSite: Bool = true,
                            confirmationWaitSeconds: Double = RealtimeOpenAppTool.confirmationWaitSeconds,
                            onConfirmationRequired agentCardOpened: (@MainActor () -> Void)? = nil,
                            isCurrent: @escaping @MainActor () -> Bool) async -> RealtimeToolDispatch? {
        // press_menu(shortcut:): the mapped item that owns it, by its path, so every gate below is the path's.
        let resolvedCall: RealtimeToolCall
        switch RealtimeOpenAppTool.withShortcutResolved(unresolvedCall, map: turn.affordanceMenuOffer) {
        case .success(let resolved): resolvedCall = resolved
        case .failure(let refusal):
            if let keys = RealtimeOpenAppTool.shortcutFallback(unresolvedCall, refusal: refusal) {
                resolvedCall = keys
                break
            }
            let refused = RealtimeToolDispatch(result: RealtimeOpenAppTool.toolResult(for: refusal), harnessMilliseconds: 0,
                                               waitedForConfirmation: false, harnessResponse: nil)
            turn.dispatches.append(refused)
            turn.decisions[decisionIndex].dispatch = refused
            return refused
        }
        // Read now, after the previous call finished: a find and a press sent
        // in one batch must still press what that find offered.
        var thisTurnOffer = turn.latestMenuOffer
        let thisTurnScreenOffer = turn.latestScreenOffer
        turn.decisions[decisionIndex].offeredBeforeCall = thisTurnOffer?.candidates
        turn.decisions[decisionIndex].offeredElementsBeforeCall = thisTurnScreenOffer?.elements
        var dispatch: RealtimeToolDispatch
        // Before the request, so the owner sees the intent while it runs;
        // from the tool's own argument, never from anything said aloud.
        let isKnownTool = RealtimeVoiceVerbs.allToolNames.contains(resolvedCall.name)
        // The owner's words against the tool's app, before anything is focused,
        // opened, searched or pressed.
        let heard = await heardCheck(for: resolvedCall, in: turn)
        // The owner's words, once complete (the check above waited for them).
        let heardWords = turn.heardCompletedUptime(now: ProcessInfo.processInfo.systemUptime) != nil ? turn.heardText : nil
        var call = RealtimeOpenAppTool.droppingUnsaidPointer(resolvedCall, heard: heardWords)
        // The owner's words hold what the item says, and it was never looked up: look it up here rather than tell the owner it cannot
        // be done (K17 2026-11-03: "hide that one", press_menu Calculator > Hide Calculator refused notOffered, "I can't hide the
        // calculator"). The listing is the live menu bar's, with its privacy filter; the kernel still judges the press.
        if isCurrent(), call.name == RealtimeVoiceVerbs.pressMenuName, let path = call.path, let label = path.last, heardWords != nil,
           RealtimeDecisionTrace.heardOverlapsLabel(heard: heardWords, path: path) == true,
           RealtimeOpenAppTool.pressOffer(path: path, thisTurn: thisTurnOffer, previousTurn: turn.previousTurnMenuOffer,
                                          followUpConfirmed: heard?.followUpConfirmed, confirmedByYes: heard?.confirmedByYes == true,
                                          affordanceMap: turn.affordanceMenuOffer, now: ProcessInfo.processInfo.systemUptime).offer == nil {
            let find = RealtimeToolCall(callID: call.callID, name: RealtimeVoiceVerbs.findMenuItemsName, appName: call.appName, words: label)
            let found = await RealtimeOpenAppTool.dispatch(find, answer: harnessAnswer, confirmationWaitSeconds: confirmationWaitSeconds, onConfirmationRequired: {})
            if let offer = found.menuOffer, let real = RealtimeOpenAppTool.offeredPath(matching: path, among: offer.candidates) {
                thisTurnOffer = RealtimeStandingOffer(candidates: offer.candidates, app: found.appCheck?["resolvedBundleId"] as? String,
                                                      uptime: ProcessInfo.processInfo.systemUptime)
                turn.latestMenuOffer = thisTurnOffer
                call.path = real
            }
        }
        // "close that calculator thing" is a window; a quit is for when the owner says so (a Quit card is theirs to answer, and asking is the cost).
        if call.name == RealtimeVoiceVerbs.closeName { call.what = RealtimeHandsVerbs.closeTarget(what: call.what, heard: heardWords) }
        // "Type hello in the search box": the field the owner's own words name, read off the live screen, outranks the model's
        // aim. Gemini sent no aim, an unsaid pointer, or the page itself as the name, then told the owner the box could not be
        // typed in (A5, A9, C5 2026-11-03). "this box" with the pointer stays the pointer's; no field picked, the model's aim stands.
        if isCurrent(), !turn.isAgentStep, call.name == RealtimeVoiceVerbs.typeTextName, !call.underPointer,
           let words = RealtimeOpenAppTool.fieldWords(inHeard: heardWords),
           let field = await pageFieldNamed(by: words, app: call.appName, display: turn.screenshotDisplayFrame, harnessAnswer: harnessAnswer) {
            call.elementName = field
            call.x = nil
            call.y = nil
        }
        // create_reminder's due is the owner's words, never the model's: always replaced, waited for like the site check's.
        // read_calendar's range is read from the same words, before the model's `when`.
        if RealtimeVoiceVerbs.eventKitWriterNames.contains(call.name) || call.name == RealtimeVoiceVerbs.readCalendarName {
            let released = turn.lastAudioSentUptime ?? ProcessInfo.processInfo.systemUptime
            call.words = await turn.waitForHeard(until: released + RealtimeHeardCheck.transcriptDeadlineAfterReleaseSeconds)
        }
        // open_url: the owner's words must name the site (hands design item 7).
        var siteRefusal: [String: Any]?
        if call.name == RealtimeVoiceVerbs.openURLName, checksSite {
            let released = turn.lastAudioSentUptime ?? ProcessInfo.processInfo.systemUptime
            siteRefusal = RealtimeHeardCheck.siteRefusal(
                transcript: await turn.waitForHeard(until: released + RealtimeHeardCheck.transcriptDeadlineAfterReleaseSeconds),
                url: call.url)
        }
        // "is xcode open?" is answered, not acted on: a read must not move the owner's windows (K15 2026-11-03).
        if !turn.isAgentStep, siteRefusal == nil, heard?.refusal == nil, [RealtimeVoiceVerbs.focusAppName, RealtimeOpenAppTool.name].contains(call.name),
           let words = heardWords, RealtimeHeardCheck.isYesNoQuestion(words), let named = call.appName {
            let running = await Task.detached { RealtimeVoiceVerbs.isRunning(named: named) }.value
            siteRefusal = RealtimeHeardCheck.questionRefusal(named: named, isRunning: running)
        }
        // Which offer the notOffered gate judges by: this turn's, or the previous
        // turn's when the owner's own words name the item. The trace records it.
        // point_at / press_element: a name from the offer, a screenshot
        // position (hit-tested) or the owner's pointer, resolved here.
        // scroll / type_text resolve a target only when they were given one
        // (none: the main area, the focused field).
        let isScreenTarget = RealtimeVoiceVerbs.isScreenTargetTool(call.name)
            || (RealtimeVoiceVerbs.aimsAtScreen(call.name)
                && (call.elementName != nil || call.x != nil || call.y != nil || call.underPointer))
        let chosen = RealtimeOpenAppTool.pressOffer(path: call.path, thisTurn: thisTurnOffer, previousTurn: turn.previousTurnMenuOffer,
                                                    followUpConfirmed: heard?.followUpConfirmed, confirmedByYes: heard?.confirmedByYes == true,
                                                    affordanceMap: turn.affordanceMenuOffer, now: ProcessInfo.processInfo.systemUptime)
        let offered = isScreenTarget ? nil : chosen.offer?.candidates
        let offeredApp = isScreenTarget ? nil : chosen.offer?.app
        var screenTarget: RealtimeScreenTarget?
        var dropTarget: RealtimeScreenTarget?
        var screenRefusal: RealtimeToolRefusal?
        if isScreenTarget {
            let rung = RungBox()
            let screens = NSScreen.screens.map(\.frame)
            let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
            let resolved = await RealtimeOpenAppTool.resolveScreenTarget(
                call: call, thisTurn: thisTurnScreenOffer, previousTurn: turn.previousTurnScreenOffer,
                followUpConfirmed: heard?.followUpConfirmed, confirmedByYes: heard?.confirmedByYes == true,
                now: ProcessInfo.processInfo.systemUptime, screenshotDisplay: turn.screenshotDisplayFrame,
                screenshotStale: RealtimeOpenAppTool.screenshotIsStale(decisions: Array(turn.decisions[..<decisionIndex]),
                                                                      freshLookOutcome: turn.freshLookOutcome),
                keyDownPointer: turn.keyDownPointer, heard: heardWords,
                // Ordinals pick only in a voice turn: an agent step's words are the whole
                // task, whose "first" may mean another step's thing.
                ordinalWords: turn.isAgentStep ? nil : heardWords,
                lookUp: { name in
                    // By bundle, as `dispatch` aims: "Chrome" is Google Chrome's word, not its name.
                    let appName = call.appName
                    let app = await Task.detached { () -> String? in
                        guard let appName else { return nil }
                        if case .resolved(let bundle, _) = RealtimeVoiceVerbs.appIdentity(named: appName) { return bundle }
                        return appName
                    }.value
                    let found = await RealtimeOpenAppTool.liveLookup(named: name, app: app, answer: harnessAnswer, screens: screens,
                                                                     screenshotDisplay: turn.screenshotDisplayFrame)
                    // A name the window lacks may be a Dock icon or a menu-bar item: pointed at, or (owner's ruling
                    // 2026-10-31) pressed or dragged by the pointer, which judges what is there itself.
                    guard [RealtimeVoiceVerbs.pointAtName, RealtimeVoiceVerbs.pressElementName, RealtimeVoiceVerbs.dragItemName]
                        .contains(call.name), !call.open else { return found }
                    return await RealtimeOpenAppTool.withSystemUIFallback(found, named: name, frontApp: app, answer: harnessAnswer, screens: screens)
                },
                lookUpResults: {
                    // The app in front, as the hit test reads it.
                    await RealtimeOpenAppTool.liveLookup(named: "result", app: call.appName, answer: harnessAnswer, screens: screens,
                                                         screenshotDisplay: turn.screenshotDisplayFrame, results: true)
                }) { point in
                    let answered = await RealtimeOpenAppTool.screenHit(at: point, app: call.appName, answer: harnessAnswer, screens: screens,
                                                                       primaryDisplayHeight: primaryHeight,
                                                                       deadlineSeconds: hitTestDeadlineSeconds,
                                                                       roles: call.name == RealtimeVoiceVerbs.typeTextName
                                                                           ? RealtimeScreenVerbs.textInputRoles : nil)
                    rung.value = answered.rung
                    return answered.hit
                }
            // drag_item's drop end: aimed exactly as its start, by name or position (`dropCall`).
            var resolvedDrop: Result<RealtimeScreenTarget, RealtimeToolRefusal>?
            if call.name == RealtimeVoiceVerbs.dragItemName, case .success = resolved {
                resolvedDrop = await RealtimeOpenAppTool.resolveScreenTarget(
                    call: RealtimeOpenAppTool.dropCall(call), thisTurn: thisTurnScreenOffer, previousTurn: turn.previousTurnScreenOffer,
                    followUpConfirmed: heard?.followUpConfirmed, confirmedByYes: heard?.confirmedByYes == true,
                    now: ProcessInfo.processInfo.systemUptime, screenshotDisplay: turn.screenshotDisplayFrame,
                    screenshotStale: RealtimeOpenAppTool.screenshotIsStale(decisions: Array(turn.decisions[..<decisionIndex]),
                                                                          freshLookOutcome: turn.freshLookOutcome),
                    keyDownPointer: nil, heard: heardWords, ordinalWords: nil,
                    lookUp: { name in
                        let appName = call.appName
                        let app = await Task.detached { () -> String? in
                            guard let appName else { return nil }
                            if case .resolved(let bundle, _) = RealtimeVoiceVerbs.appIdentity(named: appName) { return bundle }
                            return appName
                        }.value
                        let found = await RealtimeOpenAppTool.liveLookup(named: name, app: app, answer: harnessAnswer, screens: screens,
                                                                         screenshotDisplay: turn.screenshotDisplayFrame)
                        return await RealtimeOpenAppTool.withSystemUIFallback(found, named: name, frontApp: app, answer: harnessAnswer, screens: screens)
                    }) { point in
                        await RealtimeOpenAppTool.screenHit(at: point, app: call.appName, answer: harnessAnswer, screens: screens,
                                                            primaryDisplayHeight: primaryHeight, deadlineSeconds: hitTestDeadlineSeconds).hit
                    }
            }
            switch (resolved, resolvedDrop) {
            case (.failure(let refusal), _), (_, .failure(let refusal)?): screenRefusal = refusal
            case (.success(let target), let drop):
                screenTarget = target
                if case .success(let end)? = drop { dropTarget = end }
                // Which rung named it: the offer, the key-down pointer, the walk or AX.
                turn.decisions[decisionIndex].snappedBy = target.source == .screenshotPoint ? (rung.value ?? "none") : target.source.rawValue
            }
            turn.decisions[decisionIndex].offeredElementsBeforeCall = (thisTurnScreenOffer ?? turn.previousTurnScreenOffer)?.elements
        } else {
            turn.decisions[decisionIndex].offeredBeforeCall = offered
            // annotate's underPointer shapes: the key-down pointer, as point_at's.
            if call.name == RealtimeVoiceVerbs.annotateName { screenTarget = turn.keyDownPointer }
        }
        // The owner pressed the key again while this call waited: whatever
        // it would do answers a turn nobody is waiting on. Never run it.
        func recordSuperseded(autoFocus: [String: Any]? = nil) -> RealtimeToolDispatch? {
            let refusal = RealtimeToolRefusal(error: supersededError,
                                              message: "the owner started a new request before this call ran; nothing was done")
            var superseded = RealtimeToolDispatch(result: RealtimeOpenAppTool.toolResult(for: refusal), harnessMilliseconds: 0,
                                                  waitedForConfirmation: false, harnessResponse: nil)
            superseded.heardCheck = heard?.trace
            superseded.heardOverlapsLabel = heard?.overlapsLabel
            superseded.autoFocus = autoFocus
            turn.dispatches.append(superseded)
            turn.decisions[decisionIndex].dispatch = superseded
            return nil
        }
        guard isCurrent() else { return recordSuperseded() }
        if isKnownTool {
            JarvisNotch.shared.handle(.toolCall(title: RealtimeVoiceVerbs.intentTitle(for: call)))
            if turn.intentShownUptime == nil { turn.intentShownUptime = ProcessInfo.processInfo.systemUptime }
        }
        if let refusal = heard?.refusal ?? siteRefusal {
            dispatch = RealtimeToolDispatch(result: refusal, harnessMilliseconds: 0, waitedForConfirmation: false, harnessResponse: nil)
            JarvisNotch.shared.handle(.harnessAnswered(ok: false, subject: RealtimeOpenAppTool.captionName(heard?.heardApp ?? ""),
                                                       error: refusal["error"] as? String))
        } else if let screenRefusal {
            dispatch = RealtimeToolDispatch(result: RealtimeOpenAppTool.toolResult(for: screenRefusal), harnessMilliseconds: 0,
                                            waitedForConfirmation: false, harnessResponse: nil)
            JarvisNotch.shared.handle(.harnessAnswered(ok: false, subject: "", error: screenRefusal.error))
            // A typing aim that named no field: say which fields are there (A5, C2 03-34-52Z; A9 20-10-57Z: "Post box").
            if call.name == RealtimeVoiceVerbs.typeTextName, RealtimeOpenAppTool.typingRefusalsListingFields.contains(screenRefusal.error),
               let hint = await visibleFieldsHint(app: call.appName, display: turn.screenshotDisplayFrame, harnessAnswer: harnessAnswer) {
                dispatch.result["message"] = screenRefusal.message + hint
            }
        } else {
            let onConfirmationRequired: @MainActor () -> Void = {
                if isKnownTool { JarvisNotch.shared.handle(.confirmationRequired) }
                agentCardOpened?()
            }
            dispatch = await RealtimeOpenAppTool.dispatch(call, offered: offered, offeredApp: offeredApp, screenTarget: screenTarget,
                                                          dropTarget: dropTarget, screenshotDisplay: turn.screenshotDisplayFrame,
                                                          answer: heard?.unnamedApp == nil ? harnessAnswer : unnamedAppAnswer(harnessAnswer),
                                                          confirmationWaitSeconds: confirmationWaitSeconds,
                                                          onConfirmationRequired: onConfirmationRequired)
            dispatch.unnamedAppBundle = heard?.unnamedApp
            // Unaimed typing met no focused field: name the fields that are there (A9 live 02-30-16Z).
            if call.name == RealtimeVoiceVerbs.typeTextName, call.elementName == nil, call.x == nil, !call.underPointer,
               dispatch.result["error"] as? String == "kernelRefused", (dispatch.result["message"] as? String)?.contains("does not accept text") == true,
               let hint = await visibleFieldsHint(app: call.appName, display: turn.screenshotDisplayFrame, harnessAnswer: harnessAnswer),
               let message = dispatch.result["message"] as? String {
                dispatch.result["message"] = message + hint
            }
            if turn.isAgentStep, call.name == RealtimeVoiceVerbs.pressMenuName, dispatch.result["error"] as? String == "notOffered" {
                // By the call's own app: a path outside every offer is refused before any app check is recorded.
                let appName = call.appName
                let callBundle = await Task.detached { () -> String? in
                    guard let appName, case .resolved(let bundle, _) = RealtimeVoiceVerbs.appIdentity(named: appName) else { return nil }
                    return bundle
                }.value
                let listed = callBundle != nil && turn.affordanceMenuOffer?.app == callBundle
                dispatch.result["message"] = RealtimeOpenAppTool.agentStepNotOfferedMessage(menuListed: listed)
            }
            // Both witnesses name one running app and only the app in front is
            // wrong: bring it forward through the harness (policy applies), then
            // run this call ONCE more. Never a loop, never a launch.
            let resolvedBundle = dispatch.appCheck?["resolvedBundleId"] as? String
            let namedAppIsRunning = await Task.detached { resolvedBundle.map { RealtimeVoiceVerbs.isRunning(named: $0) } ?? false }.value
            if let gate = RealtimeHeardCheck.autoFocusGate(heard: heard?.decision, dispatchError: dispatch.result["error"] as? String,
                                                           resolvedBundleIdentifier: resolvedBundle, namedAppIsRunning: namedAppIsRunning) {
                var autoFocus: [String: Any] = ["triggered": gate.triggered, "reason": gate.reason,
                                                "focusStatus": NSNull(), "focusMs": NSNull(), "retried": false]
                if gate.triggered, let resolvedBundle {
                    let shownName = (dispatch.result["named"] as? String) ?? resolvedBundle
                    JarvisNotch.shared.handle(.toolCall(title: "Switching to \(RealtimeOpenAppTool.captionName(shownName))\u{2026}"))
                    let focusCall = RealtimeToolCall(callID: call.callID, name: RealtimeVoiceVerbs.focusAppName, appName: resolvedBundle)
                    let focus = await RealtimeOpenAppTool.dispatch(focusCall, answer: harnessAnswer, confirmationWaitSeconds: confirmationWaitSeconds,
                                                                   onConfirmationRequired: onConfirmationRequired)
                    autoFocus["focusStatus"] = focus.harnessConfirmed ? ((focus.result["verification"] as? String) ?? "ok")
                        : ((focus.result["error"] as? String) ?? "failed")
                    autoFocus["focusMs"] = focus.harnessMilliseconds
                    if !focus.harnessConfirmed {
                        // The focus's own refusal is the answer.
                        dispatch.result = focus.result
                        dispatch.result["message"] = "\(shownName) was not in front, so bringing it forward was tried first, and that "
                            + "did not work (\((focus.result["message"] as? String) ?? "no reason given")). Nothing was searched or pressed."
                    } else {
                        guard isCurrent() else { return recordSuperseded(autoFocus: autoFocus) }
                        JarvisNotch.shared.handle(.toolCall(title: RealtimeVoiceVerbs.intentTitle(for: call)))
                        dispatch = await RealtimeOpenAppTool.dispatch(call, offered: offered, offeredApp: offeredApp,
                                                                      screenTarget: screenTarget, dropTarget: dropTarget, answer: harnessAnswer,
                                                                      confirmationWaitSeconds: confirmationWaitSeconds,
                                                                      onConfirmationRequired: onConfirmationRequired)
                        autoFocus["retried"] = true
                    }
                }
                dispatch.autoFocus = autoFocus
            }
            // Proof only from the harness's own ok: true.
            if isKnownTool, let answered = RealtimeOpenAppTool.notchAnswer(for: call, dispatch: dispatch) {
                JarvisNotch.shared.handle(answered)
            }
        }
        dispatch.heardCheck = heard?.trace
        dispatch.heardOverlapsLabel = heard?.overlapsLabel
        if RealtimeOpenAppTool.passedOfferGate(toolName: call.name, dispatch: dispatch) {
            turn.decisions[decisionIndex].offerSource = isScreenTarget ? screenTarget?.source : chosen.source
        }
        if chosen.source == .affordanceMap, let app = chosen.offer?.app,
           RealtimeOpenAppTool.invalidatesAffordanceMap(error: dispatch.result["error"] as? String) {
            AffordanceMapCache.shared.invalidate(bundle: app)
        }
        turn.dispatches.append(dispatch)
        turn.decisions[decisionIndex].dispatch = dispatch
        // "Delete the first draft": the find lists three Deletes and the owner's words already said which (C4 2026-11-03: Gemini asked).
        if !turn.isAgentStep, call.name == RealtimeVoiceVerbs.findOnScreenName, let hint = RealtimeOpenAppTool.ordinalHint(heard: heardWords, found: dispatch.screenOffer?.candidates) {
            dispatch.result["ownersOrder"] = hint
            turn.dispatches[turn.dispatches.count - 1] = dispatch
            turn.decisions[decisionIndex].dispatch = dispatch
        }
        // A find that finished after the owner pressed again answered nobody:
        // the model never got its result, so it is no offer to press or confirm.
        if let offer = dispatch.menuOffer, isCurrent() {
            turn.latestMenuOffer = RealtimeStandingOffer(candidates: offer.candidates,
                                                         app: dispatch.appCheck?["resolvedBundleId"] as? String,
                                                         uptime: ProcessInfo.processInfo.systemUptime)
        }
        if let offer = dispatch.screenOffer, isCurrent() {
            turn.latestScreenOffer = RealtimeStandingOffer(candidates: [], app: dispatch.appCheck?["resolvedBundleId"] as? String,
                                                           uptime: ProcessInfo.processInfo.systemUptime, elements: offer.candidates)
        }
        return dispatch
    }

    /// An agent step acts only where the owner put it: in an app their words
    /// name, the app in front when the task began, or one the task opened by
    /// such a step (live 2026-10-03 B5: "read this page and summarise it" — the
    /// voice opened TextEdit unasked and the loop typed the summary into it).
    /// Reads are never refused (`mayRefuse`).
    nonisolated static func agentStepActsInUnnamedApp(outcome: RealtimeHeardCheck.Outcome, mayRefuse: Bool, callBundle: String?,
                                                      startBundle: String?, openedByTask: Set<String>, wordsNameTheApp: Bool = false) -> Bool {
        guard mayRefuse, outcome == .noAppHeard, !wordsNameTheApp, let callBundle else { return false }
        return callBundle != startBundle && !openedByTask.contains(callBundle)
    }

    /// Such a step is no longer refused here (owner's ruling 2026-10-24: "ask me with a card"): every
    /// request it sends carries `unnamedApp`, which the harness's `gate` turns from an allow into a card.
    /// A line it cannot mark is refused, never sent on unmarked — unmarked, the question would be gone.
    nonisolated static func unnamedAppAnswer(_ answer: @escaping @Sendable (String) -> String) -> @Sendable (String) -> String {
        { line in
            guard var request = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return unnamedAppUnreadable }
            request["unnamedApp"] = true
            guard let data = try? JSONSerialization.data(withJSONObject: request, options: [.sortedKeys]) else { return unnamedAppUnreadable }
            return answer(String(decoding: data, as: UTF8.self))
        }
    }
    nonisolated static let unnamedAppUnreadable = "{\"ok\":false,\"error\":\"unnamedAppUnreadable\",\"message\":\"nothing was done: "
        + "the owner's words do not name this app, and the request could not be marked to ask them on a card\"}"

    /// An agent step proceeds past another app heard, or an unrecognised slot word, when the owner's
    /// words also name the call's own app (`RealtimeHeardCheck.wordsNameTheApp`, transcript only — a page
    /// cannot widen it). Never past ambiguity or an unconfirmed retry.
    nonisolated static func agentStepNamedByOwnersWords(outcome: RealtimeHeardCheck.Outcome, wordsNameTheApp: Bool) -> Bool {
        wordsNameTheApp && (outcome == .heardNamedMismatch || outcome == .appNameUnclear)
    }

    /// An agent step's heardNamedMismatch proceeds only in an app or tab this task
    /// opened itself (what the task opened, it opened on the owner's words), or in the
    /// app in front when the owner asked: the app their words named is where it ends,
    /// the one they were looking at is where it starts. Scenario run 2026-10-18T20-45-38Z
    /// B13 "copy the order number into a new textedit note" with the order page in Chrome:
    /// every Chrome step refused, so the task ended done with an empty note. The start app
    /// already acts when no app is heard (`agentStepActsInUnnamedApp`); naming the
    /// destination takes nothing away from it.
    nonisolated static func agentStepMayActDespiteMismatch(outcome: RealtimeHeardCheck.Outcome, callBundle: String?,
                                                           openedByTask: Set<String>, startBundle: String? = nil) -> Bool {
        guard outcome == .heardNamedMismatch, let callBundle else { return false }
        return openedByTask.contains(callBundle) || callBundle == startBundle
    }

    /// An agent step's appNameUnclear proceeds only in an app the task opened
    /// or focused itself, and never when an unclear word is within two edits of
    /// an installed app's name or a word of it ("slak" / Slack).
    nonisolated static func agentStepMayActDespiteUnclearWord(callBundle: String?, openedByTask: Set<String>, unclearWords: [String],
                                                              among names: [RealtimeVoiceVerbs.AppName]) -> Bool {
        guard let callBundle, openedByTask.contains(callBundle) else { return false }
        let appWords = Set(names.flatMap { name -> [String] in
            let tokens = RealtimeVoiceVerbs.foldedTokens(name.name)
            return tokens + [tokens.joined()]
        }.filter { $0.count >= 3 })
        return !unclearWords.map { RealtimeVoiceVerbs.foldedTokens($0).joined() }.contains { word in
            word.count >= 3 && appWords.contains { editDistance(word, $0) <= (min(word.count, $0.count) <= 4 ? 1 : 2) }
        }
    }

    nonisolated static func editDistance(_ first: String, _ second: String) -> Int {
        let a = Array(first), b = Array(second)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count]
    }

    /// Waits (bounded) for this turn's transcript, then decides. nil for a call
    /// that names no app (it is refused as `missingAppName` anyway).
    private static func heardCheck(for call: RealtimeToolCall, in turn: RealtimeTurnMarks) async
        -> (refusal: [String: Any]?, heardApp: String?, decision: RealtimeHeardCheck.Decision, trace: [String: Any], overlapsLabel: Bool?,
            followUpConfirmed: Bool?, confirmedByYes: Bool, unnamedApp: String?)? {
        guard RealtimeHeardCheck.appliesTo(toolName: call.name), let appName = call.appName else { return nil }
        // An app filled in from the one in front is a bundle identifier; the words are matched against names.
        let named = await Task.detached { () -> String in
            guard appName.contains("."), !appName.contains(" "),
                  case .resolved(_, let name) = RealtimeVoiceVerbs.appIdentity(named: appName) else { return appName }
            return name
        }.value
        let waitStart = ProcessInfo.processInfo.systemUptime
        // Which app is in front, bounded like the key-down line: a word for
        // something inside it is not another app (`withoutWordsInsideTheNamedApp`).
        async let frontmostApp = RealtimeVoiceSession.value(within: RealtimeVoiceSession.frontmostReadDeadlineSeconds) {
            AccessibilityTreeWalker.focusedApplication()?.bundleURL
        }
        // The labels recently offered to the model (the offer memory's window), per app.
        let recentOffers = [turn.latestMenuOffer, turn.previousTurnMenuOffer, turn.latestScreenOffer, turn.previousTurnScreenOffer]
            .compactMap { $0 }.filter { waitStart - $0.uptime <= RealtimeOpenAppTool.previousTurnOfferMaximumAgeSeconds }
            .map { (app: $0.app, labels: $0.candidates.flatMap(\.path) + $0.elements.map(\.name)) }
            // "this one": the element under the owner's pointer at key-down is the call's target too.
            + (call.underPointer ? [turn.keyDownPointer].compactMap { $0 }.compactMap { pointer in
                pointer.candidate.map { (app: pointer.app, labels: [$0.name]) } } : [])
        let released = turn.lastAudioSentUptime ?? waitStart
        let transcript = await turn.waitForHeard(until: released + RealtimeHeardCheck.transcriptDeadlineAfterReleaseSeconds)
        let waitedMs = Int(((ProcessInfo.processInfo.systemUptime - waitStart) * 1000).rounded())
        // The app list reads the file system: off main.
        let afterHeardRefusal = turn.heardRefusals > 0
        let menuWords = RealtimeVoiceVerbs.foldedTokens(([call.words ?? "", call.elementName ?? ""] + (call.path ?? [])).joined(separator: " "))
        let frontmost = await frontmostApp
        // What the call puts into the app is content, never the app meant: the text typed, the site opened.
        let content = call.name == RealtimeVoiceVerbs.typeTextName ? (call.text ?? "")
            : call.name == RealtimeVoiceVerbs.openURLName ? ([call.url.flatMap(RealtimeHeardCheck.siteName(of:)), call.url.flatMap { URL(string: $0)?.host }]
                .compactMap { $0 }.joined(separator: " ")) : ""
        let isAgentStep = turn.isAgentStep
        let agentOpenedBundles = turn.agentOpenedBundles
        let agentStartBundle = turn.agentStartBundle
        let mayRefuseCall = RealtimeHeardCheck.mayRefuse(toolName: call.name)
        let (decision, namedAppIsRunning, actsInUnnamedApp, callIsPageApp) = await Task.detached { () -> (RealtimeHeardCheck.Decision, Bool, String?, Bool) in
            var callBundle: String?
            if case .resolved(let bundleIdentifier, _) = RealtimeVoiceVerbs.appIdentity(named: appName) { callBundle = bundleIdentifier }
            let pageApp = RealtimeHeardCheck.isPageApp(callBundle: callBundle, startBundle: agentStartBundle,
                                                       frontmostBundle: frontmost.flatMap { Bundle(url: $0)?.bundleIdentifier },
                                                       openedByTask: agentOpenedBundles)
            let offered = recentOffers.filter { $0.app != nil && $0.app == callBundle }.flatMap(\.labels)
            // A browser named: "LinkedIn within this browser" is a page inside it.
            let namedIsBrowser = callBundle.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.map { appURL in
                HarnessHands.handlesWeb(appURL: appURL, webHandlers: NSWorkspace.shared.urlsForApplications(toOpen: URL(string: "https://example.com")!))
            } ?? false
            let decision = RealtimeHeardCheck.decide(transcript: transcript, named: named, among: RealtimeVoiceVerbs.installedAppNames(),
                                                     afterHeardRefusal: afterHeardRefusal, toolName: call.name, menuWords: menuWords,
                                                     targetWords: menuWords + RealtimeVoiceVerbs.foldedTokens(offered.joined(separator: " ")),
                                                     frontmostApp: frontmost, contentWords: RealtimeHeardCheck.contentTokens(content),
                                                     namedIsBrowser: namedIsBrowser, isWebAppShim: RealtimeHeardCheck.isWebAppShim(appURL:),
                                                     isHelper: RealtimeVoiceVerbs.isBackgroundHelper(appURL:))
            // A request names what it is about ("search Google for Superloop"): live
            // 2026-10-03 its "superloop" sat in the app slot and every scroll of the
            // task was refused heardUnavailable. appNameUnclear still means "ask"
            // (review of d2fe0d7: "post this in Slak" would type into whatever was
            // in front), except in an app this task itself opened or focused, and
            // only when no unclear word resembles an installed app.
            // The owner's own words name THIS app too (R1: "into a new note" is Notes) beside another app or a
            // topic word: they named both (launch M03 2026-10-17, "…in Safari into a new note": every Notes step
            // refused heardNamedMismatch; M01 "…in Sydney … a new note": refused heardUnavailable on "sydney").
            let ownWordsNameIt = isAgentStep && RealtimeHeardCheck.wordsNameTheApp(transcript: transcript, named: named, among: RealtimeVoiceVerbs.installedAppNames())
            // A match, not noAppHeard: the owner named it, so it is no page word either (M03 re-run: "the lighthouse
            // page" then refused open_app Notes as pageNotApp).
            if isAgentStep, agentStepNamedByOwnersWords(outcome: decision.outcome, wordsNameTheApp: ownWordsNameIt) {
                var proceeding = RealtimeHeardCheck.Decision(outcome: .match, heardApps: [named], tier: nil)
                proceeding.heardSlot = decision.heardSlot
                return (proceeding, true, nil, pageApp)
            }
            if isAgentStep, decision.outcome == .appNameUnclear,
               agentStepMayActDespiteUnclearWord(callBundle: callBundle, openedByTask: agentOpenedBundles,
                                                 unclearWords: decision.heardSlot, among: RealtimeVoiceVerbs.installedAppNames()) {
                var proceeding = RealtimeHeardCheck.Decision(outcome: .noAppHeard, heardApps: [], tier: nil)
                proceeding.heardSlot = decision.heardSlot
                return (proceeding, true, nil, pageApp)
            }
            // The same for another app named where to act: a page this task opened is its own
            // (live 2026-10-08: "…then send it on LinkedIn" refused every press in the Meet tab it opened).
            if isAgentStep, agentStepMayActDespiteMismatch(outcome: decision.outcome, callBundle: callBundle, openedByTask: agentOpenedBundles,
                                                            startBundle: agentStartBundle) {
                var proceeding = RealtimeHeardCheck.Decision(outcome: .noAppHeard, heardApps: [], tier: nil)
                proceeding.heardSlot = decision.heardSlot
                return (proceeding, true, nil, pageApp)
            }
            // The bundle, so the harness is asked about it and the task keeps it once the owner allows it.
            let unnamed = isAgentStep && agentStepActsInUnnamedApp(
                outcome: decision.outcome, mayRefuse: mayRefuseCall, callBundle: callBundle, startBundle: agentStartBundle,
                openedByTask: agentOpenedBundles,
                wordsNameTheApp: ownWordsNameIt) ? callBundle : nil
            // Only asked when it decides: open_app with no transcript.
            guard decision.outcome == .transcriptMissing, call.name == RealtimeOpenAppTool.name else { return (decision, true, unnamed, pageApp) }
            return (decision, RealtimeVoiceVerbs.isRunning(named: named), unnamed, pageApp)
        }.value
        let arrivalMs = turn.heardCompletedUptime(now: ProcessInfo.processInfo.systemUptime).map { Int((($0 - released) * 1000).rounded()) }
        // A read is never refused here (`mayRefuse`); its decision still drives auto-focus.
        var refusal = RealtimeHeardCheck.mayRefuse(toolName: call.name)
            ? RealtimeHeardCheck.refusal(for: decision, toolName: call.name, named: named, namedAppIsRunning: namedAppIsRunning,
                                         isAgentStep: isAgentStep) : nil
        if refusal == nil, RealtimeHeardCheck.refusesOpeningAnApp(toolName: call.name, outcome: decision.outcome, transcript: transcript,
                                                                   callIsPageApp: callIsPageApp, named: named) {
            refusal = RealtimeHeardCheck.pageNotAppRefusal(named: named)
        }
        // Last, as the refusal it replaces was: every other refusal still answers first.
        let unnamedApp = refusal == nil ? actsInUnnamedApp : nil
        if refusal != nil { turn.heardRefusals += 1 }
        // The item a press or a point names.
        let isPoint = RealtimeVoiceVerbs.isScreenTargetTool(call.name)
        let label = isPoint ? call.elementName : call.path?.last
        let choosing = call.name == RealtimeVoiceVerbs.pressMenuName || isPoint
        return (refusal, decision.heardApps.first, decision,
                RealtimeHeardCheck.traceObject(decision, named: named, transcriptArrivalMs: arrivalMs, waitedMs: waitedMs, refused: refusal != nil),
                call.name == RealtimeVoiceVerbs.pressMenuName ? RealtimeDecisionTrace.heardOverlapsLabel(heard: transcript, path: call.path) : nil,
                choosing ? RealtimeDecisionTrace.followUpConfirmed(heard: transcript, path: label.map { [$0] }) : nil,
                RealtimeOpenAppTool.plainYesConfirms(call: call, heard: transcript, previousSaid: turn.previousTurnSaid,
                                                     previousMenu: turn.previousTurnMenuOffer, previousScreen: turn.previousTurnScreenOffer),
                unnamedApp)
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

    /// The wire form of a tool result, scrubbed: element names (`listedName`), a
    /// pointer-hit name or a heard line can carry a key the app shows as text.
    nonisolated static func toolResultMessage(stack: VoiceStackChoice, result: [String: Any],
                                              call: RealtimeToolCall) -> [String: Any] {
        let result = SecretScanner.scrub(result)
        switch stack {
        case .openAIRealtime:
            let output = String(decoding: (try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])) ?? Data("{}".utf8), as: UTF8.self)
            return ["type": "conversation.item.create",
                    "item": ["type": "function_call_output", "call_id": call.callID, "output": output]]
        case .geminiLive, .frontAndWorker:
            return ["toolResponse": ["functionResponses": [["id": call.callID, "name": call.name, "response": result]]]]
        case .cascade:
            let output = String(decoding: (try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])) ?? Data("{}".utf8), as: UTF8.self)
            return ["type": "tool_result", "tool_use_id": call.callID, "content": output]
        }
    }

    /// `requestingReply: false` (a superseded turn): OpenAI still gets the
    /// `function_call_output`, so every call item in its conversation keeps its
    /// output and the model's context says what was actually done — but no
    /// `response.create`. Gemini gets nothing: its `toolResponse` IS the request
    /// to reply, and its interrupted answer's call needs none.
    private func sendToolResult(_ result: [String: Any], for call: RealtimeToolCall, in turn: RealtimeTurnMarks,
                                requestingReply: Bool) async {
        // Decremented BEFORE the send that can start the follow-up, so that
        // follow-up's done event can never find this call still "in flight".
        do {
            switch stack {
            case .openAIRealtime:
                try await socket?.sendJSON(Self.toolResultMessage(stack: stack, result: result, call: call))
                turn.toolsInFlight -= 1
                guard requestingReply else { return ignoreStale("toolResult", arrivalUptime: uptime, in: turn) }
                // One follow-up for all the calls of a response, once that response is over.
                guard turn.toolsInFlight == 0 else { return }
                let waitDeadline = uptime + 5
                while openAIResponseActive, uptime < waitDeadline { try await Task.sleep(for: .milliseconds(20)) }
                // A press during the wait cancels the answer that held it, which ends
                // the loop: a create now would still be live at the new turn's release.
                guard self.turn === turn, !turn.supersededByPress else { return ignoreStale("toolResult", arrivalUptime: uptime, in: turn) }
                turn.toolResultSentUptime = uptime
                turn.followUpFirstAudioUptime = nil
                try await sendResponseCreate(for: turn)
            case .geminiLive, .frontAndWorker:
                turn.toolsInFlight -= 1
                guard requestingReply else { return ignoreStale("toolResult", arrivalUptime: uptime, in: turn) }
                turn.toolResultSentUptime = uptime
                turn.followUpFirstAudioUptime = nil
                try await socket?.sendJSON(Self.toolResultMessage(stack: stack, result: result, call: call))
            case .cascade:
                cascade?.add(toolResult: Self.toolResultMessage(stack: stack, result: result, call: call))
                turn.toolsInFlight -= 1
                guard requestingReply, self.turn === turn, !turn.supersededByPress else { return ignoreStale("toolResult", arrivalUptime: uptime, in: turn) }
                // One follow-up for all the calls of a message.
                guard turn.toolsInFlight == 0 else { return }
                turn.toolResultSentUptime = uptime
                turn.followUpFirstAudioUptime = nil
                cascade?.continueAfterTools(marks: turn)
            }
        } catch {
            turn.finished.settle(.failure(VoiceBenchFailure(kind: "\(stack.rawValue):toolResultSendFailed")))
        }
    }
}

/// One call's card hand-off (`send`), or a waiter's "the call before me finished".
@MainActor private final class CardHandOff {
    var send: Task<Void, Never>?
    var previousFinished = false
}

/// The hit test's rung, written from inside `resolveScreenTarget`'s closure.
@MainActor private final class RungBox {
    var value: String?
}
