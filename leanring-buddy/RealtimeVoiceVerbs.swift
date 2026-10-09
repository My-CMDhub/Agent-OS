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

import AppKit
import Foundation

nonisolated enum RealtimeVoiceVerbs {
    static let focusAppName = "focus_app"
    static let findMenuItemsName = "find_menu_items"
    static let pressMenuName = "press_menu"
    /// The window's own elements (`RealtimeScreenVerbs`, 2026-09-30; slice 1b).
    static let findOnScreenName = "find_on_screen"
    static let pointAtName = "point_at"
    static let pressElementName = "press_element"
    /// The hands (`RealtimeHandsVerbs`, owner's target level 2026-10-01).
    static let scrollName = "scroll"
    static let typeTextName = "type_text"
    static let closeName = "close"
    /// A web page in a browser (hands design item 7; live 2026-10-02: "no open-URL tool", rows 13, 14, 29).
    static let openURLName = "open_url"
    /// A multi-step request handed to the agent loop (`AgentLoop`, spec 2026-10-03): returns at once.
    static let doTaskName = "do_task"
    /// Shapes drawn round named elements while explaining (`RealtimeAnnotate`, owner 2026-10-05).
    static let annotateName = "annotate"
    static let allToolNames: Set<String> = [RealtimeOpenAppTool.name, focusAppName, findMenuItemsName, pressMenuName,
                                            findOnScreenName, pointAtName, pressElementName, scrollName, typeTextName, closeName,
                                            openURLName, doTaskName, annotateName]

    /// Read-only: they look or point and change nothing in any app, so they skip
    /// the heard-vs-named check (live 2026-09-30: four turns lost to "settings"
    /// on reads) and default to the app in front when the call names none.
    static let readOnlyToolNames: Set<String> = [findMenuItemsName, findOnScreenName, pointAtName, annotateName]

    /// The tools that aim at an element on screen, by name, position or pointer.
    static func isScreenTargetTool(_ toolName: String) -> Bool {
        toolName == pointAtName || toolName == pressElementName
    }

    /// Tools that take an element's name, a screenshot position or the
    /// owner's pointer: point_at and press_element must have one; scroll and
    /// type_text may leave it out (the main area, the focused field).
    static func aimsAtScreen(_ toolName: String) -> Bool {
        isScreenTargetTool(toolName) || toolName == scrollName || toolName == typeTextName
    }

    /// Tools whose app may be omitted: the app in front is meant.
    static func takesFrontmostApp(_ toolName: String) -> Bool {
        readOnlyToolNames.contains(toolName) || [pressElementName, scrollName, typeTextName, closeName].contains(toolName)
    }

    /// Enough to hold every View-menu toggle of a native app and short enough
    /// that a chooser reads the list, not skims it.
    static let maximumCandidates = 12

    // MARK: Declarations

    private indirect enum Kind { case text, list, number, flag, numberList, objectList([Parameter]) }

    private struct Parameter {
        let name: String
        var kind: Kind = .text
        var required = true
        let description: String
        /// A text parameter's only values, declared as the schema's `enum`.
        var options: [String] = []
    }

    private struct Declaration {
        let name: String
        let description: String
        let parameters: [Parameter]
    }

    private static let appInFront = Parameter(name: "app", required: false,
                                              description: "The app in front, for example \"Cursor\". Leave it out to mean the app in front.")
    /// How a position in the screenshot is asked for (`RealtimePointFormat`).
    private static func positionParameters(_ format: RealtimePointFormat, gemini: Bool) -> [Parameter] {
        // Scenario A8 2026-10-03: Gemini sent "rso > div:nth-child(1) > … .LC20lb" as the name.
        let name = Parameter(name: "name", required: false, description: "The element's name exactly as find_on_screen returned it, "
                                + "or as printed on screen; never a CSS selector or code.")
        // Live 2026-10-02 (rows 2, 19): the model sent underPointer for "let's point it" and "in Google Chrome".
        let underPointer = Parameter(name: "underPointer", kind: .flag, required: false,
                                     description: "Only when the owner says \"this one\", \"here\" or \"where my cursor is\": true for the "
                                        + "element under their mouse pointer. Otherwise leave it out and aim by name; it is refused unless they said so. "
                                        + "A request that names the thing (\"click sign in\", \"where is the phone number\") is never underPointer.")
        switch (format, gemini) {
        case (.fractions, _):
            return [name,
                    Parameter(name: "x", kind: .number, required: false,
                              description: "Where it is in the screenshot you were given this turn, across, as a fraction from 0 (left edge) to 1 (right edge)."),
                    Parameter(name: "y", kind: .number, required: false,
                              description: "Where it is in that screenshot, down, as a fraction from 0 (top edge) to 1 (bottom edge)."),
                    underPointer]
        case (.native, true):
            // Gemini's trained pointing format: a [y, x] point normalised to 0-1000.
            return [name,
                    Parameter(name: "point", kind: .numberList, required: false,
                              description: "Where it is in the screenshot you were given this turn, as [y, x], each normalized to 0-1000 "
                                + "(0,0 is the top-left of the image, 1000,1000 the bottom-right)."),
                    underPointer]
        case (.native, false):
            // OpenAI's: pixels of the image it was shown.
            return [name,
                    Parameter(name: "x", kind: .number, required: false,
                              description: "Where it is in the screenshot you were given this turn, across, in pixels from its left edge "
                                + "(its size in pixels is given in a system line)."),
                    Parameter(name: "y", kind: .number, required: false,
                              description: "Where it is in that screenshot, down, in pixels from its top edge."),
                    underPointer]
        }
    }

    /// `agent`: the agent loop's table, whose press_menu also takes a shortcut
    /// from the App verbs (`AffordanceMap`); a voice turn has no map.
    private static func declarations(_ format: RealtimePointFormat, gemini: Bool, agent: Bool = false) -> [Declaration] {
        let positionParameters = positionParameters(format, gemini: gemini)
        let pressMenu = agent
            ? Declaration(name: pressMenuName,
                          description: "Presses one menu item of the app in front: a path from the App verbs or from find_menu_items, copied "
                            + "exactly, or the shortcut an App verbs line shows, which presses the item that owns it (never a keystroke).",
                          parameters: [
                            Parameter(name: "app", description: "The app in front, for example \"Finder\"."),
                            Parameter(name: "path", kind: .list, required: false,
                                      description: "The menu path, split at \" > \", for example [\"View\", \"as List\"]."),
                            Parameter(name: "shortcut", required: false,
                                      description: "Instead of a path: the shortcut as an App verbs line shows it, for example \"⌘2\".")
                          ])
            : Declaration(name: pressMenuName,
                          description: "Presses one menu item of the app in front. The path must be one that find_menu_items returned in this turn, copied exactly.",
                          parameters: [
                            Parameter(name: "app", description: "The app in front, for example \"Finder\"."),
                            Parameter(name: "path", kind: .list, description: "The menu path exactly as find_menu_items returned it, for example [\"View\", \"as List\"].")
                          ])
        return [
        Declaration(name: focusAppName,
                    description: "Brings an app that is already running to the front. Use its name as shown in the Dock, for example \"Finder\".",
                    parameters: [Parameter(name: "name", description: "The running app's name, for example \"Finder\".")]),
        Declaration(name: findMenuItemsName,
                    description: "Looks through the menu bar of the app in front for items matching a few words, and returns up to "
                        + "\(maximumCandidates) exact menu paths that can be pressed. Changes nothing.",
                    parameters: [
                        Parameter(name: "app", required: false, description: "The app whose menus to search, for example \"Finder\". Leave it out to mean the app in front."),
                        Parameter(name: "words", description: "A few words for the command, for example \"list view\" or \"new window\".")
                    ]),
        pressMenu,
        Declaration(name: findOnScreenName,
                    description: "Looks through the window of the app in front for what the owner can see there — buttons, tabs, rows, links, labels, "
                        + "text — matching a few words, and returns up to \(RealtimeScreenVerbs.maximumScreenCandidates), each with its exact name, what "
                        + "kind it is and where it is. Changes nothing. Use the words printed on screen, for example \"models\" or \"new agent\".",
                    parameters: [
                        Parameter(name: "app", required: false, description: "The app whose window to search. Leave it out to mean the app in front."),
                        Parameter(name: "words", description: "A few words for the element, as printed on screen, for example \"models\".")
                    ]),
        Declaration(name: pointAtName,
                    description: "Moves the on-screen pointer to one element and highlights it, so the owner can see it. Changes nothing. Give its "
                        + "name as find_on_screen returned it, OR its position in the screenshot as x and y fractions, OR underPointer. The result "
                        + "says what was actually pointed at and where; say that. If it says approximate, say it is approximate.",
                    parameters: [appInFront] + positionParameters),
        Declaration(name: pressElementName,
                    description: "Presses (clicks) one element in the window of the app in front. Aim it exactly as point_at: a name find_on_screen "
                        + "returned, OR x and y fractions of the screenshot, OR underPointer. Safety checks run first; a destructive press shows the "
                        + "owner a card to approve, and some things are refused. The result says what was pressed and whether it was verified. "
                        + "Something visible that find_on_screen does not list (drawn on a canvas, a picture-only icon) is pressed by sight: give "
                        + "its x and y AND the words printed on it; it is clicked only where those words are read back.",
                    parameters: [appInFront] + positionParameters),
        Declaration(name: scrollName,
                    description: "Scrolls the window of the app in front, as a trackpad would. Aim it at an area by a name find_on_screen "
                        + "returned, x and y fractions of the screenshot, or underPointer; leave them out for the window's main area. The "
                        + "result says whether anything moved and names what came into view.",
                    parameters: [appInFront,
                                 Parameter(name: "direction", description: "Which way the content moves into view.",
                                           options: ScrollDirection.allCases.map(\.rawValue)),
                                 Parameter(name: "amount", kind: .number, required: false,
                                           description: "How far, in pages (screens). Default 1.")] + positionParameters),
        Declaration(name: typeTextName,
                    description: "Types text into a field of the app in front, as if from the keyboard. Never presses Enter or sends anything. "
                        + "Aim it by the field's name: the words printed in or beside it, for example \"Search\", looked up on screen. "
                        + "A position only for a field with no words; leave the aim out only for a field "
                        + "you know has keyboard focus — on a web page usually none has. Password fields are "
                        + "refused; replacing text already in a field asks the owner on a card.",
                    parameters: [appInFront,
                                 Parameter(name: "text", description: "Exactly the text to type, as the owner gave it."),
                                 Parameter(name: "mode", required: false,
                                           description: "insert (default) adds at the end of what is there; replace swaps the whole field.",
                                           options: TypeMode.allCases.map(\.rawValue))] + positionParameters),
        Declaration(name: openURLName,
                    description: "Opens a web page in a browser: the one named, or the default browser. Use it for a website "
                        + "(\"open LinkedIn in Chrome\" is https://www.linkedin.com/ in Google Chrome); open_app is for installed apps. "
                        + "The owner's words must name the site.",
                    parameters: [Parameter(name: "url", description: "The full http or https address, for example \"https://www.linkedin.com/\"."),
                                 Parameter(name: "app", required: false,
                                           description: "The browser, for example \"Google Chrome\". Leave it out for the default browser.")]),
        Declaration(name: annotateName,
                    description: "Draws on the owner's screen, while you explain, to show where things are: a box, circle, arrow, "
                        + "underline or short label round elements of the window in front, each named exactly as point_at names it (as "
                        + "printed on screen), or round the owner's pointer. Changes nothing in any app; the drawing clears after a few "
                        + "seconds or at the owner's next press. At most \(RealtimeAnnotate.maximumShapes) shapes. The result says what was drawn.",
                    parameters: [appInFront,
                                 Parameter(name: "shapes", kind: .objectList([
                                    Parameter(name: "shape", description: "What to draw.", options: RealtimeAnnotate.kinds),
                                    Parameter(name: "name", required: false, description: "The element's name exactly as printed on screen."),
                                    Parameter(name: "underPointer", kind: .flag, required: false,
                                              description: "true to draw round what is under the owner's mouse pointer instead of a name."),
                                    Parameter(name: "text", required: false,
                                              description: "A short caption beside it, at most \(RealtimeAnnotate.maximumLabelLength) characters; "
                                                + "needed for a label.")
                                 ]), description: "The shapes, in the order to draw them.")]),
        Declaration(name: closeName,
                    description: "Closes the tab or the window in front, or quits the app in front, through the app's own menu. Quitting "
                        + "shows the owner a card first; the app may still ask to save, and that answer is the owner's.",
                    parameters: [Parameter(name: "what", description: "tab, window, or app (quit it).", options: RealtimeHandsVerbs.closeTargets),
                                 appInFront])
        ]
    }

    /// The voice model's only planner hand-off. Never offered to the agent loop itself.
    private static let doTaskDeclaration = Declaration(
        name: doTaskName,
        description: "Hands a request that needs more than one step (search then open a result, open a page and read or summarise it, "
            + "fill several fields, write then post) to the task runner, which looks, acts, checks and repeats until it is done. "
            + "Use it for every request with two or more actions, and for any that acts and then asks for an answer (\"and tell me\", "
            + "summarise, find out): never do the first action yourself. Also every question to look up on the web (\"what does "
            + "this site say\", \"the latest\", \"the cheapest\"): it answers from the web without opening a browser. "
            + "Returns at once with status started; progress and the outcome arrive later as system lines.",
        parameters: [Parameter(name: "goal", description: "The owner's whole request, in their words, with any detail they gave.")])

    /// The realtime stacks' list: the shared table plus do_task.
    private static func realtimeDeclarations(_ format: RealtimePointFormat, gemini: Bool) -> [Declaration] {
        declarations(format, gemini: gemini) + [doTaskDeclaration]
    }

    /// The agent loop's tools as Anthropic Messages API tool JSON: open_app and the
    /// same table the voice model has (screen positions as fractions of the step's
    /// screenshot), never do_task. `extra`: the loop's own tools, already in that shape.
    static func anthropicDeclarations(extra: [[String: Any]] = []) -> [[String: Any]] {
        let openApp: [String: Any] = [
            "name": RealtimeOpenAppTool.name, "description": RealtimeOpenAppTool.toolDescription,
            "input_schema": ["type": "object",
                             "properties": ["name": ["type": "string", "description": RealtimeOpenAppTool.argumentDescription]],
                             "required": ["name"]] as [String: Any]
        ]
        return [openApp] + declarations(.fractions, gemini: false, agent: true).map { declaration in
            [
                "name": declaration.name, "description": declaration.description,
                "input_schema": [
                    "type": "object",
                    "properties": Dictionary(uniqueKeysWithValues: declaration.parameters.map { ($0.name, property($0, gemini: false)) }),
                    "required": declaration.parameters.filter(\.required).map(\.name)
                ] as [String: Any]
            ]
        } + extra
    }

    private static func property(_ parameter: Parameter, gemini: Bool) -> [String: Any] {
        func type(_ name: String) -> String { gemini ? name.uppercased() : name }
        switch parameter.kind {
        case .list: return ["type": type("array"), "items": ["type": type("string")], "description": parameter.description]
        case .numberList: return ["type": type("array"), "items": ["type": type("number")], "description": parameter.description]
        case .objectList(let fields):
            return ["type": type("array"), "description": parameter.description, "items": [
                "type": type("object"),
                "properties": Dictionary(uniqueKeysWithValues: fields.map { ($0.name, property($0, gemini: gemini)) }),
                "required": fields.filter(\.required).map(\.name)
            ] as [String: Any]]
        case .number: return ["type": type("number"), "description": parameter.description]
        case .flag: return ["type": type("boolean"), "description": parameter.description]
        case .text:
            guard !parameter.options.isEmpty else { return ["type": type("string"), "description": parameter.description] }
            return ["type": type("string"), "description": parameter.description, "enum": parameter.options]
        }
    }

    /// OpenAI Realtime GA `session.tools`: open_app first, then these.
    static var openAIDeclarations: [[String: Any]] { openAIDeclarations(pointFormat: .live) }

    static func openAIDeclarations(pointFormat: RealtimePointFormat) -> [[String: Any]] {
        [RealtimeOpenAppTool.openAIDeclaration] + realtimeDeclarations(pointFormat, gemini: false).map { declaration in
            [
                "type": "function", "name": declaration.name, "description": declaration.description,
                "parameters": [
                    "type": "object",
                    "properties": Dictionary(uniqueKeysWithValues: declaration.parameters.map { ($0.name, property($0, gemini: false)) }),
                    "required": declaration.parameters.filter(\.required).map(\.name)
                ] as [String: Any]
            ]
        }
    }

    /// Gemini Live `setup.tools` entry: one object holding every function.
    static var geminiDeclaration: [String: Any] { geminiDeclaration(pointFormat: .live) }

    static func geminiDeclaration(pointFormat: RealtimePointFormat) -> [String: Any] {
        let openApp = (RealtimeOpenAppTool.geminiDeclaration["functionDeclarations"] as? [[String: Any]]) ?? []
        return ["functionDeclarations": openApp + realtimeDeclarations(pointFormat, gemini: true).map { declaration in
            [
                "name": declaration.name, "description": declaration.description,
                "parameters": [
                    "type": "OBJECT",
                    "properties": Dictionary(uniqueKeysWithValues: declaration.parameters.map { ($0.name, property($0, gemini: true)) }),
                    "required": declaration.parameters.filter(\.required).map(\.name)
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
        return path.contains { step in quotesSomething(step) || foldedTokens(step).contains { $0.hasPrefix("recent") } }
    }

    /// Finder names the selection INSIDE the command: Copy “<file>” as Pathname,
    /// Open “<file>”, Compress “<file>”, Get Info on “<file>”. Found in the Jev
    /// replay (2026-09-25): 24 trace entries carried a file name, and each had
    /// gone to the model too. A quote mark in any step makes the item private;
    /// a lone ’ does not — it is the apostrophe in "Don’t Save". 「」『』 are
    /// the Japanese and Chinese quotes (review, 2026-09-25).
    static let quoteMarks: Set<Character> = ["\u{201C}", "\u{201D}", "\u{201E}", "\"", "\u{2018}", "\u{00AB}", "\u{00BB}", "\u{2039}", "\u{203A}",
                                             "\u{300C}", "\u{300D}", "\u{300E}", "\u{300F}"]

    static func quotesSomething(_ label: String) -> Bool {
        label.contains { quoteMarks.contains($0) }
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

    // MARK: App identity

    /// find_menu_items and press_menu run only against the app the tool NAMED,
    /// resolved to one installed bundle. Measured 2026-09-25 (Jev replay): with
    /// VS Code's menus offered for "new window in cursor", Jev and Haiku both
    /// chose File › New Window at 0.92-0.99 — no confidence threshold catches the
    /// right command in the wrong app, so the app is checked before any chooser.
    /// The screen pair is scoped the same way (2026-09-30): a control is read
    /// and pointed at only in the app the call named.
    static func isAppScopedMenuTool(_ toolName: String) -> Bool {
        [findMenuItemsName, pressMenuName, findOnScreenName, pointAtName, pressElementName, scrollName, typeTextName, closeName,
         annotateName].contains(toolName)
    }

    /// One name an app answers to: its file name in an Applications folder, or
    /// (`isFileName` false) the shorter name it shows in the menu bar while it
    /// runs — "Code" for Visual Studio Code. A running app found in no
    /// Applications folder (Finder) is named by its menu-bar name alone.
    struct AppName: Equatable {
        let name: String
        let url: URL
        let isFileName: Bool
    }

    enum AppResolution: Equatable {
        case resolved(URL)
        /// Two or more installed apps answer to the name: ask, never guess.
        case ambiguous([URL])
        /// None does; `closest` share a word with the name (at most five).
        case notInstalled(closest: [URL])
    }

    /// A full file name is that app even when its words appear elsewhere
    /// ("Visual Studio Code", "Finder"). Anything shorter — a menu-bar name or
    /// the words of a longer name ("Code", "Chrome") — resolves only if exactly
    /// one app answers to it: "code" is VS Code's menu-bar name AND a word of
    /// "Claude Code URL Handler", so it is asked about. Words, never letters:
    /// "code" does not find Xcode. ponytail: no sound-alike matching ("Kasa" for
    /// Cursor is not installed, and says so); that is its own owner decision.
    static func resolveApp(named query: String, among names: [AppName]) -> AppResolution {
        let wanted = foldedTokens(query)
        guard !wanted.isEmpty else { return .notInstalled(closest: []) }
        func unique(_ matches: [AppName]) -> [URL] {
            var seen = Set<String>()
            return matches.map(\.url).filter { seen.insert($0.standardizedFileURL.path).inserted }
        }
        let fullName = unique(names.filter { $0.isFileName && foldedTokens($0.name) == wanted })
        if fullName.count == 1 { return .resolved(fullName[0]) }
        if fullName.count > 1 { return .ambiguous(fullName) }
        let partial = unique(names.filter { name in
            let tokens = foldedTokens(name.name)
            return tokens.count >= wanted.count
                && (0...(tokens.count - wanted.count)).contains { Array(tokens[$0..<($0 + wanted.count)]) == wanted }
        })
        if partial.count == 1 { return .resolved(partial[0]) }
        if partial.count > 1 { return .ambiguous(partial) }
        let closest = unique(names.filter { name in
            let tokens = Set(foldedTokens(name.name))
            return wanted.contains { $0.count >= 3 && tokens.contains($0) }
        })
        return .notInstalled(closest: Array(closest.prefix(5)))
    }

    /// The name an app is shown by: its bundle's file name.
    static func displayName(_ url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }

    /// Every name an installed or running regular app answers to: the launch
    /// verb's Applications folders plus running regular apps. File names only —
    /// no Info.plist is read until one app is chosen.
    static func installedAppNames() -> [AppName] {
        var names = ApplicationLauncher.searchDirectories.flatMap { directory in
            ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
                .filter { $0.lowercased().hasSuffix(".app") }
                .map { file -> AppName in
                    let url = directory.appendingPathComponent(file, isDirectory: true)
                    return AppName(name: displayName(url), url: url, isFileName: true)
                }
        }
        let installedPaths = Set(names.map { $0.url.standardizedFileURL.path })
        for application in NSWorkspace.shared.runningApplications where application.activationPolicy == .regular {
            guard let name = application.localizedName, let url = application.bundleURL else { continue }
            names.append(AppName(name: name, url: url, isFileName: !installedPaths.contains(url.standardizedFileURL.path)))
        }
        return names
    }

    enum AppIdentity: Equatable {
        case resolved(bundleIdentifier: String, name: String)
        case ambiguous(candidates: [String])
        case notInstalled(closest: [String])
    }

    /// A bundle identifier names its app outright; anything else goes through
    /// `resolveApp`. Blocks on the file system: call it off main.
    static func appIdentity(named query: String) -> AppIdentity {
        let resolution: AppResolution
        if query.contains("."), !query.contains(" "), let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: query) {
            resolution = .resolved(url)
        } else {
            resolution = resolveApp(named: query, among: installedAppNames())
        }
        switch resolution {
        case .resolved(let url):
            guard let bundleIdentifier = Bundle(url: url)?.bundleIdentifier else { return .notInstalled(closest: []) }
            return .resolved(bundleIdentifier: bundleIdentifier, name: displayName(url))
        case .ambiguous(let urls):
            return .ambiguous(candidates: urls.map(displayName))
        case .notInstalled(let closest):
            return .notInstalled(closest: closest.map(displayName))
        }
    }

    /// A name that resolves to exactly one installed app, which is running.
    /// Blocks on the file system: call it off main.
    static func isRunning(named query: String) -> Bool {
        guard case .resolved(let bundleIdentifier, _) = appIdentity(named: query) else { return false }
        return !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
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
        case findOnScreenName:
            let words = call.words.map(RealtimeOpenAppTool.captionName) ?? "a control"
            return "Looking for \u{2018}\(words)\u{2019} in \(app ?? "the app")\u{2026}"
        case pointAtName:
            return "Finding \(call.elementName.map(RealtimeOpenAppTool.captionName) ?? "it")\u{2026}"
        case pressElementName:
            return "Pressing \(call.elementName.map(RealtimeOpenAppTool.captionName) ?? "it")\u{2026}"
        case scrollName:
            let way = call.direction.flatMap(ScrollDirection.init(rawValue:)).map { " \($0.rawValue)" } ?? ""
            return "Scrolling\(way)\u{2026}"
        case typeTextName:
            return "Typing\u{2026}"
        case openURLName:
            return "Opening \(call.url.flatMap { URL(string: $0)?.host }.map(RealtimeOpenAppTool.captionName) ?? "the page")\u{2026}"
        case annotateName:
            return "Showing you\u{2026}"
        case closeName:
            switch call.what {
            case "tab": return "Closing the tab\u{2026}"
            case "window": return "Closing the window\u{2026}"
            default: return "Quitting \(app ?? "the app")\u{2026}"
            }
        default:
            return "Working\u{2026}"
        }
    }

    /// Only these count as the receipt for completion words: a find is a read.
    /// do_task only starts the loop: its "started" is no receipt for "done".
    static func isActingTool(_ toolName: String) -> Bool {
        toolName != findMenuItemsName && toolName != findOnScreenName && toolName != doTaskName && toolName != annotateName
    }
}

/// How a realtime model gives a position in the screenshot. F1 `fractions`
/// (live since 2026-09-30): x, y from 0 to 1 on both stacks. F2 `native`: the
/// format each was trained on — Gemini a [y, x] point normalised to 0-1000
/// (its computer-use and detection outputs), OpenAI pixels of the image.
/// Either way the call becomes fractions here, and the local snap is unchanged.
/// `--point-format-probe` measures which aims better; `live` is the switch.
nonisolated enum RealtimePointFormat: String, CaseIterable, Sendable {
    case fractions
    case native

    static let live: RealtimePointFormat = .fractions

    /// The call with x, y as fractions of the screenshot; a position that
    /// cannot be read (pixels with no known image size, a point that is not
    /// two numbers) is dropped, never guessed.
    static func normalised(_ call: RealtimeToolCall, format: RealtimePointFormat, stack: VoiceStackChoice,
                           screenshotPixels: CGSize?) -> RealtimeToolCall {
        guard format == .native, RealtimeVoiceVerbs.aimsAtScreen(call.name) else { return call }
        var normalised = call
        switch stack {
        case .geminiLive:
            normalised.x = nil
            normalised.y = nil
            if let point = call.point, point.count == 2 {
                normalised.x = point[1] / 1000
                normalised.y = point[0] / 1000
            }
        case .openAIRealtime:
            guard let x = call.x, let y = call.y, let size = screenshotPixels, size.width > 0, size.height > 0 else {
                normalised.x = nil
                normalised.y = nil
                break
            }
            normalised.x = x / Double(size.width)
            normalised.y = y / Double(size.height)
        }
        return normalised
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

/// A turn's latest finished find: its candidates, the bundle that find
/// resolved to, and when it finished — what a press or a point is judged
/// against. A find_menu_items offer holds `candidates`, a find_on_screen offer
/// `elements`; each kind of find replaces only its own kind.
nonisolated struct RealtimeStandingOffer: Sendable {
    let candidates: [RealtimeMenuCandidate]
    let app: String?
    let uptime: TimeInterval
    var elements: [RealtimeScreenCandidate] = []
}

/// One tool call as the turn saw it: what was asked, what the model had been
/// offered when it asked, and — once the harness answered — the dispatch.
nonisolated struct RealtimeToolDecision {
    let call: RealtimeToolCall
    let callUptime: TimeInterval
    /// The candidates the notOffered gate judged this call against, set when it
    /// was DISPATCHED (after the calls before it finished): this turn's latest
    /// find, or the previous turn's when `offerSource` says so. Set to the
    /// arrival-time offer until then. nil: none.
    var offeredBeforeCall: [RealtimeMenuCandidate]?
    var dispatch: RealtimeToolDispatch?
    /// press_menu or point_at that passed the notOffered gate: whose offer let it through.
    var offerSource: RealtimeOpenAppTool.OfferSource? = nil
    /// point_at's `offeredBeforeCall`: the controls it was judged against.
    var offeredElementsBeforeCall: [RealtimeScreenCandidate]? = nil
    /// point_at / press_element: which rung named the target (trace `snappedBy`).
    var snappedBy: String? = nil
}

// MARK: - Decision trace

/// `~/Library/Logs/Clicky/voice-decisions.log`: one JSON line per tool call, the
/// record an offline replay (a different chooser on the same option lists) reads.
/// Keep the shape stable; add keys, never rename them, and bump `schema` if a
/// key's meaning changes. Every key is always present, null when it does not apply.
///
///   kind "toolCall", schema 6 (2026-09-25: `appCheck` added in 2, `heardCheck`
///   in 3, `autoFocus` in 4; earlier lines simply lack them, and every other key
///   means what it did — except that from 4 a menu call's ok/harnessError/
///   appCheck are those of its auto-focus RE-RUN when `autoFocus.retried`, from
///   5 `choseFromOffered` is judged at dispatch, not arrival, and from 6 against
///   the previous turn's offer when `offerSource` says so)
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
///   choseFromOffered  press_menu: was `args.path` one of the `offered` paths the
///                     gate used, when dispatched? null if nothing was offered.
///                     Schema 5 (2026-09-29): before, judged at call ARRIVAL, so
///                     a find and a press in one batch read null or false.
///                     Schema 6 (2026-09-30): the gate's offer may be the
///                     previous turn's (`offerSource`)
///   independentCheck  probe: a structure read that does not trust the verb
///                     ({kind, passed, ...}); live: null
///   appCheck          find_menu_items / press_menu: {outcome, named,
///                     resolvedBundleId, frontmostBundleId}; outcome is match |
///                     appMismatch | ambiguousApp | appNotInstalled | notChecked.
///                     null for other tools and for calls refused before it ran
///   heardCheck        every app-naming tool: {outcome, heardApps, tier, named,
///                     transcriptArrivalMs, waitedMs}; outcome is match |
///                     heardNamedMismatch | ambiguousApp | noAppHeard |
///                     transcriptMissing | unconfirmedRetry | appNameUnclear.
///                     heardApps are display names from the file system.
///                     refused: the call got this check's refusal and never ran.
///                     heardSlot, refused (added 2026-09-25, absent before). heardSlot: app-slot
///                     words that are not ordinary English or that name or
///                     sound like an app — never the rest of the sentence
///   autoFocus         find_menu_items / press_menu that came back appMismatch,
///                     else null: {triggered, reason, focusStatus, focusMs,
///                     retried}. reason: witnessesAgree | heard:<outcome> |
///                     tier:<tier> | unresolved | notRunning
///                     (`RealtimeHeardCheck.autoFocusGate`); focusStatus: the
///                     focus's verification, or its error; retried: the call ran
///                     once more after a confirmed focus
///   heardOverlapsLabel press_menu (added 2026-09-29, absent before): did the
///                     owner's heard transcript share a non-filler word with the
///                     pressed item's label? null with no transcript. Measurement
///                     only; the previous-turn gate uses the stricter
///                     `followUpConfirmed` (not logged; `offerSource` is its outcome)
///   offerSource       press_menu that passed the notOffered gate (added
///                     2026-09-30, schema 6): thisTurn | previousTurnConfirmedByWords
///                     (`RealtimeOpenAppTool.pressOffer`). null when refused
///                     notOffered, stopped before the gate, or not a press.
///                     Schema 7: also point_at, and previousTurnConfirmedByYes
///                     (`confirmedByPlainYes`)
///   Schema 7 (2026-09-30): find_on_screen fills offered ([{name, role, where}]),
///                     offeredCount, privacyDroppedCount and listingIncomplete
///                     (enabledItemCount stays menus-only, null); point_at's args
///                     are {app, name} and its choseFromOffered is judged against
///                     the controls offered
///   Schema 8 (2026-09-30, slice 1b): find_on_screen offers every named VISIBLE
///                     element (any role); point_at and press_element args add
///                     x, y (screenshot fractions) and underPointer; their
///                     offerSource adds screenshotPoint | underPointer
///   Schema 10 (2026-10-01): scroll / type_text / close; args add direction,
///                     amount, mode, what and textLength (never the text)
///   Schema 11 (2026-10-02, hands H2): open_url, args add urlHost (never the
///                     path or query); point_at / press_element / type_text by a
///                     name no offer holds resolve on the live screen, offerSource
///                     liveName
///   Schema 9 (2026-09-30 review): snappedBy — point_at / press_element, which
///                     rung named the target: thisTurn | previousTurn… |
///                     underPointer (the offer or the key-down pointer), walk |
///                     ax (a screenshot position), none (nothing there); else null
nonisolated enum RealtimeDecisionTrace {
    static let fileName = "voice-decisions.log"
    static let schemaVersion = 11
    static let privatePathPlaceholder = ["<private>"]

    static func choseFromOffered(path: [String]?, offered: [RealtimeMenuCandidate]?) -> Bool? {
        guard let offered else { return nil }
        guard let path else { return false }
        return offered.contains { $0.path == path }
    }

    /// press_menu, counts-only: does the owner's own transcript share a word
    /// (not a filler word) with the pressed item's label? nil with no
    /// transcript. Only this boolean is logged, never the words.
    static func heardOverlapsLabel(heard: String?, path: [String]?) -> Bool? {
        guard let heard, !heard.allSatisfy(\.isWhitespace) else { return nil }
        let spoken = Set(RealtimeVoiceVerbs.foldedTokens(heard)).subtracting(RealtimeVoiceVerbs.ignoredQueryWords)
        let label = Set(RealtimeVoiceVerbs.foldedTokens(path?.last ?? "")).subtracting(RealtimeVoiceVerbs.ignoredQueryWords)
        return spoken.contains { word in label.contains { RealtimeVoiceVerbs.tokensMatch(word, $0) } }
    }

    /// Words that turn a mention into a "no" or a question (review 2026-09-30:
    /// "no, not the side bar" shared "side" with "Secondary Side Bar").
    static let followUpVetoWords: Set<String> = ["no", "not", "don", "dont", "never", "cancel", "stop", "wait", "nevermind", "none", "neither",
                                                 "what", "which", "why", "how", "difference"]

    /// The previous-turn press gate (`RealtimeOpenAppTool.pressOffer`): strictly
    /// stronger than `heardOverlapsLabel`, which stays a counts-only measurement.
    /// A yes that names the item: no veto word, not a question (no "?" at the
    /// end), and a label word of 4+ letters said in full or by a 4+ letter
    /// prefix ("not" never finds "Note", "can" never "Cancel"). nil with no
    /// transcript. Precision over recall: a miss only means "search again".
    static func followUpConfirmed(heard: String?, path: [String]?) -> Bool? {
        guard let heard, !heard.allSatisfy(\.isWhitespace) else { return nil }
        let spoken = RealtimeVoiceVerbs.foldedTokens(heard)
        guard !spoken.contains(where: followUpVetoWords.contains),
              !heard.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?") else { return false }
        let label = RealtimeVoiceVerbs.foldedTokens(path?.last ?? "").filter { $0.count >= 4 }
        return spoken.contains { word in label.contains { labelWordMatches(spoken: word, label: $0) } }
    }

    /// Said in full, or by a 4+ letter prefix either way ("symbols" / "symbol").
    static func labelWordMatches(spoken: String, label: String) -> Bool {
        spoken == label || (min(spoken.count, label.count) >= 4 && (spoken.hasPrefix(label) || label.hasPrefix(spoken)))
    }

    /// How a plain yes starts (live 2026-09-30: "Yes, to"). Not "please": it
    /// opens requests ("please open Safari") as often as agreements.
    static let plainYesOpeners: [[String]] = [["yes"], ["yeah"], ["yep"], ["sure"], ["ok"], ["okay"], ["go", "ahead"], ["do", "it"]]
    /// A yes is the opener and at most this many words ("Yes, to"; "go ahead please").
    static let plainYesMaximumTrailingWords = 2
    /// Hedges that ride on an opener (review 2026-09-30): "yeah nah", "okay, hang on", "sure, skip it".
    static let plainYesVetoWords: Set<String> = followUpVetoWords.union(["nah", "nope", "hang", "hold", "skip", "later", "actually", "instead"])

    /// The plain-"yes" follow-up: the owner's reply is a bare affirmative (no
    /// veto word, not a question) AND the previous answer, as spoken, named
    /// exactly ONE of the previous offer's items — every 4+ letter word of its
    /// label — and that item is `label`. Live 2026-09-30: "You could try adding
    /// a symbol to a new chat, sir… May I press that?" / "Yes, to" named Add
    /// Symbol to New Chat and not Add Symbol to Current Chat. `offeredLabels`
    /// keeps duplicates: two "Zoom"s are two items, and a yes to one is a yes to
    /// neither. Precision over recall: a miss only means the owner says the name.
    static func confirmedByPlainYes(heard: String?, previousSaid: String?, offeredLabels: [String], label: String?) -> Bool {
        guard let heard, let previousSaid, let label else { return false }
        let spoken = RealtimeVoiceVerbs.foldedTokens(heard)
        guard !spoken.contains(where: plainYesVetoWords.contains),
              !heard.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?"),
              let opener = plainYesOpeners.first(where: { spoken.starts(with: $0) }),
              spoken.count - opener.count <= plainYesMaximumTrailingWords else { return false }
        let said = RealtimeVoiceVerbs.foldedTokens(previousSaid)
        let named = offeredLabels.filter { offered in
            let words = RealtimeVoiceVerbs.foldedTokens(offered).filter { $0.count >= 4 }
            return !words.isEmpty && words.allSatisfy { word in said.contains { labelWordMatches(spoken: $0, label: word) } }
        }
        return named == [label]
    }

    static func loggedArguments(for call: RealtimeToolCall) -> [String: Any] {
        var arguments: [String: Any] = [:]
        if let appName = call.appName {
            arguments[call.name == RealtimeOpenAppTool.name || call.name == RealtimeVoiceVerbs.focusAppName ? "name" : "app"] = appName
        }
        if let words = call.words { arguments["words"] = words }
        if let elementName = call.elementName {
            arguments["name"] = RealtimeScreenVerbs.isPrivateName(elementName) ? privatePathPlaceholder[0] : elementName
        }
        if let x = call.x { arguments["x"] = x }
        if let y = call.y { arguments["y"] = y }
        if call.underPointer { arguments["underPointer"] = true }
        if let path = call.path { arguments["path"] = RealtimeVoiceVerbs.isPrivateMenuPath(path) ? privatePathPlaceholder : path }
        if let shortcut = call.shortcut { arguments["shortcut"] = shortcut }
        if let direction = call.direction { arguments["direction"] = direction }
        if let amount = call.amount { arguments["amount"] = amount }
        // The text is the owner's: its length only, never the words.
        if let text = call.text { arguments["textLength"] = text.count }
        if let mode = call.mode { arguments["mode"] = mode }
        if let what = call.what { arguments["what"] = what }
        // A page's query can carry a search or an address: the host only.
        if let url = call.url { arguments["urlHost"] = URL(string: url)?.host ?? "<unreadable>" }
        return arguments
    }

    /// `loggedArguments` with the words a page or the owner wrote (find words,
    /// element names, menu paths) as lengths: an agent step's goal-driven words
    /// are the owner's request, and agent-loop.log already keeps only lengths.
    static func lengthOnlyArguments(for call: RealtimeToolCall) -> [String: Any] {
        var arguments = loggedArguments(for: call)
        for key in ["words", "name"] {
            if let text = arguments.removeValue(forKey: key) as? String { arguments[key + "Length"] = text.count }
        }
        if let path = arguments.removeValue(forKey: "path") as? [String] { arguments["pathSteps"] = path.count }
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
        let screenOffer = dispatch?.screenOffer
        let isPress = decision.call.name == RealtimeVoiceVerbs.pressMenuName
        let isPoint = RealtimeVoiceVerbs.isScreenTargetTool(decision.call.name)
        let chose: Bool? = isPress ? choseFromOffered(path: decision.call.path, offered: decision.offeredBeforeCall)
            : isPoint && decision.call.elementName != nil
                ? decision.offeredElementsBeforeCall.map { offered in offered.contains { $0.name == decision.call.elementName } }
            : nil
        // An agent step (re-review of 2e45939): lengths, and no offered names.
        let agentStep = source == "agentLoop"
        return [
            "kind": "toolCall", "schema": schemaVersion, "source": source,
            "turnId": turnID, "stack": stack, "probeId": value(probeID), "fixture": value(fixture),
            "seq": sequence, "tool": decision.call.name,
            "args": agentStep ? lengthOnlyArguments(for: decision.call) : loggedArguments(for: decision.call),
            "callMs": value(releasedUptime.map { Int(((decision.callUptime - $0) * 1000).rounded()) }),
            "harnessMs": value(dispatch?.harnessMilliseconds),
            "ok": value(dispatch.map(\.harnessConfirmed)),
            "harnessError": value(dispatch?.result["error"] as? String),
            "verification": value((dispatch?.result["verification"] as? String) ?? (dispatch?.result["status"] as? String)),
            "offered": agentStep ? NSNull() : value(offer.map { $0.candidates.map(\.jsonObject) } ?? screenOffer.map { $0.candidates.map(\.jsonObject) }),
            "offeredCount": value(offer?.candidates.count ?? screenOffer?.candidates.count),
            "correctOffered": value(expectedPath.flatMap { expected in offer.map { $0.candidates.contains { $0.path == expected } } }),
            "enabledItemCount": value(offer?.enabledItemCount),
            "privacyDroppedCount": value(offer?.privacyDroppedCount ?? screenOffer?.privacyDroppedCount),
            "listingIncomplete": value(offer?.listingIncomplete ?? screenOffer?.listingIncomplete),
            "choseFromOffered": value(chose),
            "independentCheck": value(independentCheck),
            "appCheck": value(dispatch?.appCheck),
            "heardCheck": value(dispatch?.heardCheck),
            "autoFocus": value(dispatch?.autoFocus),
            "heardOverlapsLabel": value(isPress ? dispatch?.heardOverlapsLabel : nil),
            "offerSource": value(isPress || isPoint ? decision.offerSource?.rawValue : nil),
            "snappedBy": value(decision.snappedBy)
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
