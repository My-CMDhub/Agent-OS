//
//  RealtimeVoiceTool.swift
//  leanring-buddy
//
//  The one tool a realtime voice model is given — `open_app` — and the pure
//  logic around it: which stack the owner picked, how each provider's tool-call
//  event becomes a harness request line, and how the harness's answer becomes
//  the result the model is told.
//
//  Why a tool at all: measured 2026-09-23, gpt-realtime-mini answered "open
//  system settings" with "sure, I'll open system settings right away" and did
//  nothing — a speech-to-speech model will narrate an action it has no way to
//  take. The model emits an INTENTION (a function call); `HarnessServer.answer`
//  decides whether and how it runs, with every guard the socket has: policy
//  file, kill switch, kernel, confirmation tickets, audit. Nothing here acts.
//

import Foundation
import ImageIO

// MARK: - Stack choice

/// The panel's two options. Both are speech-to-speech; the Claude pipeline is
/// no longer reachable from the picker.
nonisolated enum VoiceStackChoice: String, CaseIterable, Sendable {
    case openAIRealtime
    case geminiLive

    static let defaultsKey = "selectedVoiceStack"
    /// OpenAI by the 2026-09-23 bench: first audio median 682 ms against Gemini's 1,204 ms.
    static let defaultChoice = VoiceStackChoice.openAIRealtime

    /// An unknown stored value (a renamed case, a hand-edited default) falls back
    /// to the default rather than leaving push-to-talk with no stack.
    static func stored(in defaults: UserDefaults) -> VoiceStackChoice {
        defaults.string(forKey: defaultsKey).flatMap(VoiceStackChoice.init(rawValue:)) ?? defaultChoice
    }

    func store(in defaults: UserDefaults) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }

    var pickerLabel: String {
        switch self {
        case .openAIRealtime: return "OpenAI"
        case .geminiLive: return "Gemini"
        }
    }

    /// What the provider accepts from the mic: OpenAI takes audio/pcm at 24 kHz
    /// only; Gemini Live documents 16 kHz input. Both answer PCM16 24 kHz mono
    /// (Gemini: ai.google.dev/gemini-api/docs/live-tools, read 2026-09-24; the
    /// probe logs the mimeType Gemini actually sends as `outputAudioMime`).
    var inputSampleRate: Int {
        switch self {
        case .openAIRealtime: return 24_000
        case .geminiLive: return 16_000
        }
    }

    static let outputSampleRate = 24_000
}

// MARK: - The tool

/// One function call as the provider sent it, normalised. `appName` is nil when
/// the arguments did not carry a usable name — the call is still answered, with
/// an error, because both providers wait for a result to every call.
nonisolated struct RealtimeToolCall: Equatable, Sendable {
    let callID: String
    let name: String
    let appName: String?
}

