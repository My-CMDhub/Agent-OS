//
//  RealtimeVoiceVerbs.swift
//  leanring-buddy
//
//  The voice verbs after `open_app` (spec 2026-09-24 slice 4): `focus_app`,
//  `find_menu_items` and `press_menu`, and the decision trace that records
//  every choice a model makes with them.
//
//  The menu pair is a CHOOSER's interface on purpose. The model never writes a
//  menu path: `find_menu_items` reads the frontmost app's menu bar through the
//  harness's `menus`, filters it LOCALLY (enabled leaves only, private items
//  dropped, token overlap with the model's words) and offers at most twelve
//  exact paths; `press_menu` takes one of them back to the harness's `menu`,
//  where the kernel, tickets and refusals decide as they always have. So the
//  question "did it pick well from a real option list?" can be asked of any
//  chooser — the realtime model today, a fast chooser (TypeSafe Jev) offline
//  tomorrow — against the same logged lists.
//
//  Everything acts through `HarnessServer.answer(line:)` via
//  `RealtimeOpenAppTool.dispatch`; nothing here reads AX or acts.
//

import Foundation

nonisolated enum RealtimeVoiceVerbs {
    static let focusAppName = "focus_app"
    static let findMenuItemsName = "find_menu_items"
    static let pressMenuName = "press_menu"
    static let allToolNames: Set<String> = [RealtimeOpenAppTool.name, focusAppName, findMenuItemsName, pressMenuName]

    /// Enough to hold every View-menu toggle of a native app and short enough
    /// that a chooser reads the list, not skims it.
    static let maximumCandidates = 12

    // MARK: Declarations

    private struct Parameter {
        let name: String
        let isList: Bool
        let description: String
    }

    private struct Declaration {
        let name: String
        let description: String
        let parameters: [Parameter]
    }

    private static let declarations = [
        Declaration(name: focusAppName,
                    description: "Brings an app that is already running to the front. Use its name as shown in the Dock, for example \"Finder\".",
                    parameters: [Parameter(name: "name", isList: false, description: "The running app's name, for example \"Finder\".")]),
        Declaration(name: findMenuItemsName,
                    description: "Looks through the menu bar of the app in front for items matching a few words, and returns up to "
                        + "\(maximumCandidates) exact menu paths that can be pressed. The app must be in front; call focus_app first if it is not.",
                    parameters: [
                        Parameter(name: "app", isList: false, description: "The app whose menus to search, for example \"Finder\"."),
                        Parameter(name: "words", isList: false, description: "A few words for the command, for example \"list view\" or \"new window\".")
                    ]),
        Declaration(name: pressMenuName,
                    description: "Presses one menu item of the app in front. The path must be one that find_menu_items returned in this turn, copied exactly.",
                    parameters: [
                        Parameter(name: "app", isList: false, description: "The app in front, for example \"Finder\"."),
                        Parameter(name: "path", isList: true, description: "The menu path exactly as find_menu_items returned it, for example [\"View\", \"as List\"].")
                    ])
    ]

    /// OpenAI Realtime GA `session.tools`: open_app first, then these.
    static var openAIDeclarations: [[String: Any]] {
        [RealtimeOpenAppTool.openAIDeclaration] + declarations.map { declaration in
            [
                "type": "function", "name": declaration.name, "description": declaration.description,
                "parameters": [
                    "type": "object",
                    "properties": Dictionary(uniqueKeysWithValues: declaration.parameters.map { parameter in
                        (parameter.name, parameter.isList
                            ? ["type": "array", "items": ["type": "string"], "description": parameter.description] as [String: Any]
                            : ["type": "string", "description": parameter.description])
                    }),
                    "required": declaration.parameters.map(\.name)
                ] as [String: Any]
            ]
        }
    }

    /// Gemini Live `setup.tools` entry: one object holding every function.
    static var geminiDeclaration: [String: Any] {
        let openApp = (RealtimeOpenAppTool.geminiDeclaration["functionDeclarations"] as? [[String: Any]]) ?? []
        return ["functionDeclarations": openApp + declarations.map { declaration in
            [
                "name": declaration.name, "description": declaration.description,
                "parameters": [
                    "type": "OBJECT",
                    "properties": Dictionary(uniqueKeysWithValues: declaration.parameters.map { parameter in
                        (parameter.name, parameter.isList
                            ? ["type": "ARRAY", "items": ["type": "STRING"], "description": parameter.description] as [String: Any]
                            : ["type": "STRING", "description": parameter.description])
                    }),
                    "required": declaration.parameters.map(\.name)
                ] as [String: Any]
            ] as [String: Any]
        }]
    }

    // MARK: Menu offer (pure)

    /// Case-, diacritic- and width-folded words: "Afficher la barre" and
    /// "afficher la BARRE" are the same tokens.
    static func foldedTokens(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }

    /// Words a model pads a query with that name no menu item.
    static let ignoredQueryWords: Set<String> = ["the", "a", "an", "to", "in", "of", "for", "on", "and", "my", "me", "please", "menu", "menus"]

    /// Equal, or the shorter (3+ letters) begins the longer: "icon" finds "Icons",
    /// "window" finds "Windows". ponytail: prefix only, no stemming; "show"
    /// never finds "shown". Add a stemmer if a replay shows a real miss.
    static func tokensMatch(_ first: String, _ second: String) -> Bool {
        if first == second { return true }
        let (shorter, longer) = first.count <= second.count ? (first, second) : (second, first)
        return shorter.count >= 3 && longer.hasPrefix(shorter)
    }

    /// Open Recent, Recent Items, Recent Folders, Go > Recents: their children
    /// are the owner's file, folder and server names. Dropped before matching,
    /// before logging and before pressing — never offered, never recorded.
    /// Same class, found in the first Chrome run (2026-09-25): History (page
    /// titles), Bookmarks, Profiles (people), and the Apple menu (the account's
    /// full name in "Log Out …"; system commands, not the app's, anyway).
    static let privateTopLevelMenus: Set<String> = ["apple", "history", "bookmarks", "profiles"]

    static func isPrivateMenuPath(_ path: [String]) -> Bool {
        if let top = path.first, privateTopLevelMenus.contains(foldedTokens(top).joined(separator: " ")) { return true }
        return path.contains { foldedTokens($0).contains { $0.hasPrefix("recent") } }
    }

    /// The Window menu ends with one item per open window, named by its title —
    /// a Chrome tab's page title, a Cursor workspace. Nothing marks them, so a
    /// Window item with no shortcut is offered only if it is a known command.
    /// ponytail: English labels only; a localized command without a shortcut is
    /// simply not offered. Widen the list if a replay misses one.
    static let windowMenuCommandsWithoutShortcut: Set<String> = [
        "zoom", "zoom all", "bring all to front", "arrange in front", "merge all windows", "show all tabs",
        "show tab bar", "hide tab bar", "move tab to new window", "name window", "remove window from set"
    ]

    static func isPrivateMenuItem(path: [String], shortcut: String?) -> Bool {
        if isPrivateMenuPath(path) { return true }
        guard path.count == 2, foldedTokens(path[0]) == ["window"], shortcut == nil else { return false }
        return !windowMenuCommandsWithoutShortcut.contains(foldedTokens(path[1]).joined(separator: " "))
    }

    /// The candidates for `words`, from a `menus` response's items. Leaves only
    /// (the harness refuses a submenu parent as `targetIsSubmenu`), enabled only
    /// (a disabled item refuses anyway), private paths dropped, and every step a
    /// plausible label: the target app wrote them and they go into a model's context.
    static func menuOffer(fromMenusResponse response: [String: Any], words: String) -> RealtimeMenuOffer {
        let items = response["items"] as? [[String: Any]] ?? []
        var enabledItemCount = 0
        var privacyDroppedCount = 0
        var leaves: [RealtimeMenuCandidate] = []
        for item in items where item["enabled"] as? Bool == true {
            enabledItemCount += 1
            guard let path = item["path"] as? [String], !path.isEmpty else { continue }
            if isPrivateMenuItem(path: path, shortcut: item["shortcut"] as? String) { privacyDroppedCount += 1; continue }
            guard item["hasSubmenu"] as? Bool == false,
                  path.allSatisfy({ UntrustedText($0).isPlausibleControlLabel }) else { continue }
            leaves.append(RealtimeMenuCandidate(path: path, shortcut: item["shortcut"] as? String))
        }
        return RealtimeMenuOffer(
            candidates: rankedCandidates(leaves, words: words),
            enabledItemCount: enabledItemCount,
            privacyDroppedCount: privacyDroppedCount,
            listingIncomplete: !((response["listingStopReasons"] as? [String]) ?? []).isEmpty
        )
    }

    /// Ranked by how many query words the path holds, then how many sit in the
    /// item's own label, then menu order. No match, no candidate: an empty list
    /// is the honest answer to "rainbow text", and the prompt says to say so.
    static func rankedCandidates(_ leaves: [RealtimeMenuCandidate], words: String,
                                 limit: Int = maximumCandidates) -> [RealtimeMenuCandidate] {
        let query = Set(foldedTokens(words)).subtracting(ignoredQueryWords)
        guard !query.isEmpty else { return [] }
        let scored: [(matched: Int, inLabel: Int, index: Int, leaf: RealtimeMenuCandidate)] = leaves.enumerated().compactMap { index, leaf in
            let pathTokens = leaf.path.flatMap(foldedTokens)
            let labelTokens = foldedTokens(leaf.path.last ?? "")
            let matched = query.filter { word in pathTokens.contains { tokensMatch(word, $0) } }.count
            guard matched > 0 else { return nil }
            let inLabel = query.filter { word in labelTokens.contains { tokensMatch(word, $0) } }.count
            return (matched, inLabel, index, leaf)
        }
        return scored.sorted { ($0.matched, $0.inLabel, -$0.index) > ($1.matched, $1.inLabel, -$1.index) }
            .prefix(limit).map(\.leaf)
    }

    // MARK: Notch text

    /// "View › as List": each step shown safe, because the app wrote them.
    static func menuPathCaption(_ path: [String]) -> String {
        path.map(RealtimeOpenAppTool.captionName).joined(separator: " \u{203A} ")
    }

    /// The intent line, from the tool's own arguments — shown before the request.
    static func intentTitle(for call: RealtimeToolCall) -> String {
        let app = call.appName.map(RealtimeOpenAppTool.captionName)
        switch call.name {
        case RealtimeOpenAppTool.name:
            return "Opening \(app ?? "an app")\u{2026}"
        case focusAppName:
            return "Switching to \(app ?? "an app")\u{2026}"
        case findMenuItemsName:
            let words = call.words.map(RealtimeOpenAppTool.captionName) ?? "a command"
            return "Looking for \u{2018}\(words)\u{2019} in \(app ?? "the app")\u{2019}s menus\u{2026}"
        case pressMenuName:
            return "\(menuPathCaption(call.path ?? []))\u{2026}"
        default:
            return "Working\u{2026}"
        }
    }

    /// Only these count as the receipt for completion words: a find is a read.
    static func isActingTool(_ toolName: String) -> Bool {
        toolName != findMenuItemsName
    }
}

