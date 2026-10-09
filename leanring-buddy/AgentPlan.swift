//
//  AgentPlan.swift
//  leanring-buddy
//
//  The agent loop's `plan` tool (design docs/superpowers/specs/2026-10-07-
//  affordance-map-and-plan-execute-design.md §B). Model calls are the cost
//  (~2-3 s each) and the loop made one per step: the prompt's default was one
//  tool per reply, Gemini's multi-call idiom is parallel and independent while
//  ours are sequential, and every menu step needed a find first. A plan is ONE
//  call with an array argument: up to six steps, each a tool name plus that
//  tool's own arguments, run in order through the same per-call path
//  (`AgentLoop`'s batch loop, so every guard is the same code).
//
//  Nothing acts before the whole plan passes `precheck` (shape) and
//  `livePrecheck` (what the screen and menus say now): a refused plan runs no
//  step. Execution stops and returns to the model on a failure, a card waited
//  on, `notObserved`, a front-app change, or a read whose result it must see.
//

import Foundation

nonisolated enum AgentPlan {
    static let name = "plan"
    static let maximumSteps = 6
    static let positionKeys = ["x", "y", "point"]

    /// What a step may name: the loop's tools, never do_task, ask_owner (a
    /// pause is its own reply) or a plan inside a plan.
    static var stepTools: Set<String> {
        RealtimeVoiceVerbs.allToolNames.subtracting([RealtimeVoiceVerbs.doTaskName])
            .union([AgentLoopTools.readPageName, AgentLoopTools.searchWebName, AgentLoopGemini.webLookupName, AgentLoopTools.doneName])
    }

    /// Arguments each tool needs; any one alternative set, fully present.
    static let requiredArguments: [String: [[String]]] = [
        RealtimeOpenAppTool.name: [["name"]], RealtimeVoiceVerbs.focusAppName: [["name"]],
        RealtimeVoiceVerbs.findMenuItemsName: [["words"]], RealtimeVoiceVerbs.findOnScreenName: [["words"]],
        RealtimeVoiceVerbs.pressMenuName: [["path"], ["shortcut"]],
        RealtimeVoiceVerbs.pressElementName: [["name"], ["x", "y"], ["point"], ["underPointer"]],
        RealtimeVoiceVerbs.pointAtName: [["name"], ["x", "y"], ["point"], ["underPointer"]],
        RealtimeVoiceVerbs.typeTextName: [["text"]], RealtimeVoiceVerbs.scrollName: [["direction"]],
        RealtimeVoiceVerbs.closeName: [["what"]], RealtimeVoiceVerbs.openURLName: [["url"]],
        RealtimeVoiceVerbs.annotateName: [["shapes"]], AgentLoopTools.searchWebName: [["query"]],
        AgentLoopGemini.webLookupName: [["question"]], AgentLoopTools.doneName: [["summary"]]
    ]

    /// Anthropic tool JSON. Each step is a flat object: `tool` plus that
    /// tool's own parameters (the annotate pattern), so a model that cannot
    /// send dependent calls in one reply can still send one array.
    static var declaration: [String: Any] {
        func text(_ description: String) -> [String: Any] { ["type": "string", "description": description] }
        func number(_ description: String) -> [String: Any] { ["type": "number", "description": description] }
        let step: [String: Any] = [
            "type": "object",
            "properties": [
                "tool": text("The tool this step calls, for example \"press_menu\"."),
                "app": text("The app, as that tool takes it."),
                "name": text("open_app / focus_app: the app's name. press_element / point_at / type_text / scroll: the element's exact name."),
                "words": text("find_menu_items / find_on_screen: a few words."),
                "path": ["type": "array", "items": ["type": "string"], "description": "press_menu: the menu path, split at \" > \"."],
                "shortcut": text("press_menu: instead of a path, the shortcut an App verbs line shows."),
                "x": number("Step 1 only: across the screenshot, 0 to 1."),
                "y": number("Step 1 only: down the screenshot, 0 to 1."),
                "text": text("type_text: exactly the text to type."),
                "mode": text("type_text: insert or replace."),
                "direction": text("scroll: up, down, left or right."),
                "amount": number("scroll: pages."),
                "what": text("close: tab, window or app."),
                "url": text("open_url: the full address."),
                "query": text("search_web: the words."),
                "question": text("web_lookup: the question."),
                "summary": text("done: what was achieved, spoken to the owner."),
                "evidence": ["type": "array", "items": ["type": "integer"], "description": "done: the step numbers whose ok results prove it."]
            ] as [String: Any],
            "required": ["tool"]
        ]
        return ["name": name,
                "description": "Runs up to \(maximumSteps) steps in order with no model call between them: every step you can name now from "
                    + "the screenshot, the App verbs and earlier results. Each step is one of your tools with that tool's own arguments. "
                    + "Checked before anything runs (known tools, arguments, menu paths from the App verbs or a find, read-only); it stops "
                    + "at the first step that fails, waits for an approval card, is notObserved, changes the app in front, or reads "
                    + "(read_page, find_on_screen, find_menu_items, web_lookup), and the result lists each step that ran. A position (x, y) "
                    + "only in step 1. done may be the last step only when the steps before it act and their ok results prove it.",
                "input_schema": ["type": "object",
                                 "properties": ["steps": ["type": "array", "items": step,
                                                          "description": "1 to \(maximumSteps) steps, in order."]] as [String: Any],
                                 "required": ["steps"]] as [String: Any]]
    }

    static func steps(fromInput input: [String: Any]) -> [[String: Any]]? {
        input["steps"] as? [[String: Any]]
    }

    /// One step as its tool's input: the step without `tool`.
    static func arguments(of step: [String: Any]) -> [String: Any] {
        step.filter { $0.key != "tool" }
    }

    static func tool(of step: [String: Any]) -> String { (step["tool"] as? String) ?? "" }

    /// The shape: refuses the whole plan before anything runs. nil: it may run.
    static func precheck(_ steps: [[String: Any]]?) -> String? {
        guard let steps, !steps.isEmpty else { return "a plan needs a list of 1 to \(maximumSteps) steps" }
        guard steps.count <= maximumSteps else { return "a plan runs at most \(maximumSteps) steps; this one has \(steps.count)" }
        for (index, step) in steps.enumerated() {
            let tool = tool(of: step)
            let number = index + 1
            guard stepTools.contains(tool) else {
                return tool == AgentLoopTools.askOwnerName ? "step \(number): ask_owner is its own reply, never a step of a plan"
                    : "step \(number): there is no tool named \(UntrustedText(tool).forDisplay) a plan may run"
            }
            if tool == AgentLoopTools.doneName, index != steps.count - 1 { return "step \(number): done may only be the last step" }
            if index > 0, positionKeys.contains(where: { step[$0] != nil }) {
                return "step \(number): a position is a point in this step's screenshot, which an earlier step may change; "
                    + "aim it by name, or by position in the next reply"
            }
            let arguments = arguments(of: step)
            if let alternatives = requiredArguments[tool], !alternatives.contains(where: { $0.allSatisfy { arguments[$0] != nil } }) {
                return "step \(number): \(tool) needs \(alternatives.map { $0.joined(separator: " and ") }.joined(separator: " or "))"
            }
        }
        return nil
    }

    /// Steps that only read: their result is something to see, so a plan stops after one.
    static func isReading(_ tool: String) -> Bool {
        [AgentLoopTools.readPageName, AgentLoopGemini.webLookupName, RealtimeVoiceVerbs.findOnScreenName,
         RealtimeVoiceVerbs.findMenuItemsName].contains(tool)
    }

    static func isActing(_ tool: String) -> Bool {
        !isReading(tool) && tool != AgentLoopTools.doneName && tool != RealtimeVoiceVerbs.pointAtName
            && tool != RealtimeVoiceVerbs.annotateName
    }

    /// What the menus and screen say NOW, before any step acts. Menu steps:
    /// the path (or the shortcut's one owner) is in the App verbs or a find of
    /// this task, and a read-only task's press judge allows it; an item the map
    /// marks disabled is refused only when no earlier step acts (Get Info
    /// enables after a selection). A step aimed by name before anything acts:
    /// refused if every exact match on screen is a secure field, or if more
    /// than one matches (ask which). No match is allowed: the press's own
    /// resolver still has OCR and vision to look with.
    static func livePrecheck(_ steps: [[String: Any]], map: AffordanceMap?, findOffer: RealtimeStandingOffer?, readOnly: Bool,
                             screenElements: [[String: Any]]?) -> String? {
        var actedBefore = false
        for (index, step) in steps.enumerated() {
            let tool = tool(of: step)
            let number = index + 1
            defer { if isActing(tool) { actedBefore = true } }
            if tool == RealtimeVoiceVerbs.pressMenuName {
                var path = (step["path"] as? [Any])?.compactMap { $0 as? String } ?? []
                if path.isEmpty, let shortcut = step["shortcut"] as? String {
                    switch AffordanceMap.resolve(shortcut: shortcut, in: map?.offer) {
                    case .success(let owner): path = owner
                    case .failure(let refusal): return "step \(number): \(refusal.message)"
                    }
                }
                let shown = UntrustedText(path.joined(separator: " > ")).forDisplay
                let offered = [map?.offer, findOffer].contains { offer in
                    offer.map { RealtimeDecisionTrace.choseFromOffered(path: path, offered: $0.candidates) == true } ?? false
                }
                guard offered else {
                    return "step \(number): the menu path \(shown) is not in the App verbs or a find of this task; copy a path exactly as listed"
                }
                if readOnly, let reason = AgentLoop.readOnlyRefusal(["verb": "menu", "path": path], focusedField: { nil }) {
                    return "step \(number): this task is read-only by the owner's words, and \(reason)"
                }
                if !actedBefore, map?.items.first(where: { $0.path == path })?.enabled == false {
                    return "step \(number): \(shown) is disabled now, and no step before it changes that"
                }
            } else if !actedBefore, RealtimeVoiceVerbs.aimsAtScreen(tool), let name = step["name"] as? String, let elements = screenElements {
                let matches = elements.filter { $0["name"] as? String == name }
                if !matches.isEmpty, matches.allSatisfy(AccessibilityElementNode.mightBeSecure(entry:)) {
                    return "step \(number): \(UntrustedText(name).forDisplay) is a password or secure field; nothing is typed or pressed there"
                }
                let visible = matches.filter { !AccessibilityElementNode.mightBeSecure(entry: $0) }
                if visible.count > 1 {
                    return "step \(number): \(visible.count) things on screen are named \(UntrustedText(name).forDisplay); "
                        + "find_on_screen to tell them apart, or ask_owner which"
                }
            }
        }
        return nil
    }

    /// The plan's one tool_result: each step that ran or was skipped, in order.
    static func combinedResult(stepResults: [[String: Any]], stoppedBecause: String?) -> [String: Any] {
        let ranAll = stoppedBecause == nil
        let allOk = stepResults.allSatisfy { $0["ok"] as? Bool == true }
        // A read's page text goes top level, where the result's size limit makes room for it.
        var steps = stepResults
        var text: Any = NSNull()
        if let index = steps.firstIndex(where: { $0["text"] is String }) { text = steps[index].removeValue(forKey: "text") ?? NSNull() }
        return ["ok": ranAll && allOk, "steps": steps, "stopped": stoppedBecause ?? NSNull(), "text": text,
                "message": ranAll ? (allOk ? "every step ran" : "a step did not succeed")
                    : "the plan stopped \(stoppedBecause!); the steps after it did not run. Look at the new screenshot, then plan again."]
    }
}
