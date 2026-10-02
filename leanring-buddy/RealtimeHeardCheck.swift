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
    /// 293, p95 369, max 387, never after the call. LIVE voices are slower
    /// (voice-decisions.log to 2026-10-02): Gemini 123 turns, median 362 ms,
    /// max 3,107, 8 past 2.5 s; OpenAI 47, max 2,676. 4 s is the live max plus
    /// ~0.9 s; it is only ever waited out when no transcript comes.
    static let transcriptDeadlineAfterReleaseSeconds: Double = 4.0

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
        "color", "digital", "meter", "word", "flow", "toolbox", "zoom", "window", "store", "memos", "mirroring",
        // Every app's own UI words (live 2026-09-30: "Cursor settings", "the
        // general settings" were heard as System Settings four turns running).
        "settings", "setting", "preferences", "general", "panel", "sidebar", "options", "option", "tab", "button", "menu"
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
    /// `contentWords`: what the call puts INTO the app — type_text's text,
    /// open_url's site — folded. An app named only by them is content, not the
    /// app meant (live 2026-10-02 28B7: "search for LinkedIn" typed into
    /// Chrome was refused as the LinkedIn web app). `namedIsBrowser`: the call's
    /// app opens web pages, so "in this browser" is inside it (D30199AA).
    static func decide(transcript: String?, named: String, among names: [RealtimeVoiceVerbs.AppName],
                       afterHeardRefusal: Bool = false, toolName: String = "", menuWords: [String] = [],
                       targetWords: [String] = [], frontmostApp: URL? = nil,
                       contentWords: [String] = [], namedIsBrowser: Bool = false) -> Decision {
        guard let rawTranscript = transcript, !rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return Decision(outcome: .transcriptMissing, heardApps: [], tier: nil)
        }
        let transcript = withoutWebAddresses(rawTranscript)
        // A word of the call's own target — its query, the offered labels, the
        // element under the owner's pointer — is a thing inside the app, not a
        // missed app name: live 2026-10-02 90A952DF, "click on the internet one,
        // this one" with the pointer on a page's "Internet" link was refused
        // heardUnavailable. The same evidence `withoutWordsInsideTheNamedApp` uses.
        let slot = readSlot(RealtimeVoiceVerbs.foldedTokens(transcript), among: names, menuWords: menuWords + targetWords)
        var decision = decideHeard(transcript: transcript, named: named, among: names, afterHeardRefusal: afterHeardRefusal,
                                   toolName: toolName, targetWords: targetWords, frontmostApp: frontmostApp,
                                   contentWords: contentWords, namedIsBrowser: namedIsBrowser)
        // noAppHeard fails OPEN to the model's name, so a menu tool asks when a
        // name-like word sat where the app goes and matched nothing.
        if decision.outcome == .noAppHeard, RealtimeVoiceVerbs.isAppScopedMenuTool(toolName), !slot.unrecognised.isEmpty {
            decision = Decision(outcome: .appNameUnclear, heardApps: [], tier: nil)
        }
        decision.heardSlot = slot.logged
        return decision
    }

    private static func decideHeard(transcript: String, named: String, among names: [RealtimeVoiceVerbs.AppName],
                                    afterHeardRefusal: Bool, toolName: String, targetWords: [String], frontmostApp: URL?,
                                    contentWords: [String], namedIsBrowser: Bool) -> Decision {
        func path(_ url: URL) -> String { url.standardizedFileURL.path }
        let namedPaths: Set<String>
        switch RealtimeVoiceVerbs.resolveApp(named: named, among: names) {
        case .resolved(let url): namedPaths = [path(url)]
        // The existing identity check still asks about an ambiguous name downstream.
        case .ambiguous(let urls): namedPaths = Set(urls.map(path))
        case .notInstalled: namedPaths = []
        }
        var heard = withoutContent(appsMentioned(in: transcript, among: names), contentWords: contentWords,
                                   namedPaths: namedPaths, among: names)
        heard = withoutWordsInsideTheNamedApp(heard, transcript: transcript, namedPaths: namedPaths, among: names,
                                              targetWords: targetWords, frontmostApp: frontmostApp, namedIsBrowser: namedIsBrowser)
        let heardNames = heard.apps.map(RealtimeVoiceVerbs.displayName)
        guard let only = heard.apps.first else { return Decision(outcome: .noAppHeard, heardApps: [], tier: nil) }
        // Two apps said ("open Chrome and open LinkedIn"), and this call opens or
        // focuses one of them: that call is not ambiguous. A word that fits two
        // apps ("code") still is.
        // Unless the owner put the named app INSIDE the other one: "open terminal
        // in cursor" is Cursor's terminal, never a launch of Terminal (review 2026-10-01).
        func words(of url: URL) -> [[String]] {
            names.filter { path($0.url) == path(url) }.map { RealtimeVoiceVerbs.foldedTokens($0.name) }
        }
        let namedNames = heard.apps.filter { namedPaths.contains(path($0)) }.flatMap(words)
        let otherWords = Set(heard.apps.filter { !namedPaths.contains(path($0)) }.flatMap(words).joined()
            .filter { !genericNameWords.contains($0) })
        let spoken = RealtimeVoiceVerbs.foldedTokens(transcript)
        let opensOneOfThem = [RealtimeOpenAppTool.name, RealtimeVoiceVerbs.focusAppName].contains(toolName)
            && !heard.ambiguousWord && heard.apps.contains { namedPaths.contains(path($0)) }
            && !placesInside(namedNames + namedNames.joined().filter { $0.count >= 4 && !genericNameWords.contains($0) }.map { [$0] },
                             containerWords: otherWords, spoken: spoken)
        guard (heard.apps.count == 1 && !heard.ambiguousWord) || opensOneOfThem else {
            return Decision(outcome: .ambiguousApp, heardApps: heardNames, tier: heard.tier)
        }
        let agrees = opensOneOfThem || namedPaths.contains(path(only))
        if agrees, afterHeardRefusal, heard.tier?.confirmsARetry != true {
            return Decision(outcome: .unconfirmedRetry, heardApps: heardNames, tier: heard.tier)
        }
        return Decision(outcome: agrees ? .match : .heardNamedMismatch, heardApps: heardNames, tier: heard.tier)
    }

    // MARK: Content and web addresses are not apps (pure)

    /// Top-level domains a spoken or written address ends in.
    static let webAddressSuffixes = ["com", "org", "net", "io", "ai", "co", "dev", "uk", "in", "au", "me", "tv", "gov", "edu"]

    /// "linkedin.com" and "linkedin dot com" name a website, never an app (live
    /// 2026-10-02 00768893: "type down linkedin.com" refused opening Chrome as
    /// the LinkedIn web app). The address is dropped before apps are heard. A
    /// written one only with no space around the dot: "Cursor. In the…" is two
    /// sentences.
    static func withoutWebAddresses(_ transcript: String) -> String {
        let suffixes = webAddressSuffixes.joined(separator: "|")
        return transcript.replacingOccurrences(of: #"(?i)\b[\p{L}\p{N}-]+(?:\.|\s+dot\s+)(?:"# + suffixes + #")\b"#, with: " ",
                                               options: .regularExpression)
    }

    /// Words of a call's content, folded, with each adjacent pair run together
    /// too ("linked in" is LinkedIn).
    static func contentTokens(_ text: String) -> [String] {
        let tokens = RealtimeVoiceVerbs.foldedTokens(text)
        return tokens + zip(tokens, tokens.dropFirst()).map { $0 + $1 }
    }

    /// Drops every app other than the call's whose whole name is in the call's content.
    static func withoutContent(_ heard: HeardApps, contentWords: [String], namedPaths: Set<String>,
                               among names: [RealtimeVoiceVerbs.AppName]) -> HeardApps {
        guard !contentWords.isEmpty else { return heard }
        func path(_ url: URL) -> String { url.standardizedFileURL.path }
        let content = Set(contentWords)
        let kept = heard.apps.filter { app in
            namedPaths.contains(path(app)) || !names.filter { path($0.url) == path(app) }.contains { name in
                let tokens = RealtimeVoiceVerbs.foldedTokens(name.name)
                return !tokens.isEmpty && (tokens.allSatisfy(content.contains) || content.contains(tokens.joined()))
            }
        }
        guard kept.count != heard.apps.count else { return heard }
        return HeardApps(apps: kept, ambiguousWord: heard.ambiguousWord, tier: kept.isEmpty ? nil : heard.tier)
    }

    // MARK: open_url's site (pure)

    /// The site a URL names, as the owner would say it: the registrable label
    /// of its host — "linkedin" for www.linkedin.com, "bbc" for bbc.co.uk.
    static func siteName(of url: String) -> String? {
        guard let host = URL(string: url)?.host?.lowercased() else { return nil }
        var labels = host.split(separator: ".").map(String.init)
        if labels.count > 2, ["www", "m"].contains(labels[0]) { labels.removeFirst() }
        guard labels.count >= 2 else { return labels.first.map { RealtimeVoiceVerbs.foldedTokens($0).joined() } }
        let secondLevel = ["co", "com", "org", "net", "ac", "gov", "edu"]
        let index = labels.count >= 3 && labels.last?.count == 2 && secondLevel.contains(labels[labels.count - 2])
            ? labels.count - 3 : labels.count - 2
        let name = RealtimeVoiceVerbs.foldedTokens(labels[index]).joined()
        return name.isEmpty ? nil : name
    }

    /// Words that, within three words before the site in the same clause, say
    /// NOT to open it: "don't open evil.com" ("don't" folds to "don", "t").
    static let siteNegations: Set<String> = ["not", "no", "never", "dont", "don", "t", "nt", "cannot", "without", "instead"]

    /// Whether the owner's words say the site: as one word, or run together
    /// from consecutive words ("linked in"). Never letters inside a word, and
    /// never just after a negation in its own clause ("No, open LinkedIn" is two).
    static func heardSite(_ transcript: String, siteName: String) -> Bool {
        transcript.split(whereSeparator: { ",;:.!?\n".contains($0) }).contains { clause in
            let spoken = RealtimeVoiceVerbs.foldedTokens(String(clause))
            return spoken.indices.contains { start in
                guard !spoken[max(0, start - 3)..<start].contains(where: siteNegations.contains) else { return false }
                var joined = ""
                for word in spoken[start...] {
                    joined += word
                    if joined == siteName { return true }
                    if !siteName.hasPrefix(joined) { return false }
                }
                return false
            }
        }
    }

    /// A URL that carries another address in its query or fragment: a
    /// redirector ("linkedin.com/redir?url=https://evil.example") passes the
    /// site check on its own host and lands somewhere else.
    static func carriesAnotherAddress(_ url: String) -> Bool {
        guard let components = URLComponents(string: url) else { return false }
        let tail = ((components.percentEncodedQuery ?? "") + "#" + (components.percentEncodedFragment ?? "")).lowercased()
        return tail.contains("://") || tail.contains("%3a%2f%2f")
    }

    /// open_url's heard check: the owner's words must name the site, or nothing
    /// is opened (a page the owner never mentioned is the model's idea). nil proceeds.
    static func siteRefusal(transcript: String?, url: String?) -> [String: Any]? {
        guard let url, let site = siteName(of: url) else { return nil }   // the harness refuses a bad URL itself
        if carriesAnotherAddress(url) {
            return ["ok": false, "status": NSNull(), "error": "urlCarriesAnotherAddress",
                    "message": "that address carries another address inside it, so it may land on a different site. Nothing was opened. "
                        + "Open the site's own address instead."]
        }
        guard let transcript, !transcript.allSatisfy(\.isWhitespace) else {
            return ["ok": false, "status": NSNull(), "error": unavailableError,
                    "message": "the owner's words were not transcribed in time to confirm the site. Nothing was opened. Ask them to say it again."]
        }
        guard !heardSite(transcript, siteName: site) else { return nil }
        return ["ok": false, "status": NSNull(), "error": "heardSiteMismatch", "site": site,
                "message": "the owner's words do not name \(site). Nothing was opened. Ask the owner, briefly, which site they meant."]
    }

    // MARK: A word for something inside the app (pure)

    /// Where the owner names an app: right after one of these. Narrower than
    /// `appSlotLeadWords` ("the" is not here): "close the terminal" names a
    /// panel, "open terminal" or "in console" may name an app.
    static let namingLeadWords: Set<String> = ["in", "into", "on", "inside", "within", "from", "to", "open", "launch", "focus", "switch", "use"]
    /// "the terminal in this cursor": skipped between the preposition and the app.
    static let containerFillerWords: Set<String> = ["the", "this", "my", "a", "that"]
    static let containerPrepositions: Set<String> = ["in", "on", "inside", "within"]

    /// Whether the words say "<one of `innerNames`> in/on/inside/within [the] <a container word>".
    static func placesInside(_ innerNames: [[String]], containerWords: Set<String>, spoken: [String]) -> Bool {
        innerNames.contains { name in
            !name.isEmpty && spoken.indices.contains { start in
                guard spoken[start...].starts(with: name) else { return false }
                var next = start + name.count
                guard next < spoken.count, containerPrepositions.contains(spoken[next]) else { return false }
                next += 1
                while next < spoken.count, containerFillerWords.contains(spoken[next]) { next += 1 }
                return next < spoken.count && containerWords.contains(spoken[next])
            }
        }
    }
    /// Not "no" (review 2026-10-01): "no, Terminal" is a correction that NAMES Terminal.
    static let negationWords: Set<String> = ["not", "never", "without"]

    /// The owner's live test 2026-09-30: "close the terminal" with Cursor in
    /// front, "the terminal in Cursor", "LinkedIn on Chrome" — eight turns
    /// refused because a word that names an app named a thing INSIDE the app the
    /// call acts in. Only when that app is in front or the owner named it, an
    /// app X other than the call's is dropped from what was heard when:
    ///  - every mention of X is negated ("not Terminal"), or
    ///  - no mention of X sits where an app is named (`namingLeadWords`) and X's
    ///    name is a word of the call's own target — element name, menu path,
    ///    find words, recently offered labels (`targetWords`, folded) — or
    ///  - the owner said X is inside the call's app: "X in/on/inside [the] <app>".
    /// D66FC598 stays asked: "a new window in cursor" with VS Code in front puts
    /// Cursor right after "in".
    static func withoutWordsInsideTheNamedApp(_ heard: HeardApps, transcript: String, namedPaths: Set<String>,
                                              among names: [RealtimeVoiceVerbs.AppName], targetWords: [String],
                                              frontmostApp: URL?, namedIsBrowser: Bool = false) -> HeardApps {
        func path(_ url: URL) -> String { url.standardizedFileURL.path }
        let namedIsFrontmost = frontmostApp.map { namedPaths.contains(path($0)) } ?? false
        guard !namedPaths.isEmpty, namedIsFrontmost || heard.apps.contains(where: { namedPaths.contains(path($0)) }) else { return heard }
        let spoken = RealtimeVoiceVerbs.foldedTokens(transcript)
        let target = Set(targetWords)
        func tokens(of url: URL) -> [[String]] {
            names.filter { path($0.url) == path(url) }.map { RealtimeVoiceVerbs.foldedTokens($0.name) }.filter { !$0.isEmpty }
        }
        // "LinkedIn within this browser" with a browser named: inside it (live D30199AA).
        let namedWords = Set(names.filter { namedPaths.contains(path($0.url)) }
            .flatMap { RealtimeVoiceVerbs.foldedTokens($0.name) }.filter { !genericNameWords.contains($0) })
            .union(namedIsBrowser ? ["browser"] : [])
        /// Each mention: where it starts and where it ends (exclusive).
        func mentions(of url: URL) -> [Range<Int>] {
            tokens(of: url).flatMap { name -> [Range<Int>] in
                spoken.indices.compactMap { start -> Range<Int>? in
                    if spoken[start...].starts(with: name) { return start..<(start + name.count) }
                    if name.count > 1, name.contains(spoken[start]), spoken[start].count >= 4,
                       !genericNameWords.contains(spoken[start]) { return start..<(start + 1) }
                    return nil
                }
            }
        }
        let kept = heard.apps.filter { app in
            guard !namedPaths.contains(path(app)) else { return true }
            let said = mentions(of: app)
            guard !said.isEmpty else { return true }
            if said.allSatisfy({ $0.lowerBound > 0 && negationWords.contains(spoken[$0.lowerBound - 1]) }) { return false }
            let named = said.contains { $0.lowerBound > 0 && namingLeadWords.contains(spoken[$0.lowerBound - 1]) }
            if !named, tokens(of: app).contains(where: { name in name.allSatisfy(target.contains) }) { return false }
            return !said.contains { mention in placesInside([Array(spoken[mention])], containerWords: namedWords, spoken: spoken) }
        }
        guard kept.count != heard.apps.count else { return heard }
        return HeardApps(apps: kept, ambiguousWord: heard.ambiguousWord, tier: kept.isEmpty ? nil : heard.tier)
    }

    /// With no transcript: a PRESS refuses, and so does an open_app of an app
    /// that is not running — a LAUNCH runs the app's code and leaves it running,
    /// which one more request does not undo. A find is a read; focus_app, and
    /// open_app of a running app, only change which app is in front, keep every
    /// harness guard (policy, confirmation tickets for code-running apps), and
    /// refusing them would let a dropped transcription stop the voice loop.
    /// type_text and close joined 2026-10-01 (review): typing puts text in an
    /// app and quitting ends one — neither on a model's word alone. A scroll
    /// changes only the view, so it keeps the checks it has.
    static func refusesWithoutTranscript(toolName: String, namedAppIsRunning: Bool) -> Bool {
        [RealtimeVoiceVerbs.pressMenuName, RealtimeVoiceVerbs.pressElementName, RealtimeVoiceVerbs.typeTextName,
         RealtimeVoiceVerbs.closeName].contains(toolName)
            || (toolName == RealtimeOpenAppTool.name && !namedAppIsRunning)
    }

    /// Whether this tool is checked at all: every tool that names an app.
    static func appliesTo(toolName: String) -> Bool {
        RealtimeVoiceVerbs.allToolNames.contains(toolName)
    }

    /// Whether the check may REFUSE the call. Reads never are (slice 1b: four
    /// live turns were lost asking about "settings" on a read); their decision
    /// is still made, because it is the witness `autoFocusGate` needs.
    static func mayRefuse(toolName: String) -> Bool {
        appliesTo(toolName: toolName) && !RealtimeVoiceVerbs.readOnlyToolNames.contains(toolName)
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
                : toolName == RealtimeVoiceVerbs.typeTextName ? "Nothing was typed."
                : toolName == RealtimeVoiceVerbs.closeName ? "Nothing was closed." : "Nothing was pressed."
            return ["ok": false, "status": NSNull(), "error": unavailableError, "named": named,
                    "message": "the owner's words were not transcribed in time to confirm which app they meant. "
                        + nothing + " Ask them to say the app's name again."]
        default:
            return nil
        }
    }

    // MARK: Transcriber vocabulary hint (pure)

    /// The transcriber wrote "Kasa"/"Kursor"/"CASA" for "cursor" on the fixture
    /// voice (probe 27BA20D2), so the check only ever had a sound-alike and
    /// asked. OpenAI's `audio.input.transcription.prompt` is free text for
    /// gpt-4o-*-transcribe (developers.openai.com/api/reference/resources/realtime/client-events,
    /// read 2026-09-28); with this list it wrote "Cursor" 5/5 on fixture 13
    /// (probe C92505CE). Gemini's documented `customVocabulary`
    /// (ai.google.dev/api/live, AudioTranscriptionConfig) was accepted and
    /// changed nothing — "Kasa" 8/8 — so Gemini is sent no hint. No length
    /// limit is published for these models; whisper-1's is 224 tokens, so the
    /// prompt stays under `transcriptionHintMaxCharacters` (~150 tokens).
    /// App display names ONLY — never a file name or window title. Running apps
    /// first (what the owner acts on), then the rest in folder order; menu-bar
    /// aliases ("Code") are skipped, their file name is there. Everyday-word
    /// names ("Preview", "Font Book") would only pull ordinary speech toward an
    /// app, so they are left out.
    static let transcriptionHintMaxCharacters = 600
    static let transcriptionHintPrefix = "App names on this Mac: "

    static func transcriptionVocabulary(from names: [RealtimeVoiceVerbs.AppName], runningPaths: Set<String>) -> [String] {
        let ordered = names.filter { runningPaths.contains($0.url.standardizedFileURL.path) }
            + names.filter { !runningPaths.contains($0.url.standardizedFileURL.path) }
        var seen = Set<String>()
        var budget = transcriptionHintMaxCharacters - transcriptionHintPrefix.count
        var vocabulary: [String] = []
        for name in ordered where name.isFileName {
            let tokens = RealtimeVoiceVerbs.foldedTokens(name.name)
            guard !tokens.isEmpty, !(tokens.count == 1 && commonWordAppNames.contains(tokens[0])),
                  !tokens.allSatisfy(genericNameWords.contains),
                  seen.insert(tokens.joined(separator: " ")).inserted else { continue }
            let cost = name.name.count + (vocabulary.isEmpty ? 0 : 2)
            guard cost <= budget else { break }
            budget -= cost
            vocabulary.append(name.name)
        }
        return vocabulary
    }

    /// OpenAI's free-text prompt: `transcriptionHintPrefix` plus the list.
    static func transcriptionPrompt(vocabulary: [String]) -> String {
        transcriptionHintPrefix + vocabulary.joined(separator: ", ")
    }

    // MARK: Auto-focus when both witnesses agree (pure)

    /// Probe 27BA20D2: the owner named Chrome, the tool named Google Chrome,
    /// the words agreed — and Finder was in front, so the menu tool came back
    /// `appMismatch` and Gemini stopped instead of focusing (Chrome 1/5). When
    /// the owner's words and the tool agree on one installed, RUNNING app and
    /// the only thing wrong is which app is in front, local code brings that
    /// app forward (reversible, through the harness's own focus and policy) and
    /// runs the call once more. Full-name, slot and word evidence count — a
    /// distinctive word ("chrome") joined on the owner's ruling 2026-09-28,
    /// after "chrome" scored at the word tier in 43/43 Chrome calls and so
    /// never triggered. A word still passes the generic-word and
    /// everyday-name lists, must fit exactly one app, and must agree with the
    /// tool's app. A sound-alike ("kasa") is a different word guessed and
    /// keeps asking. Never launches: a stopped app is open_app's job, which
    /// has its own heard check.
    static let autoFocusTiers: Set<Tier> = [.fullName, .slot, .word]

    struct AutoFocusGate: Equatable {
        let triggered: Bool
        let reason: String
    }

    /// nil: the call did not come back `appMismatch`, so the question never arose.
    /// `resolvedBundleIdentifier`: the app check's one installed app (nil: none).
    static func autoFocusGate(heard: Decision?, dispatchError: String?, resolvedBundleIdentifier: String?,
                              namedAppIsRunning: Bool) -> AutoFocusGate? {
        guard dispatchError == "appMismatch" else { return nil }
        guard let heard, heard.outcome == .match else {
            return AutoFocusGate(triggered: false, reason: "heard:\(heard?.outcome.rawValue ?? "notChecked")")
        }
        guard let tier = heard.tier, autoFocusTiers.contains(tier) else {
            return AutoFocusGate(triggered: false, reason: "tier:\(heard.tier?.rawValue ?? "none")")
        }
        guard resolvedBundleIdentifier != nil else { return AutoFocusGate(triggered: false, reason: "unresolved") }
        guard namedAppIsRunning else { return AutoFocusGate(triggered: false, reason: "notRunning") }
        return AutoFocusGate(triggered: true, reason: "witnessesAgree")
    }

    /// The decision trace's `heardCheck` (schema 3). App names, timings, and
    /// only the app-slot words `heardSlot` keeps — never the sentence.
    /// `refused`: the call was answered with this check's refusal, not run.
    static func traceObject(_ decision: Decision, named: String, transcriptArrivalMs: Int?, waitedMs: Int, refused: Bool) -> [String: Any] {
        ["refused": refused, "outcome": decision.outcome.rawValue, "heardApps": decision.heardApps, "tier": decision.tier?.rawValue ?? NSNull(),
         "named": named, "transcriptArrivalMs": transcriptArrivalMs ?? NSNull(), "waitedMs": waitedMs, "heardSlot": decision.heardSlot]
    }
}