nonisolated struct RealtimeMenuCandidate: Equatable, Sendable {
    let path: [String]
    let shortcut: String?

    var jsonObject: [String: Any] { ["path": path, "shortcut": shortcut ?? NSNull()] }
}

nonisolated struct RealtimeMenuOffer: Equatable, Sendable {
    let candidates: [RealtimeMenuCandidate]
    /// Enabled items in the harness's listing, before any filtering.
    let enabledItemCount: Int
    /// Enabled items dropped as private (`isPrivateMenuItem`). Counted, never listed.
    let privacyDroppedCount: Int
    /// The harness's listing hit a limit, so a missing item may simply be unread.
    let listingIncomplete: Bool
}

/// One tool call as the turn saw it: what was asked, what the model had been
/// offered when it asked, and — once the harness answered — the dispatch.
nonisolated struct RealtimeToolDecision {
    let call: RealtimeToolCall
    let callUptime: TimeInterval
    /// The candidates of this turn's latest finished find_menu_items when this
    /// call ARRIVED — the list the model could have chosen from. nil: none yet.
    let offeredBeforeCall: [RealtimeMenuCandidate]?
    var dispatch: RealtimeToolDispatch?
}

// MARK: - Decision trace

/// `~/Library/Logs/Clicky/voice-decisions.log`: one JSON line per tool call, the
/// record an offline replay (a different chooser on the same option lists) reads.
/// Keep the shape stable; add keys, never rename them, and bump `schema` if a
/// key's meaning changes. Every key is always present, null when it does not apply.
///
///   kind "toolCall", schema 1
///   source            "live" | "probe"
///   turnId, stack     the turn (voice-live.log / voice-tool-probe.log share turnId)
///   probeId, fixture  probe only, else null
///   seq               1-based order of the call within its turn
///   tool, args        the call as parsed: {name|app, words, path} — a path with
///                     a Recent step is logged as ["<private>"]
///   callMs            release -> the call arrived
///   harnessMs         request -> final answer (includes any ticket wait)
///   ok, harnessError  the harness's own; verification = its verification status
///                     (focus/menu) or launch's status
///   offered           find_menu_items: the candidate list sent to the model
///                     ([{path, shortcut}], already privacy-filtered)
///   offeredCount, enabledItemCount, privacyDroppedCount, listingIncomplete
///                     find_menu_items (the words the model searched are in args)
///   correctOffered    probe, find_menu_items: was the fixture's expected path
///                     among `offered`? null live or with no expected path
///   choseFromOffered  press_menu: was `args.path` one of the latest `offered`
///                     paths when the call arrived? null if nothing was offered
///   independentCheck  probe: a structure read that does not trust the verb
///                     ({kind, passed, ...}); live: null
nonisolated enum RealtimeDecisionTrace {
    static let fileName = "voice-decisions.log"
    static let schemaVersion = 1
    static let privatePathPlaceholder = ["<private>"]

    static func choseFromOffered(path: [String]?, offered: [RealtimeMenuCandidate]?) -> Bool? {
        guard let offered else { return nil }
        guard let path else { return false }
        return offered.contains { $0.path == path }
    }

    static func loggedArguments(for call: RealtimeToolCall) -> [String: Any] {
        var arguments: [String: Any] = [:]
        if let appName = call.appName {
            arguments[call.name == RealtimeOpenAppTool.name || call.name == RealtimeVoiceVerbs.focusAppName ? "name" : "app"] = appName
        }
        if let words = call.words { arguments["words"] = words }
        if let path = call.path { arguments["path"] = RealtimeVoiceVerbs.isPrivateMenuPath(path) ? privatePathPlaceholder : path }
        return arguments
    }

    static func line(
        decision: RealtimeToolDecision, sequence: Int, turnID: String, stack: String, source: String,
        releasedUptime: TimeInterval?, probeID: String? = nil, fixture: String? = nil,
        expectedPath: [String]? = nil, independentCheck: [String: Any]? = nil
    ) -> [String: Any] {
        func value(_ optional: Any?) -> Any { optional ?? NSNull() }
        let dispatch = decision.dispatch
        let offer = dispatch?.menuOffer
        let isPress = decision.call.name == RealtimeVoiceVerbs.pressMenuName
        return [
            "kind": "toolCall", "schema": schemaVersion, "source": source,
            "turnId": turnID, "stack": stack, "probeId": value(probeID), "fixture": value(fixture),
            "seq": sequence, "tool": decision.call.name, "args": loggedArguments(for: decision.call),
            "callMs": value(releasedUptime.map { Int(((decision.callUptime - $0) * 1000).rounded()) }),
            "harnessMs": value(dispatch?.harnessMilliseconds),
            "ok": value(dispatch.map(\.harnessConfirmed)),
            "harnessError": value(dispatch?.result["error"] as? String),
            "verification": value((dispatch?.result["verification"] as? String) ?? (dispatch?.result["status"] as? String)),
            "offered": value(offer.map { $0.candidates.map(\.jsonObject) }),
            "offeredCount": value(offer?.candidates.count),
            "correctOffered": value(expectedPath.flatMap { expected in offer.map { $0.candidates.contains { $0.path == expected } } }),
            "enabledItemCount": value(offer?.enabledItemCount),
            "privacyDroppedCount": value(offer?.privacyDroppedCount),
            "listingIncomplete": value(offer?.listingIncomplete),
            "choseFromOffered": value(isPress ? choseFromOffered(path: decision.call.path, offered: decision.offeredBeforeCall) : nil),
            "independentCheck": value(independentCheck)
        ]
    }

    /// Appends every decision of one turn, in call order.
    static func append(
        _ decisions: [RealtimeToolDecision], turnID: String, stack: String, source: String,
        releasedUptime: TimeInterval?, probeID: String? = nil, fixture: String? = nil,
        expectedPath: [String]? = nil, independentCheck: [String: Any]? = nil
    ) {
        for (index, decision) in decisions.enumerated() {
            MeasurementLogFile.appendJSONLine(
                line(decision: decision, sequence: index + 1, turnID: turnID, stack: stack, source: source,
                     releasedUptime: releasedUptime, probeID: probeID, fixture: fixture,
                     expectedPath: expectedPath, independentCheck: independentCheck),
                toFileNamed: fileName)
        }
    }
}
