//
//  RealtimeHeardCheck.swift
//  leanring-buddy
//
//  The heard-vs-named check: before any app-targeted voice tool runs, the app
//  the TOOL names is compared with the app(s) the OWNER'S WORDS name.
//
//  Why: probe D66FC598 (2026-09-25), "open a new window in cursor" — OpenAI's
//  realtime model called press_menu with app "Visual Studio Code" 9 times. The
//  app check compared that named app with the frontmost app, both VS Code, so
//  it passed and the press landed in the wrong app. Both sides of that check
//  came from the model's own (mis)hearing. The owner's words are a third,
//  independent witness: each provider runs a SEPARATE transcription model on
//  the same input audio (OpenAI `audio.input.transcription`, Gemini
//  `inputAudioTranscription`), and its text is matched here against installed
//  app names, locally.
//
//  Owner-only: the transcript is compared here and written only to the 0600
//  answers files. The decision trace carries app display names, never words.
//

import Foundation

nonisolated enum RealtimeHeardCheck {
    static let mismatchError = "heardNamedMismatch"
    static let unavailableError = "heardUnavailable"

    /// How long after the push-to-talk release a tool call may wait for the
    /// transcript before the check decides without it. Measured 2026-09-25, 79
    /// fixture turns per stack, release -> transcript complete: OpenAI
    /// (gpt-4o-mini-transcribe) median 660 ms, p95 810, max 1,809, and AFTER
    /// the first tool call in 35/74 turns (by at most 128 ms); Gemini median
    /// 293, p95 369, max 387, never after the call. 2.5 s is the OpenAI max
    /// plus ~0.7 s; it is only ever waited out when no transcript comes.
    static let transcriptDeadlineAfterReleaseSeconds: Double = 2.5

    // MARK: Which apps the words name (pure)

    /// Evidence tiers, strongest first. A word that fits two apps counts only
    /// when no app was named in full: "the cursor code editor" names Cursor, so
    /// "code" (VS Code, Claude Code URL Handler) is not also heard — but
    /// "cursor and chrome" is two apps. Sound-alikes count only when nothing
    /// else was heard.
    enum Tier: String {
        /// An app's file name, word for word or run together ("text edit").
        case fullName
        /// A running app's menu-bar name ("Code"), or one distinctive word of a
        /// longer name ("chrome").
        case word
        /// Sounds like a one-word app name ("kasa" for Cursor).
        case soundAlike
    }

    struct HeardApps: Equatable {
        /// Distinct apps, in order of first mention.
        let apps: [URL]
        /// A single word fits two or more apps ("code").
        let ambiguousWord: Bool
        let tier: Tier?

        static let none = HeardApps(apps: [], ambiguousWord: false, tier: nil)
    }

    /// Words of multi-word app names that are ordinary command or product words,
    /// so they never name an app on their own: "font" is Font Book's word AND
    /// the Format menu's; "time" is Time Machine's AND every clock question's.
    /// ponytail: a hand list drawn from this Mac's apps (2026-09-25); an app
    /// installed later with a common word in its name can be heard by that word.
    static let genericNameWords: Set<String> = [
        "app", "apps", "google", "microsoft", "system", "utility", "assistant", "player", "center", "centre",
        "editor", "script", "classic", "handler", "image", "photo", "screen", "sharing", "information",
        "capture", "font", "book", "time", "machine", "control", "file", "exchange", "audio", "setup", "print",
        "color", "digital", "meter", "word", "flow", "toolbox", "zoom", "window", "store", "memos", "mirroring"
    ]

    /// Sound-alike matching only reads a word in the APP SLOT — right after one
    /// of these, or the last word said — so "click" in "click the button" is
    /// never heard as Clock. "the" joined after probe 9BC0CACB: "in the Kasa
    /// code editor".
    static let appSlotLeadWords: Set<String> = ["in", "into", "to", "on", "from", "open", "launch", "focus", "switch", "use", "the"]
    /// Everyday words that share a sound key with an app installed here and can
    /// sit in the app slot ("just in case" is Cursor's key). ponytail: a hand
    /// list; a wrong hit only ever makes the check ASK, never act.
    static let soundAlikeStopWords: Set<String> = ["case", "cause", "course", "coarse", "curse", "click", "clerk", "commit", "decay", "nation", "sticks", "worthy"]

    /// A rough English sound key: c/q/z/x folded to k/s, r dropped where a
    /// non-rhotic speaker drops it (not before a vowel), every vowel one
    /// symbol, doubled letters once. "cursor", "kasa", "kaza" and "kassa" all
    /// key to "kasa". Deliberately coarse; the tier and the app slot are what
    /// keep it conservative.
    static func soundKey(_ word: String) -> String {
        let vowels: Set<Character> = ["a", "e", "i", "o", "u", "y"]
        var letters = word.lowercased().filter { $0.isASCII && $0.isLetter }
        for (from, to) in [("ph", "f"), ("ck", "k"), ("qu", "kw"), ("x", "ks")] {
            letters = letters.replacingOccurrences(of: from, with: to)
        }
        let characters = Array(letters)
        var keyed: [Character] = []
        for (index, character) in characters.enumerated() {
            let next: Character? = index + 1 < characters.count ? characters[index + 1] : nil
            var mapped = character
            switch character {
            case "c": mapped = next.map { "eiy".contains($0) } == true ? "s" : "k"
            case "q": mapped = "k"
            case "z": mapped = "s"
            case "r" where next.map { !vowels.contains($0) } ?? true: continue
            default: break
            }
            if vowels.contains(mapped) { mapped = "a" }
            if keyed.last != mapped { keyed.append(mapped) }
        }
        return String(keyed)
    }

    static func appsMentioned(in transcript: String, among names: [RealtimeVoiceVerbs.AppName]) -> HeardApps {
        let spoken = RealtimeVoiceVerbs.foldedTokens(transcript)
        guard !spoken.isEmpty else { return .none }
        func path(_ url: URL) -> String { url.standardizedFileURL.path }
        func distinct(_ urls: [URL]) -> [URL] {
            var seen = Set<String>()
            return urls.filter { seen.insert(path($0)).inserted }
        }
        /// Does the run of spoken words, joined, equal the name's words joined?
        func said(_ name: String) -> Bool {
            let wanted = RealtimeVoiceVerbs.foldedTokens(name).joined()
            guard !wanted.isEmpty else { return false }
            return spoken.indices.contains { start in
                var joined = ""
                for word in spoken[start...] {
                    joined += word
                    if joined == wanted { return true }
                    if joined.count >= wanted.count || !wanted.hasPrefix(joined) { return false }
                }
                return false
            }
        }

        let fullNames = distinct(names.filter { $0.isFileName && said($0.name) }.map(\.url))

        // Word tier: a menu-bar name said in full, or one distinctive word.
        var appsByWord: [String: [URL]] = [:]
        for name in names {
            let tokens = RealtimeVoiceVerbs.foldedTokens(name.name)
            // One-word names join too, so "claude" is Claude's AND a word of Claude
            // Code URL Handler's: ambiguous as a word, and the full name decides.
            if !name.isFileName || tokens.count == 1 { appsByWord[tokens.joined(), default: []].append(name.url) }
            guard tokens.count > 1 else { continue }
            for token in Set(tokens) where token.count >= 4 && !genericNameWords.contains(token) {
                appsByWord[token, default: []].append(name.url)
            }
        }
        // A menu-bar name of more than one word ("Google Chrome" while running).
        var wordApps = names.filter { !$0.isFileName && RealtimeVoiceVerbs.foldedTokens($0.name).count > 1 && said($0.name) }.map(\.url)
        var ambiguousWordApps: [URL] = []
        for word in spoken {
            guard let apps = appsByWord[word].map(distinct) else { continue }
            if apps.count > 1 { ambiguousWordApps += apps } else { wordApps += apps }
        }
        if !fullNames.isEmpty { return HeardApps(apps: distinct(fullNames + wordApps), ambiguousWord: false, tier: .fullName) }
        if !wordApps.isEmpty {
            return HeardApps(apps: distinct(wordApps + ambiguousWordApps), ambiguousWord: !ambiguousWordApps.isEmpty, tier: .word)
        }
        var ambiguousWord = !ambiguousWordApps.isEmpty

        // Sound-alike tier: only one-word names of five letters or more, only
        // words of four or more in the app slot.
        var appsByKey: [String: [URL]] = [:]
        for name in names {
            let tokens = RealtimeVoiceVerbs.foldedTokens(name.name)
            guard tokens.count == 1, tokens[0].count >= 5 else { continue }
            appsByKey[soundKey(tokens[0]), default: []].append(name.url)
        }
        var soundApps: [URL] = []
        for (index, word) in spoken.enumerated() {
            let inSlot = index == spoken.count - 1 || (index > 0 && appSlotLeadWords.contains(spoken[index - 1]))
            guard inSlot, word.count >= 4, !soundAlikeStopWords.contains(word),
                  let apps = appsByKey[soundKey(word)].map(distinct) else { continue }
            if apps.count > 1 { ambiguousWord = true }
            soundApps += apps
        }
        // A sound-alike beside a word that fits two apps is one more candidate,
        // never the answer: probe 9BC0CACB heard "the Kasa code editor" 10/10.
        if !ambiguousWordApps.isEmpty { return HeardApps(apps: distinct(soundApps + ambiguousWordApps), ambiguousWord: true, tier: .word) }
        if !soundApps.isEmpty { return HeardApps(apps: distinct(soundApps), ambiguousWord: ambiguousWord, tier: .soundAlike) }
        return .none
    }

    // MARK: The decision (pure)

    enum Outcome: String {
        /// The words name exactly one app, and it is the one the tool named.
        case match
        /// The words name one app and the tool named another: ask.
        case heardNamedMismatch
        /// The words name two or more apps, or a word fits two: ask.
        case ambiguousApp
        /// The words name no app ("switch to list view"): the existing check decides.
        case noAppHeard
        /// No transcript by the deadline.
        case transcriptMissing
    }

    struct Decision: Equatable {
        let outcome: Outcome
        /// Display names of the apps heard.
        let heardApps: [String]
        let tier: Tier?
        /// The tool result to hand back instead of calling the harness; nil proceeds.
        var refusalError: String? {
            switch outcome {
            case .heardNamedMismatch: return RealtimeHeardCheck.mismatchError
            case .ambiguousApp: return "ambiguousApp"
            case .match, .noAppHeard, .transcriptMissing: return nil
            }
        }
    }

    /// `transcript` nil or blank: nothing was heard in time. press_menu then
    /// fails CLOSED (`refusesWithoutTranscript`); the other tools proceed on the
    /// checks they already had — see `refusesWithoutTranscript`.
    static func decide(transcript: String?, named: String, among names: [RealtimeVoiceVerbs.AppName]) -> Decision {
        guard let transcript, !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return Decision(outcome: .transcriptMissing, heardApps: [], tier: nil)
        }
        let heard = appsMentioned(in: transcript, among: names)
        let heardNames = heard.apps.map(RealtimeVoiceVerbs.displayName)
        guard let only = heard.apps.first else { return Decision(outcome: .noAppHeard, heardApps: [], tier: nil) }
        guard heard.apps.count == 1, !heard.ambiguousWord else {
            return Decision(outcome: .ambiguousApp, heardApps: heardNames, tier: heard.tier)
        }
        let samePath = { (url: URL) in url.standardizedFileURL.path == only.standardizedFileURL.path }
        let agrees: Bool
        switch RealtimeVoiceVerbs.resolveApp(named: named, among: names) {
        case .resolved(let url): agrees = samePath(url)
        // The existing identity check still asks about an ambiguous name downstream.
        case .ambiguous(let urls): agrees = urls.contains(where: samePath)
        case .notInstalled: agrees = false
        }
        return Decision(outcome: agrees ? .match : .heardNamedMismatch, heardApps: heardNames, tier: heard.tier)
    }

    /// Owner's decision recorded in the commit: with no transcript, only a
    /// PRESS refuses. A find is a read. open_app and focus_app change only which
    /// app is in front, are undone by one more request, and keep every harness
    /// guard (policy, confirmation tickets for code-running apps) — refusing
    /// them would make a dropped transcription stop the whole voice loop.
    static func refusesWithoutTranscript(toolName: String) -> Bool {
        toolName == RealtimeVoiceVerbs.pressMenuName
    }

    /// Whether this tool is checked at all: every tool that names an app.
    static func appliesTo(toolName: String) -> Bool {
        RealtimeVoiceVerbs.allToolNames.contains(toolName)
    }

    /// What the model is told instead of a harness answer. Display names only
    /// (from the file system, not the transcript); `named` is the model's own.
    static func refusal(for decision: Decision, toolName: String, named: String) -> [String: Any]? {
        let shownNamed = UntrustedText(named).forDisplay
        switch decision.outcome {
        case .heardNamedMismatch:
            let heard = decision.heardApps.first ?? "another app"
            return ["ok": false, "status": NSNull(), "error": mismatchError, "heard": heard, "named": named,
                    "message": "the owner said \(heard), but this call names \(shownNamed). Nothing was opened, focused, "
                        + "searched or pressed. Ask the owner, briefly, whether they meant \(heard)."]
        case .ambiguousApp:
            return ["ok": false, "status": NSNull(), "error": "ambiguousApp", "named": named, "candidates": decision.heardApps,
                    "message": "the owner's words fit more than one installed app: \(decision.heardApps.joined(separator: ", ")). "
                        + "Nothing was opened, focused, searched or pressed. Ask the owner which one they meant."]
        case .transcriptMissing where refusesWithoutTranscript(toolName: toolName):
            return ["ok": false, "status": NSNull(), "error": unavailableError, "named": named,
                    "message": "the owner's words were not transcribed in time to confirm which app they meant. "
                        + "Nothing was pressed. Ask them to say the app's name again."]
        default:
            return nil
        }
    }

    /// The decision trace's `heardCheck` (schema 3). No words, only app names and timings.
    static func traceObject(_ decision: Decision, named: String, transcriptArrivalMs: Int?, waitedMs: Int) -> [String: Any] {
        ["outcome": decision.outcome.rawValue, "heardApps": decision.heardApps, "tier": decision.tier?.rawValue ?? NSNull(),
         "named": named, "transcriptArrivalMs": transcriptArrivalMs ?? NSNull(), "waitedMs": waitedMs]
    }
}