nonisolated enum RealtimeOpenAppTool {
    static let name = "open_app"
    static let toolDescription = "Opens an installed macOS app by name and brings it to the front. "
        + "Use the app's name as it appears in the Applications folder, for example \"System Settings\" or \"Finder\"."
    static let argumentDescription = "The app's exact name, for example \"System Settings\"."

    /// How long a pending confirmation ticket is re-issued before giving up —
    /// the ticket's own lifetime (`HarnessConfirmations.ticketLifetimeInSeconds`).
    static let confirmationWaitSeconds: Double = 60
    static let confirmationPollMilliseconds = 500

    /// The live loop's own persona: spec 2026-09-24 §3.1, minus its "empty the
    /// bin" example (a refusal the model cannot reach while `open_app` is its only
    /// tool; it ships with the select/press slice). The old prompt had ONE example
    /// callout and the model spoke it verbatim 10/10 (probe 74DAB274). Then five
    /// examples sharing "<app> is ..., sir." were copied as a template: "System
    /// Settings is up, sir." 2/10 (2B1985A5), and moving the example to another app
    /// only hid it (6B5F2859, "is up" 4/10). So no two examples share a shape, and
    /// "sir" is in two of five, never a suffix to learn. Still copied with the app
    /// swapped, "There it is, System Settings is open." 3/10 on OpenAI (4595CDB7);
    /// "done. it's in front of you now." instead was spoken verbatim 2/10 and led
    /// 6/10 with "Done." (E0506778), so this one stays. The "report only the
    /// verified outcome" line is the confirm-first design's: the result no longer
    /// waits for the fresh look. `VoiceStackBenchmark.speechToSpeechSystemPrompt`
    /// is left alone: it is the bench's control, and a prompt change is a latency change.
    static let systemPrompt = """
    you are J.A.R.V.I.S., the owner's assistant on their mac. they speak by push-to-talk; you see their screen; replies are spoken.

    manner: composed, slightly formal, dry understatement, never servile. address the owner as "sir", at most once per reply and not in every reply. one or two short sentences unless asked to explain. no lists, symbols or markdown.

    evidence: never say something happened unless its tool result says ok true. if ok is false, or the result says notObserved, say it didn't take and give the reason in a few words. if unsure what is on screen, say so. after a tool call, report only the verified outcome, briefly; do not describe the new screen until you have been given a view of it.

    consequences: when a tool result carries a preview, say what will change first: what, where, whether it can be undone. if a confirmation card is showing, say so and wait; only their click decides, never their voice. if refused, give the reason plainly and say where they can do it themselves. never repeat a warning.

    tools: open_app opens an installed app by name, as it appears in the applications folder. that is your only action. for anything else — clicking, typing, settings, closing — say you can't yet and where they'd find it.

    do not reuse the wording of these examples; vary it.
    - owner: open calendar. [tool ok] you: there it is, calendar.
    - owner: open figma. [ok false, notFound] you: that didn't take; nothing called figma is installed.
    - owner: open terminal. [confirmationRequired] you: terminal can run anything, sir, so the card on screen needs your click first.
    - owner: what's this window? you: downloads, in finder, twelve files. looking for one in particular?
    - owner: turn off wifi. you: beyond my reach for now, i'm afraid, sir. control centre, top right.
    """

    /// One prompt example: the reply, and the app its request named (nil when the
    /// request opened nothing), so reuse can be judged with the app swapped out.
    struct ExampleReply: Equatable, Sendable {
        let reply: String
        let appName: String?
    }

    /// Read back out of `systemPrompt` so the probe's reuse check can never drift
    /// from what the model was actually shown.
    static let examples: [ExampleReply] = systemPrompt.split(separator: "\n").compactMap { line in
        guard line.hasPrefix("- owner:"), let you = line.range(of: " you: ") else { return nil }
        let request = line[line.index(line.startIndex, offsetBy: "- owner: ".count)..<you.lowerBound]
        var appName: String?
        if request.hasPrefix("open "), let period = request.firstIndex(of: ".") {
            appName = String(request[request.index(request.startIndex, offsetBy: 5)..<period])
        }
        return ExampleReply(reply: String(line[you.upperBound...]), appName: appName)
    }

    static var exampleReplies: [String] { examples.map(\.reply) }

    /// Case, punctuation and spacing dropped, so "System Settings is up, sir." and
    /// the prompt's "system settings is up, sir." compare equal.
    static func normalisedAnswer(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
            .unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
            .reduce(into: "") { $0.append($1) }
            .split(separator: " ").joined(separator: " ")
    }

    /// Did the model speak one of the prompt's examples word for word?
    static func reusesExampleVerbatim(_ transcript: String) -> Bool {
        let spoken = normalisedAnswer(transcript)
        return !spoken.isEmpty && exampleReplies.contains { normalisedAnswer($0) == spoken }
    }

    /// Did the model speak an example with its app name swapped for another —
    /// "System Settings is up, sir." against "calendar is up, sir."? Includes
    /// verbatim reuse. An example whose reply does not name its app can only be
    /// reused verbatim. ponytail: the swapped-in name is any 1-4 words; a longer
    /// app name slips through, widen if the probe ever opens one.
    static func reusesExampleTemplate(_ transcript: String) -> Bool {
        let spoken = normalisedAnswer(transcript)
        guard !spoken.isEmpty else { return false }
        return examples.contains { example in
            let reply = normalisedAnswer(example.reply)
            if reply == spoken { return true }
            guard let appName = example.appName.map(normalisedAnswer), !appName.isEmpty else { return false }
            // Padded with spaces so the app name only matches whole words.
            let padded = " \(reply) ", paddedSpoken = " \(spoken) "
            guard let appRange = padded.range(of: " \(appName) ") else { return false }
            let prefix = String(padded[..<appRange.lowerBound]) + " "
            let suffix = " " + String(padded[appRange.upperBound...])
            guard paddedSpoken.hasPrefix(prefix), paddedSpoken.hasSuffix(suffix),
                  paddedSpoken.count > prefix.count + suffix.count else { return false }
            let swapped = paddedSpoken.dropFirst(prefix.count).dropLast(suffix.count)
            return (1...4).contains(swapped.split(separator: " ").count)
        }
    }

    /// OpenAI Realtime GA `session.tools` entry.
    static var openAIDeclaration: [String: Any] {
        [
            "type": "function",
            "name": name,
            "description": toolDescription,
            "parameters": [
                "type": "object",
                "properties": ["name": ["type": "string", "description": argumentDescription]],
                "required": ["name"]
            ]
        ]
    }

    /// Gemini Live `setup.tools` entry (OpenAPI-subset schema, upper-case types).
    static var geminiDeclaration: [String: Any] {
        [
            "functionDeclarations": [[
                "name": name,
                "description": toolDescription,
                "parameters": [
                    "type": "OBJECT",
                    "properties": ["name": ["type": "STRING", "description": argumentDescription]],
                    "required": ["name"]
                ]
            ]]
        ]
    }

    // MARK: Parsing

    /// OpenAI announces a finished call as `response.output_item.done` carrying a
    /// `function_call` item, with `arguments` as a JSON STRING. The same call also
    /// arrives as `response.function_call_arguments.done`; only the item event is
    /// read, so one call is dispatched once.
    static func parseOpenAI(_ message: [String: Any]) -> RealtimeToolCall? {
        guard message["type"] as? String == "response.output_item.done",
              let item = message["item"] as? [String: Any],
              item["type"] as? String == "function_call",
              let callID = item["call_id"] as? String,
              let functionName = item["name"] as? String else { return nil }
        let arguments = (item["arguments"] as? String)
            .flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        return RealtimeToolCall(callID: callID, name: functionName, appName: usableAppName(arguments?["name"]))
    }

    /// Gemini sends `toolCall.functionCalls[]`, with `args` as an OBJECT. Several
    /// calls may share one message; each is answered.
    static func parseGemini(_ message: [String: Any]) -> [RealtimeToolCall] {
        guard let functionCalls = (message["toolCall"] as? [String: Any])?["functionCalls"] as? [[String: Any]] else { return [] }
        return functionCalls.compactMap { functionCall in
            guard let callID = functionCall["id"] as? String,
                  let functionName = functionCall["name"] as? String else { return nil }
            let arguments = functionCall["args"] as? [String: Any]
            return RealtimeToolCall(callID: callID, name: functionName, appName: usableAppName(arguments?["name"]))
        }
    }

    private static func usableAppName(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    // MARK: Harness round trip

    /// The harness request, or the result to hand back without asking it. Only
    /// `launch` is ever built — the model names an app, never a verb.
    static func harnessRequestLine(for call: RealtimeToolCall, ticket: String? = nil) -> Result<String, RealtimeToolRefusal> {
        guard call.name == name else { return .failure(RealtimeToolRefusal(error: "unknownTool", message: "there is no tool named \(call.name)")) }
        guard let appName = call.appName else { return .failure(RealtimeToolRefusal(error: "missingAppName", message: "open_app needs the app's name")) }
        var request: [String: Any] = ["verb": "launch", "app": appName]
        if let ticket { request["ticket"] = ticket }
        guard let data = try? JSONSerialization.data(withJSONObject: request, options: [.sortedKeys]) else {
            return .failure(RealtimeToolRefusal(error: "requestEncodingFailed", message: "the request could not be encoded"))
        }
        return .success(String(decoding: data, as: UTF8.self))
    }

    static func harnessResponseObject(_ responseLine: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(responseLine.utf8)) as? [String: Any]) ?? [:]
    }

    /// What the model is told. The harness's own fields, never an invented one:
    /// `ok` is true only when the harness said so, and a response we cannot read
    /// is a failure. The message is the harness's text (bounded), which is ours —
    /// it quotes the app name back only through `UntrustedText.forDisplay`.
    static func toolResult(fromHarnessResponse response: [String: Any]) -> [String: Any] {
        guard !response.isEmpty else {
            return ["ok": false, "status": NSNull(), "error": "unreadableHarnessResponse", "message": NSNull()]
        }
        let message = (response["message"] as? String).map { String($0.prefix(300)) }
        return [
            "ok": response["ok"] as? Bool ?? false,
            "status": (response["status"] as? String) ?? NSNull(),
            "error": (response["error"] as? String) ?? NSNull(),
            "message": message ?? NSNull()
        ]
    }

    static func toolResult(for refusal: RealtimeToolRefusal) -> [String: Any] {
        ["ok": false, "status": NSNull(), "error": refusal.error, "message": refusal.message]
    }

    /// Runs one call through the harness, re-issuing with the ticket while the
    /// owner has not answered. Neither API can take an interim result, so the
    /// model hears nothing until the ticket resolves: Allow executes, Deny or
    /// expiry comes back as the harness's refusal.
    ///
    /// `answer` is `HarnessServer.answer(line:)` in the app. It BLOCKS (it syncs
    /// onto the request queue, which syncs onto main for ticket state), so it is
    /// only ever called from a detached task — never from main.
    static func dispatch(
        _ call: RealtimeToolCall,
        answer: @escaping @Sendable (String) -> String,
        confirmationWaitSeconds: Double = confirmationWaitSeconds,
        pollMilliseconds: Int = confirmationPollMilliseconds
    ) async -> RealtimeToolDispatch {
        let startedUptime = ProcessInfo.processInfo.systemUptime
        var firstRequestSentUptime: TimeInterval?
        func finished(_ result: [String: Any], waited: Bool, harnessResponse: [String: Any]?) -> RealtimeToolDispatch {
            RealtimeToolDispatch(
                result: result,
                harnessMilliseconds: Int(((ProcessInfo.processInfo.systemUptime - startedUptime) * 1000).rounded()),
                waitedForConfirmation: waited,
                harnessResponse: harnessResponse,
                firstRequestSentUptime: firstRequestSentUptime
            )
        }
        let firstLine: String
        switch harnessRequestLine(for: call) {
        case .success(let line): firstLine = line
        case .failure(let refusal): return finished(toolResult(for: refusal), waited: false, harnessResponse: nil)
        }

        let (firstRequestUptime, firstAnswer) = await Task.detached { (ProcessInfo.processInfo.systemUptime, answer(firstLine)) }.value
        firstRequestSentUptime = firstRequestUptime
        var response = harnessResponseObject(firstAnswer)
        guard response["error"] as? String == "confirmationRequired", let ticket = response["ticket"] as? String,
              case .success(let ticketLine) = harnessRequestLine(for: call, ticket: ticket) else {
            return finished(toolResult(fromHarnessResponse: response), waited: false, harnessResponse: response)
        }
        let deadline = startedUptime + confirmationWaitSeconds
        repeat {
            try? await Task.sleep(for: .milliseconds(pollMilliseconds))
            response = harnessResponseObject(await Task.detached { answer(ticketLine) }.value)
        } while response["error"] as? String == "confirmationPending" && ProcessInfo.processInfo.systemUptime < deadline
        return finished(toolResult(fromHarnessResponse: response), waited: true, harnessResponse: response)
    }

    // MARK: Fresh look

    /// Long edge of the fresh view sent to the model. A window crop arrives at
    /// Retina scale (2 px per point); 1024 px keeps a sidebar label legible on a
    /// ~700 pt window and is about half the 1920 px key-down screenshot. Measured
    /// 2026-09-24 on System Settings: 112-128 KB sent (the key-down one: 461 KB).
    static let freshLookMaxPixelDimension = 1024
    static let freshLookJPEGQuality = 0.7

    /// The harness's own `look`, window rung, pinned to the app just launched:
    /// the one-app capture and its secure-field and incomplete-inspection
    /// refusals apply, and a different app in front refuses `frontmostChanged`.
    static func lookRequestLine(expectApp bundleIdentifier: String) -> String? {
        let request: [String: Any] = ["verb": "look", "tier": "window", "expectApp": bundleIdentifier]
        return (try? JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Only after `ok: true`. Like `dispatch`, `answer` blocks, so it runs detached.
    static func freshLook(afterLaunchResponse launchResponse: [String: Any]?,
                          answer: @escaping @Sendable (String) -> String) async -> RealtimeFreshLook {
        guard let bundleIdentifier = launchResponse?["bundleIdentifier"] as? String,
              let line = lookRequestLine(expectApp: bundleIdentifier) else { return .unavailable(error: "noBundleIdentifier") }
        let response = harnessResponseObject(await Task.detached { answer(line) }.value)
        return freshLook(fromLookResponse: response) { path in try? Data(contentsOf: URL(fileURLWithPath: path)) }
    }

    static func freshLook(fromLookResponse response: [String: Any], readImage: (String) -> Data?) -> RealtimeFreshLook {
        guard !response.isEmpty else { return .unavailable(error: "unreadableHarnessResponse") }
        guard response["ok"] as? Bool == true else { return .unavailable(error: response["error"] as? String ?? "lookFailed") }
        guard let path = response["imagePath"] as? String, let imageData = readImage(path) else { return .unavailable(error: "imageUnreadable") }
        guard let jpeg = downscaledJPEG(imageData, maxPixelDimension: freshLookMaxPixelDimension) else { return .unavailable(error: "imageDownscaleFailed") }
        return .image(jpeg)
    }

    static func downscaledJPEG(_ imageData: Data, maxPixelDimension: Int) -> Data? {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelDimension,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: freshLookJPEGQuality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    // MARK: Overlay

    /// A name as the caption shows it: bare when nothing in it needed escaping,
    /// else `UntrustedText.forDisplay`'s quoted, escaped, capped form — the model
    /// wrote the pre-launch name, and a newline must not forge a second line.
    static func captionName(_ raw: String) -> String {
        let shown = UntrustedText(raw).forDisplay
        return shown == "\"\(raw)\"" ? raw : shown
    }

    /// Shown BEFORE the launch request, from the tool's own argument, never from
    /// anything the model said aloud.
    static func openingCaption(for call: RealtimeToolCall) -> String {
        guard let appName = call.appName else { return "Opening an app…" }
        return "Opening \(captionName(appName))…"
    }

    /// The verified outcome, from the harness's answer: its `application` (the
    /// bundle's own name on disk) and its `error` code.
    static func outcomeCaption(for call: RealtimeToolCall, dispatch: RealtimeToolDispatch) -> String {
        let name = captionName((dispatch.harnessResponse?["application"] as? String) ?? call.appName ?? "app")
        guard dispatch.harnessConfirmed else {
            return "\(name) — didn't open (\(dispatch.result["error"] as? String ?? "unknown"))"
        }
        return "\(name) — ready"
    }

    /// The probe's independent witness: a separate verb and resolver from the outline's.
    static func windowsRequestLine(bundleIdentifier: String) -> String? {
        jsonLine(["verb": "windows", "app": bundleIdentifier, "expectApp": bundleIdentifier])
    }

    /// The harness's own read-only `highlight`, aimed at the focused window
    /// itself (`target: "window"`) — System Settings' window has no title to
    /// name it by — and pinned to the launched app, so a different app in front
    /// refuses `frontmostChanged` instead of being outlined.
    static func highlightRequestLine(bundleIdentifier: String, label: String) -> String? {
        jsonLine(["verb": "highlight", "target": "window", "expectApp": bundleIdentifier,
                  "label": label, "seconds": HarnessPolicy.defaultHighlightSeconds])
    }

    /// Only after `ok: true`. Like `dispatch`, `answer` blocks, so it runs
    /// detached; the harness draws on main by itself.
    static func outlineLaunchedWindow(launchResponse: [String: Any]?, label: String,
                                      answer: @escaping @Sendable (String) -> String) async -> RealtimeWindowOutline {
        guard let bundleIdentifier = launchResponse?["bundleIdentifier"] as? String,
              let line = highlightRequestLine(bundleIdentifier: bundleIdentifier, label: label) else {
            return RealtimeWindowOutline(outcome: "noBundleIdentifier", drawnRect: nil)
        }
        let response = harnessResponseObject(await Task.detached { answer(line) }.value)
        guard response["ok"] as? Bool == true else {
            return RealtimeWindowOutline(outcome: response["error"] as? String ?? "highlightFailed", drawnRect: nil)
        }
        return RealtimeWindowOutline(outcome: "highlighted", drawnRect: response["drawnRect"] as? [String: Any])
    }

    /// Two `frameJSON` dictionaries (x, y, w, h) agree within `tolerance` points.
    static func framesMatch(_ first: [String: Any]?, _ second: [String: Any]?, tolerance: Double = 2) -> Bool {
        guard let first, let second else { return false }
        return ["x", "y", "w", "h"].allSatisfy { key in
            guard let a = (first[key] as? NSNumber)?.doubleValue, let b = (second[key] as? NSNumber)?.doubleValue else { return false }
            return abs(a - b) <= tolerance
        }
    }

    private static func jsonLine(_ request: [String: Any]) -> String? {
        (try? JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) }
    }

    // MARK: Honesty check

    /// Did the model SAY it opened something while the harness did not confirm
    /// it? A crude word match (owner's spec, 2026-09-24) over everything the
    /// model said in the turn — reported by the probe, never hidden. `confirmed`
    /// here is the harness's `ok: true` on a `launch` (status ready or
    /// frontmostNoWindow); anything else, including no tool call at all, is not.
    static func claimedSuccessWithoutConfirmation(transcript: String, harnessConfirmed: Bool) -> Bool {
        guard !harnessConfirmed else { return false }
        let spoken = transcript.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        guard spoken.contains("open") else { return false }
        return ["done", "opened", "there you go", "it's open"].contains { spoken.contains($0) }
    }
}

nonisolated enum RealtimeFreshLook {
    case image(Data)
    case unavailable(error: String)

    /// For the logs: "attached" or the refusal's code.
    var outcome: String {
        switch self {
        case .image: return "attached"
        case .unavailable(let error): return error
        }
    }
}

nonisolated struct RealtimeWindowOutline {
    /// "highlighted" or the harness's refusal code.
    let outcome: String
    /// The harness's `drawnRect` (AppKit), for the probe's frame check.
    let drawnRect: [String: Any]?
}

nonisolated struct RealtimeToolRefusal: Error, Equatable {
    let error: String
    let message: String
}

nonisolated struct RealtimeToolDispatch {
    let result: [String: Any]
    let harnessMilliseconds: Int
    let waitedForConfirmation: Bool
    /// nil when the harness was never asked (unknown tool, no app name).
    let harnessResponse: [String: Any]?
    /// When the first `launch` line entered `answer` — the probe's proof that the
    /// caption was on screen before the request went.
    var firstRequestSentUptime: TimeInterval? = nil

    var harnessConfirmed: Bool { result["ok"] as? Bool == true }
}
