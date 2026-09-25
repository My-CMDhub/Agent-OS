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
//  answers files. The decision trace (also 0600) carries app display names and
//  at most the app-slot word(s) that are not ordinary English — the one word a
//  mishearing lives in ("kasa") — never the sentence.
//

import Foundation

nonisolated enum RealtimeHeardCheck {
    static let mismatchError = "heardNamedMismatch"
    static let unavailableError = "heardUnavailable"
    static let unconfirmedError = "heardUnconfirmed"

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
        /// A common-word app name ("Preview", "Home") heard where only an app
        /// name fits: the app slot, or the whole utterance.
        case slot
        /// A running app's menu-bar name ("Code"), or one distinctive word of a
        /// longer name ("chrome").
        case word
        /// Sounds like a one-word app name ("kasa" for Cursor).
        case soundAlike

        /// Evidence that lets the model re-call with the heard app after a
        /// refusal this turn. A distinctive word or a sound-alike is a guess the
        /// owner has not confirmed; re-calling with it is the model answering
        /// its own question.
        var confirmsARetry: Bool { self == .fullName || self == .slot }
        /// The refusal says "may have said", not "said".
        var isTentative: Bool { self == .soundAlike || self == .slot }
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

    /// One-word app names that are also everyday words: they name an app only
    /// in the common-name slot (`isInCommonNameSlot`) or as the whole
    /// utterance. "show the preview pane in finder" hears only Finder; "go
    /// home" hears nothing. Never matched as a word or a sound-alike.
    /// ponytail: a hand list of Apple's own apps (2026-09-25); a third-party
    /// app with an everyday name is matched anywhere until it is added here.
    static let commonWordAppNames: Set<String> = [
        "preview", "home", "photos", "music", "notes", "maps", "news", "pages", "numbers", "clock", "contacts",
        "stocks", "mail", "books", "reminders", "calendar", "messages", "weather", "shortcuts", "podcasts", "tv",
        "tips", "passwords", "journal", "games", "phone", "chess", "stickies", "freeform"
    ]
    /// Right after these (or "bring up") only an app name fits.
    static let commonNameSlotLeadWords: Set<String> = ["open", "in", "to", "launch"]
    /// Dropped before asking whether the utterance is just the name ("Preview, please").
    static let fillerWords: Set<String> = ["the", "app", "please", "now", "hey", "ok", "okay", "jarvis"]

    static func isInCommonNameSlot(_ spoken: [String], at index: Int) -> Bool {
        guard index > 0 else { return false }
        if commonNameSlotLeadWords.contains(spoken[index - 1]) { return true }
        return index > 1 && spoken[index - 2] == "bring" && spoken[index - 1] == "up"
    }

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
        /// Where the run of spoken words, joined, equals the name's words joined.
        func starts(_ name: String) -> [Int] {
            let wanted = RealtimeVoiceVerbs.foldedTokens(name).joined()
            guard !wanted.isEmpty else { return [] }
            return spoken.indices.filter { start in
                var joined = ""
                for word in spoken[start...] {
                    joined += word
                    if joined == wanted { return true }
                    if joined.count >= wanted.count || !wanted.hasPrefix(joined) { return false }
                }
                return false
            }
        }
        func said(_ name: String) -> Bool { !starts(name).isEmpty }
        func isCommonWord(_ name: RealtimeVoiceVerbs.AppName) -> Bool {
            let tokens = RealtimeVoiceVerbs.foldedTokens(name.name)
            return tokens.count == 1 && commonWordAppNames.contains(tokens[0])
        }
        let unpadded = spoken.filter { !fillerWords.contains($0) }.joined()

        let fullNames = distinct(names.filter { $0.isFileName && !isCommonWord($0) && said($0.name) }.map(\.url))
        // A common-word name, file or menu-bar, only where nothing but an app name fits.
        let slotNames = distinct(names.filter { name in
            isCommonWord(name) && (starts(name.name).contains { isInCommonNameSlot(spoken, at: $0) }
                                   || unpadded == RealtimeVoiceVerbs.foldedTokens(name.name).joined())
        }.map(\.url))

        // Word tier: a menu-bar name said in full, or one distinctive word.
        var appsByWord: [String: [URL]] = [:]
        for name in names where !isCommonWord(name) {
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
        if !fullNames.isEmpty || !slotNames.isEmpty {
            return HeardApps(apps: distinct(fullNames + slotNames + wordApps), ambiguousWord: false, tier: fullNames.isEmpty ? .slot : .fullName)
        }
        if !wordApps.isEmpty {
            return HeardApps(apps: distinct(wordApps + ambiguousWordApps), ambiguousWord: !ambiguousWordApps.isEmpty, tier: .word)
        }
        var ambiguousWord = !ambiguousWordApps.isEmpty

        // Sound-alike tier: only one-word names of five letters or more, only
        // words of four or more in the app slot.
        var appsByKey: [String: [URL]] = [:]
        for name in names where !isCommonWord(name) {
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

    // MARK: The app slot, read when nothing else settles it (pure)

    /// The words read as "where the app name goes": the word after one of these,
    /// or the last word said. Wider than the matching slots above, because
    /// this only ever LOGS a word or ASKS.
    static let heardSlotLeadWords: Set<String> = ["in", "to", "the", "open", "for"]

    /// macOS's own word list, `/usr/share/dict/words` (Webster's Second, 1934:
    /// 235,976 words on every Mac), lower-cased. Deterministic, unlike
    /// NSSpellChecker, which learns the owner's words and follows their language.
    /// Empty if unreadable, which makes every unknown slot word ASK — closed.
    static let englishWords: Set<String> = {
        guard let text = try? String(contentsOfFile: "/usr/share/dict/words", encoding: .utf8) else { return [] }
        return Set(text.split(separator: "\n").map { $0.lowercased() })
    }()
    /// Webster's Second predates computers. ponytail: a hand list of the
    /// everyday computing words it lacks; a menu word the call itself carries
    /// ("minimap") is covered separately, so this stays short.
    static let modernWords: Set<String> = [
        "email", "desktop", "download", "online", "inbox", "screenshot", "popup", "dropdown", "toolbar", "sidebar",
        "fullscreen", "emoji", "website", "homepage", "wifi", "bluetooth", "login", "logout", "username", "app", "apps",
        "tab", "tabs", "url", "browser", "devtools", "incognito", "workspace", "terminal", "settings", "okay"
    ]

    /// Plural and verb endings stripped once: Webster's lists "window", not "windows".
    static func isEnglishWord(_ word: String) -> Bool {
        if englishWords.contains(word) || modernWords.contains(word) { return true }
        return ["s", "es", "ed", "ing"].contains { suffix in
            word.count > suffix.count + 2 && word.hasSuffix(suffix) && englishWords.contains(String(word.dropLast(suffix.count)))
        }
    }

    struct SlotReading: Equatable {
        /// Name-like slot words that are not ordinary English, or that name or
        /// sound like an app: the trace's `heardSlot`.
        let logged: [String]
        /// Name-like slot words that are none of: an installed app's word, a
        /// sound-alike of one, English, a word of the call's own menu query.
        let unrecognised: [String]
    }

    static func readSlot(_ spoken: [String], among names: [RealtimeVoiceVerbs.AppName], menuWords: [String]) -> SlotReading {
        var slot: [String] = []
        for (index, word) in spoken.enumerated() where index == spoken.count - 1 || (index > 0 && heardSlotLeadWords.contains(spoken[index - 1])) {
            if word.count >= 3, word.allSatisfy(\.isLetter), !slot.contains(word) { slot.append(word) }
        }
        let appWords = Set(names.flatMap { name -> [String] in
            let tokens = RealtimeVoiceVerbs.foldedTokens(name.name)
            return tokens + [tokens.joined()]
        })
        let appKeys = Set(names.compactMap { name -> String? in
            let tokens = RealtimeVoiceVerbs.foldedTokens(name.name)
            return tokens.count == 1 && tokens[0].count >= 5 ? soundKey(tokens[0]) : nil
        })
        func isApp(_ word: String) -> Bool {
            appWords.contains(word) || (word.count >= 4 && !soundAlikeStopWords.contains(word) && appKeys.contains(soundKey(word)))
        }
        return SlotReading(
            logged: slot.filter { isApp($0) || !isEnglishWord($0) },
            unrecognised: slot.filter { word in
                !isApp(word) && !isEnglishWord(word) && !menuWords.contains { RealtimeVoiceVerbs.tokensMatch($0, word) }
            })
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
        /// A menu tool, no app heard, and the app slot holds a word that is no
        /// app, no sound-alike, not English and not a menu word ("in Zorbit"):
        /// the name was said and not caught, so ask rather than trust the model's.
        case appNameUnclear
        /// No transcript by the deadline.
        case transcriptMissing
        /// The words name the tool's app only by a guess (a distinctive word or
        /// a sound-alike), and a call this turn was already refused by this
        /// check: the model re-calling with the app it was told to ask about
        /// is not the owner's answer.
        case unconfirmedRetry
    }

    struct Decision: Equatable {
        let outcome: Outcome
        /// Display names of the apps heard.
        let heardApps: [String]
        let tier: Tier?
        /// `SlotReading.logged`, for the trace.
        var heardSlot: [String] = []
        /// The tool result to hand back instead of calling the harness; nil proceeds.
        var refusalError: String? {
            switch outcome {
            case .heardNamedMismatch: return RealtimeHeardCheck.mismatchError
            case .ambiguousApp: return "ambiguousApp"
            case .unconfirmedRetry: return RealtimeHeardCheck.unconfirmedError
            case .appNameUnclear: return RealtimeHeardCheck.unavailableError
            case .match, .noAppHeard, .transcriptMissing: return nil
            }
        }
    }

    /// `transcript` nil or blank: nothing was heard in time. press_menu then
    /// fails CLOSED (`refusesWithoutTranscript`); the other tools proceed on the
    /// checks they already had — see `refusesWithoutTranscript`.
    /// `afterHeardRefusal`: this check already refused a call this turn.
    /// `menuWords`: the call's own query words and path, which an app slot may
    /// hold ("hide the minimap").
    static func decide(transcript: String?, named: String, among names: [RealtimeVoiceVerbs.AppName],
                       afterHeardRefusal: Bool = false, toolName: String = "", menuWords: [String] = []) -> Decision {
        guard let transcript, !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return Decision(outcome: .transcriptMissing, heardApps: [], tier: nil)
        }
        let slot = readSlot(RealtimeVoiceVerbs.foldedTokens(transcript), among: names, menuWords: menuWords)
        var decision = decideHeard(transcript: transcript, named: named, among: names, afterHeardRefusal: afterHeardRefusal)
        // noAppHeard fails OPEN to the model's name, so a menu tool asks when a
        // name-like word sat where the app goes and matched nothing.
        if decision.outcome == .noAppHeard, RealtimeVoiceVerbs.isAppScopedMenuTool(toolName), !slot.unrecognised.isEmpty {
            decision = Decision(outcome: .appNameUnclear, heardApps: [], tier: nil)
        }
        decision.heardSlot = slot.logged
        return decision
    }

    private static func decideHeard(transcript: String, named: String, among names: [RealtimeVoiceVerbs.AppName],
                                    afterHeardRefusal: Bool) -> Decision {
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
        if agrees, afterHeardRefusal, heard.tier?.confirmsARetry != true {
            return Decision(outcome: .unconfirmedRetry, heardApps: heardNames, tier: heard.tier)
        }
        return Decision(outcome: agrees ? .match : .heardNamedMismatch, heardApps: heardNames, tier: heard.tier)
    }

    /// With no transcript: a PRESS refuses, and so does an open_app of an app
    /// that is not running — a LAUNCH runs the app's code and leaves it running,
    /// which one more request does not undo. A find is a read; focus_app, and
    /// open_app of a running app, only change which app is in front, keep every
    /// harness guard (policy, confirmation tickets for code-running apps), and
    /// refusing them would let a dropped transcription stop the voice loop.
    static func refusesWithoutTranscript(toolName: String, namedAppIsRunning: Bool) -> Bool {
        toolName == RealtimeVoiceVerbs.pressMenuName || (toolName == RealtimeOpenAppTool.name && !namedAppIsRunning)
    }

    /// Whether this tool is checked at all: every tool that names an app.
    static func appliesTo(toolName: String) -> Bool {
        RealtimeVoiceVerbs.allToolNames.contains(toolName)
    }

    /// What the model is told instead of a harness answer. Display names only
    /// (from the file system, not the transcript); `named` is the model's own.
    /// `namedAppIsRunning` matters only without a transcript (`refusesWithoutTranscript`).
    static func refusal(for decision: Decision, toolName: String, named: String, namedAppIsRunning: Bool = true) -> [String: Any]? {
        let shownNamed = UntrustedText(named).forDisplay
        switch decision.outcome {
        case .heardNamedMismatch:
            let heard = decision.heardApps.first ?? "another app"
            let said = decision.tier?.isTentative == true ? "may have said" : "said"
            return ["ok": false, "status": NSNull(), "error": mismatchError, "heard": heard, "named": named,
                    "message": "the owner \(said) \(heard), but this call names \(shownNamed). Nothing was opened, focused, "
                        + "searched or pressed. Ask the owner, briefly, whether they meant \(heard)."]
        case .unconfirmedRetry:
            let heard = decision.heardApps.first ?? "that app"
            return ["ok": false, "status": NSNull(), "error": unconfirmedError, "heard": heard, "named": named,
                    "message": "the owner may have said \(heard), but it was not heard clearly, and calling again is not their "
                        + "answer. Nothing was opened, focused, searched or pressed. Ask the owner, briefly, whether they meant "
                        + "\(heard), and wait for them to say so."]
        case .ambiguousApp:
            return ["ok": false, "status": NSNull(), "error": "ambiguousApp", "named": named, "candidates": decision.heardApps,
                    "message": "the owner's words fit more than one installed app: \(decision.heardApps.joined(separator: ", ")). "
                        + "Nothing was opened, focused, searched or pressed. Ask the owner which one they meant."]
        case .appNameUnclear:
            return ["ok": false, "status": NSNull(), "error": unavailableError, "named": named,
                    "message": "the owner's words name no installed app that could be recognised, so which app they meant "
                        + "is not confirmed. Nothing was searched or pressed. Ask them to say the app's name again."]
        case .transcriptMissing where refusesWithoutTranscript(toolName: toolName, namedAppIsRunning: namedAppIsRunning):
            let nothing = toolName == RealtimeOpenAppTool.name ? "Nothing was opened: \(shownNamed) is not running, and opening it would launch it."
                : "Nothing was pressed."
            return ["ok": false, "status": NSNull(), "error": unavailableError, "named": named,
                    "message": "the owner's words were not transcribed in time to confirm which app they meant. "
                        + nothing + " Ask them to say the app's name again."]
        default:
            return nil
        }
    }

    /// The decision trace's `heardCheck` (schema 3). App names, timings, and
    /// only the app-slot words `heardSlot` keeps — never the sentence.
    static func traceObject(_ decision: Decision, named: String, transcriptArrivalMs: Int?, waitedMs: Int) -> [String: Any] {
        ["outcome": decision.outcome.rawValue, "heardApps": decision.heardApps, "tier": decision.tier?.rawValue ?? NSNull(),
         "named": named, "transcriptArrivalMs": transcriptArrivalMs ?? NSNull(), "waitedMs": waitedMs, "heardSlot": decision.heardSlot]
    }
}
