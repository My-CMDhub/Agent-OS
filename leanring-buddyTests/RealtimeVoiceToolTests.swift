//
//  RealtimeVoiceToolTests.swift
//  leanring-buddyTests
//
//  Pure logic behind `open_app`: each provider's tool-call event -> the harness
//  request line, the harness response -> what the model is told, the ticket
//  re-issue loop, the honesty heuristic and the picker's stored value. Whether
//  the models actually CALL the tool is proven by `--voice-tool-probe`, not here.
//

import CoreGraphics
import Foundation
import ImageIO
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

    /// 72985B9B's miss: "Done. It's in front of you now." never said "open".
    @Test func anyCompletionClaimWithoutAnOkResultIsFlagged() {
        let claim = RealtimeOpenAppTool.claimedSuccessWithoutReceipt
        #expect(claim("Done. It\u{2019}s in front of you now.", false))
        #expect(claim("Done, I opened System Settings.", false))
        #expect(claim("System Settings is UP AND RUNNING, sir.", false))
        #expect(claim("Here it is.", false))
        #expect(claim("Launched, as requested.", false))
        #expect(claim("sure, i'll open system settings", false))
        #expect(!claim("Done, I opened System Settings.", true))
        #expect(!claim("It didn't open; nothing called Figma is installed.", false))
        #expect(!claim("That's not ready yet, the card needs your click.", false))
        // Whole words only: "reopening" and "abandoned" carry no claim.
        #expect(!claim("reopening is abandoned", false))
        #expect(!claim("", false))
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

    // MARK: Fresh look

    @Test func lookIsTheHarnessWindowRungPinnedToTheLaunchedApp() throws {
        let line = try #require(RealtimeOpenAppTool.lookRequestLine(expectApp: "com.apple.systempreferences"))
        #expect(line == #"{"expectApp":"com.apple.systempreferences","tier":"window","verb":"look"}"#)
    }

    @Test func refusedLookIsAnOutcomeAndNeverReadsTheImage() {
        let refused: [String: Any] = ["ok": false, "error": "kernelRefused", "imagePath": "/never/read.jpg"]
        var imageReads = 0
        let look = RealtimeOpenAppTool.freshLook(fromLookResponse: refused) { _ in imageReads += 1; return Data() }
        #expect(imageReads == 0)
        #expect(look.outcome == "kernelRefused")
        #expect(RealtimeOpenAppTool.freshLook(fromLookResponse: [:]) { _ in nil }.outcome == "unreadableHarnessResponse")
        #expect(RealtimeOpenAppTool.freshLook(fromLookResponse: ["ok": true, "imagePath": "/x.jpg"]) { _ in nil }.outcome == "imageUnreadable")
        #expect(RealtimeOpenAppTool.freshLook(fromLookResponse: ["ok": true, "imagePath": "/x.jpg"]) { _ in Data("not a jpeg".utf8) }.outcome == "imageDownscaleFailed")
    }

    @Test func attachedLookIsDownscaled() throws {
        // A 2000x1000 image in, long edge 1024 out.
        let context = try #require(CGContext(data: nil, width: 2000, height: 1000, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let encoded = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(encoded, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
        let big = encoded as Data
        let look = RealtimeOpenAppTool.freshLook(fromLookResponse: ["ok": true, "imagePath": "/x.jpg"]) { _ in big }
        guard case .image(let jpeg) = look else { Issue.record("expected an image, got \(look.outcome)"); return }
        let source = try #require(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == 1024)
        #expect(properties[kCGImagePropertyPixelHeight] as? Int == 512)
    }

    /// The result no longer waits for the look, so the prompt must not name a
    /// field the result stopped carrying.
    @MainActor @Test func promptNamesNoFieldTheResultDoesNotCarry() {
        #expect(!RealtimeOpenAppTool.systemPrompt.contains("freshView"))
    }

    /// Spec §3.1 minus the bin example, plus the two menu examples of slice 4:
    /// seven replies, none about a verb the model has no tool for.
    @MainActor @Test func exampleRepliesAreReadFromThePrompt() {
        let replies = RealtimeOpenAppTool.exampleReplies
        #expect(replies.count == 7)
        #expect(replies.first == "there it is, calendar.")
        #expect(RealtimeOpenAppTool.examples.map(\.appName) == ["calendar", "figma", "terminal", nil, nil, nil, nil])
        #expect(RealtimeOpenAppTool.systemPrompt.contains("do not reuse the wording of these examples; vary it."))
        #expect(RealtimeOpenAppTool.systemPrompt.contains("report only the verified outcome, briefly; do not describe the new screen until you have been given a view of it."))
    }

    /// No example is another's template, so the model has no single shape to copy
    /// (2B1985A5: "<app> is up, sir." 2/10); "sir" at most once and not in all.
    @MainActor @Test func examplesShareNoTemplateAndSirIsNotASuffix() {
        let examples = RealtimeOpenAppTool.examples
        for example in examples {
            let others = examples.filter { $0 != example }.map(\.reply)
            #expect(!others.contains { RealtimeOpenAppTool.normalisedAnswer($0) == RealtimeOpenAppTool.normalisedAnswer(example.reply) })
            let sirCount = RealtimeOpenAppTool.normalisedAnswer(example.reply).split(separator: " ").filter { $0 == "sir" }.count
            #expect(sirCount <= 1)
        }
        let withSir = examples.filter { RealtimeOpenAppTool.normalisedAnswer($0.reply).split(separator: " ").contains("sir") }
        #expect(withSir.count < examples.count)
        #expect(!examples.contains { RealtimeOpenAppTool.normalisedAnswer($0.reply).hasSuffix(" sir") })
        #expect(Set(examples.map { RealtimeOpenAppTool.normalisedAnswer($0.reply).split(separator: " ").first }).count == examples.count)
        #expect(!RealtimeOpenAppTool.systemPrompt.contains("empty the bin"))
    }

    /// The notch's names come from the model's argument, so one that needs
    /// escaping is shown quoted and escaped, never raw.
    @MainActor @Test func notchNamesAreSanitisedAndProofComesFromTheHarnessAnswer() {
        #expect(RealtimeOpenAppTool.captionName("System Settings") == "System Settings")
        #expect(RealtimeOpenAppTool.captionName("Notes\nDone, sir") == "\"Notes\\nDone, sir\"")
        #expect(RealtimeOpenAppTool.captionName(String(repeating: "a", count: 150)).hasSuffix("(150 chars)"))

        let call = RealtimeToolCall(callID: "c", name: "open_app", appName: "settings")
        let ready = RealtimeToolDispatch(result: ["ok": true], harnessMilliseconds: 1, waitedForConfirmation: false,
                                         harnessResponse: ["ok": true, "application": "System Settings"])
        #expect(RealtimeOpenAppTool.notchAnswer(for: call, dispatch: ready) == .harnessAnswered(ok: true, subject: "System Settings", error: nil))
        let failed = RealtimeToolDispatch(result: ["ok": false, "error": "notFound"], harnessMilliseconds: 1,
                                          waitedForConfirmation: false, harnessResponse: ["ok": false, "error": "notFound"])
        #expect(RealtimeOpenAppTool.notchAnswer(for: call, dispatch: failed) == .harnessAnswered(ok: false, subject: "settings", error: "notFound"))
    }

    /// `highlight` stays a harness verb after the voice flow stopped using it.
    @MainActor @Test func highlightStillAimsAtAWindowTarget() throws {
        let line = #"{"expectApp":"com.apple.systempreferences","label":"x","target":"window","verb":"highlight"}"#
        guard case .success(let request) = HarnessPolicy.decode(line: line) else { Issue.record("highlight line did not decode"); return }
        #expect(request.verb == .highlight)
        #expect(request.aimAtWindow)
        #expect(request.expectApp == "com.apple.systempreferences")
    }

    /// The window target outlines; it never aims an acting verb.
    @MainActor @Test func windowTargetIsHighlightOnly() {
        guard case .failure = HarnessPolicy.decode(line: #"{"verb":"press","target":"window"}"#) else {
            Issue.record("press accepted target window"); return
        }
        guard case .failure = HarnessPolicy.decode(line: #"{"verb":"type","text":"x","target":"window"}"#) else {
            Issue.record("type accepted target window"); return
        }
    }

    @Test func aTicketTellsTheNotchBeforeTheWait() async {
        final class Flags: @unchecked Sendable { var count = 0; var confirmationSeenAt = -1 }
        let flags = Flags()
        let call = RealtimeToolCall(callID: "c", name: "open_app", appName: "Terminal")
        let dispatch = await RealtimeOpenAppTool.dispatch(call, answer: { _ in
            flags.count += 1
            return flags.count == 1 ? #"{"ok":false,"error":"confirmationRequired","ticket":"T"}"# : #"{"ok":true,"status":"ready"}"#
        }, pollMilliseconds: 1, onConfirmationRequired: { flags.confirmationSeenAt = flags.count })
        #expect(flags.confirmationSeenAt == 1)
        #expect(dispatch.harnessConfirmed)
        #expect(dispatch.answeredUptime != nil)
    }

    @MainActor @Test func verbatimReuseIgnoresCasePunctuationAndSpacing() {
        #expect(RealtimeOpenAppTool.reusesExampleVerbatim("There it is, Calendar."))
        #expect(RealtimeOpenAppTool.reusesExampleVerbatim("  there IT is  calendar "))
        #expect(RealtimeOpenAppTool.reusesExampleVerbatim("That didn\u{2019}t take; nothing called Figma is installed."))
        #expect(!RealtimeOpenAppTool.reusesExampleVerbatim("There it is, System Settings."))
        #expect(!RealtimeOpenAppTool.reusesExampleVerbatim(""))
        #expect(RealtimeOpenAppTool.normalisedAnswer("Done, sir.") == RealtimeOpenAppTool.normalisedAnswer("done sir"))
    }

    /// The app swapped for another is still the example; a different sentence is not.
    @MainActor @Test func templateReuseSwapsTheAppNameOnly() {
        #expect(RealtimeOpenAppTool.reusesExampleTemplate("There it is, System Settings."))
        #expect(RealtimeOpenAppTool.reusesExampleTemplate("There it is, System Settings is open."))
        #expect(!RealtimeOpenAppTool.reusesExampleTemplate("There it is."))
        #expect(RealtimeOpenAppTool.reusesExampleTemplate("That didn't take; nothing called System Settings is installed."))
        #expect(RealtimeOpenAppTool.reusesExampleTemplate("Terminal can run anything, sir, so the card on screen needs your click first."))
        #expect(RealtimeOpenAppTool.reusesExampleTemplate("Notes can run anything, sir, so the card on screen needs your click first."))
        #expect(!RealtimeOpenAppTool.reusesExampleTemplate("That didn't take."))
        #expect(!RealtimeOpenAppTool.reusesExampleTemplate("That didn't take; nothing called System Settings is installed, sadly."))
        #expect(!RealtimeOpenAppTool.reusesExampleTemplate("That didn't take; nothing called a very long app name here is installed."))
        #expect(!RealtimeOpenAppTool.reusesExampleTemplate("System Settings is up, sir."))
        #expect(!RealtimeOpenAppTool.reusesExampleTemplate("Downloads, in Notes, twelve files. Looking for one in particular?"))
        #expect(!RealtimeOpenAppTool.reusesExampleTemplate(""))
    }

    /// The live persona is its own prompt; the bench's control must not drift with it.
    @MainActor @Test func livePersonaIsJarvisAndLeavesTheBenchPromptAlone() {
        let prompt = RealtimeOpenAppTool.systemPrompt
        #expect(prompt.hasPrefix("you are J.A.R.V.I.S."))
        #expect(prompt.contains("\"sir\""))
        #expect(prompt.contains("never say something happened unless its tool result says ok true"))
        #expect(!prompt.contains("clicky"))
        #expect(!prompt.contains("POINT"))
        #expect(VoiceStackBenchmark.speechToSpeechSystemPrompt.hasPrefix("you're clicky"))
        #expect(VoiceStackBenchmark.openAIRealtimeVoice == "marin")
    }

    @MainActor @Test func freshLookArrivalIsMeasuredFromTheSpokenResult() {
        let marks = RealtimeTurnMarks()
        #expect(marks.freshLookArrivedAfterSpeechStartMs == nil)
        marks.followUpFirstAudioUptime = 100.0
        marks.freshLookCompletedUptime = 100.25
        #expect(marks.freshLookArrivedAfterSpeechStartMs == 250)
        marks.freshLookCompletedUptime = 99.9
        #expect(marks.freshLookArrivedAfterSpeechStartMs == -100)
    }

    // MARK: Live turn line

    @Test func failedLiveTurnStillWritesEveryKeyAndNoWords() throws {
        var line = RealtimeLiveTurnLine(stack: "geminiLive", turnID: "T1", sessionWasWarm: false)
        line.sessionSetupMs = 1_900
        line.holdMs = 1_200
        line.errorKind = "geminiLive:setupTimeout"
        let jsonLine = try #require(MeasurementLogFile.jsonLine(line.jsonObject))
        let parsed = object(jsonLine)
        #expect(parsed["errorKind"] as? String == "geminiLive:setupTimeout")
        #expect(parsed["sessionWasWarm"] as? Bool == false)
        #expect(parsed["sessionSetupMs"] as? Int == 1_900)
        #expect(parsed["toolCalled"] as? Bool == false)
        #expect(parsed["bargedIn"] as? Bool == false)
        #expect(parsed["firstAudioMs"] is NSNull)
        #expect(parsed["freshLookMs"] is NSNull)
        #expect(Set(parsed.keys) == [
            "kind", "stack", "turnId", "sessionWasWarm", "sessionSetupMs", "holdMs", "firstAudioMs", "toolCalled",
            "toolName", "toolCallMs", "harnessMs", "harnessStatus", "harnessError", "freshLook", "freshLookMs", "freshLookArrivedAfterSpeechStartMs",
            "followUpFirstAudioMs", "releaseToSpokenResultMs", "turnDoneMs", "bargedIn", "errorKind", "notchTransitions"
        ])
    }
}
