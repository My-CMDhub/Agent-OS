//
//  RealtimeHandsVerbs.swift
//  leanring-buddy
//
//  scroll / type_text / close — the voice model's hands (owner's target level
//  2026-10-01: "its hands on my keyboard and trackpad, with guardrails").
//  Live 2026-09-30 12:41-13:00Z the model said "I cannot type just yet", could
//  not scroll a LinkedIn page and told the owner to find the close button.
//
//  Each maps to a harness verb, and every guard there holds: scroll -> `scroll`
//  (no kernel question; policy, kill switch, `expectApp`); type_text -> `type`
//  (a secure field refused above everything, replacing text asks on a card,
//  Enter never pressed); close -> the app's own menu item through `menu`
//  ("Quit …" asks on a card: the kernel's "quit" word).
//

import AppKit
import Foundation

nonisolated enum RealtimeHandsVerbs {
    static let closeTargets = ["tab", "window", "app"]

    /// How long a quit is given before "still running" is said. Review
    /// 2026-10-01: Xcode and Chrome take seconds to tear down, so 3 s reported
    /// clean quits as failures. 8 s is the reviewer's figure, NOT measured here
    /// (no owner app was quit to time it); re-measure on the first live quit.
    static let quitWaitSeconds: Double = 8

    /// AX errors a press can come back with while the app is quitting under
    /// it: -25204 (cannot complete — busy tearing down) and -25202 (invalid
    /// element — already gone). Neither means the press did not happen.
    static let quitInFlightAXErrors: Set<Int> = [-25204, -25202]

    /// Whether the menu press reached the app: sent, or failed the way a quit
    /// in flight fails. A refusal, a Deny on the card or an expired ticket
    /// carries no `performed`, and nothing was asked to quit.
    static func quitWasAttempted(_ pressed: [String: Any]) -> Bool {
        guard let performed = pressed["performed"] as? [String: Any] else { return false }
        if performed["status"] as? String == "sent" { return true }
        return (performed["axErrorRawValue"] as? Int).map(quitInFlightAXErrors.contains) ?? false
    }

    /// Said when the app outlives the wait. It claims nothing about why: a save
    /// prompt is one reason, a slow teardown another, and neither was seen.
    static func stillRunningMessage(name: String) -> String {
        "\(name) was asked to quit and is still running after \(Int(quitWaitSeconds)) s; nothing more was done"
    }

    /// The app's own close item, from a `menus` listing: enabled leaves only.
    ///  - tab: "Close Tab"; else the ⌘W item if it closes something smaller
    ///    than a window ("Close Editor" in Cursor). TextEdit's bare "Close" is
    ///    the window, never a tab.
    ///  - window: "Close Window"; else a bare "Close".
    ///  - app: "Quit …" in the app's own menu, the first in the bar.
    /// ponytail: English labels; a localized menu answers noCloseItem.
    static func closeMenuPath(what: String, items: [[String: Any]]) -> [String]? {
        let leaves: [(path: [String], label: String, shortcut: String?)] = items.compactMap { item in
            guard item["enabled"] as? Bool == true, item["hasSubmenu"] as? Bool != true,
                  let path = item["path"] as? [String], path.count >= 2, let last = path.last else { return nil }
            return (path, RealtimeVoiceVerbs.foldedTokens(last).joined(separator: " "), item["shortcut"] as? String)
        }
        func first(_ label: String) -> [String]? { leaves.first { $0.label == label }?.path }
        switch what {
        case "tab":
            return first("close tab") ?? leaves.first { leaf in
                leaf.shortcut == "\u{2318}W" && leaf.label.hasPrefix("close ") && !["close window", "close all"].contains(leaf.label)
            }?.path
        case "window":
            return first("close window") ?? first("close")
        case "app":
            // The Apple menu is first in every bar (and holds "Force Quit…" and
            // ⇧⌘Q "Log Out"): ⌘Q's Quit, else Quit in the first menu that is not it.
            func isQuit(_ label: String) -> Bool { label == "quit" || label.hasPrefix("quit ") }
            if let quit = leaves.first(where: { $0.shortcut == "\u{2318}Q" && isQuit($0.label) }) { return quit.path }
            let appMenu = leaves.first { !RealtimeVoiceVerbs.isPrivateMenuPath([$0.path[0]]) }?.path.first
            return leaves.first { $0.path.first == appMenu && isQuit($0.label) }?.path
        default:
            return nil
        }
    }

    /// Whether any process of `bundleIdentifier` is still running, polled
    /// until `seconds` pass. A quit is proved by the app being gone.
    static func stillRunning(_ bundleIdentifier: String, seconds: Double = quitWaitSeconds) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        repeat {
            if NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).allSatisfy(\.isTerminated) { return false }
            try? await Task.sleep(for: .milliseconds(100))
        } while ProcessInfo.processInfo.systemUptime < deadline
        return true
    }

    /// scroll / type_text: what the model is told beyond the harness's own
    /// fields — which way it scrolled and what came into view, what was typed into.
    static func result(_ result: [String: Any], call: RealtimeToolCall, target: RealtimeScreenTarget?,
                       response: [String: Any]) -> [String: Any] {
        var result = result
        switch call.name {
        case RealtimeVoiceVerbs.scrollName:
            result["scrolled"] = call.direction ?? NSNull()
            if let newlyVisible = response["newlyVisible"] as? [String] { result["newlyVisible"] = newlyVisible }
        case RealtimeVoiceVerbs.typeTextName:
            // From the harness's own read of the field it typed into: its role and
            // its title, description or placeholder — never its value.
            let role = (response["resolved"] as? [String: Any])?["role"] as? String
            let label = (response["field"] as? [String: Any])?["label"] as? String
            if let role, let label {
                result["typedInto"] = "\(RealtimeScreenVerbs.roleWord(role: role)) \(UntrustedText(label).forDisplay)"
            } else {
                result["typedInto"] = target?.candidate?.described ?? "the field with keyboard focus"
            }
        default:
            break
        }
        return result
    }
}
