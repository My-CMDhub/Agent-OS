//
//  SystemUITargets.swift
//  leanring-buddy
//
//  What annotate and point_at can name OUTSIDE the front app's window: Dock
//  icons, the front app's menu-bar titles and the status icons. Owner's live
//  test 2026-10-26: on the desktop, "just highlight me where I should click"
//  came back nothingDrawn, because shapes resolved only against the front
//  app's snapshot (Finder's desktop icons) while the Dock and the menu bar
//  belong to other processes. Read-only: the result is only drawn on Clicky's
//  own click-through overlay. The front app always wins; this is the fallback.
//

import AppKit
import ApplicationServices
import Foundation

nonisolated enum SystemUITargets {

    static let dockBundleIdentifier = "com.apple.dock"

    /// Where a target was found, as the model is told it.
    enum Place: String, Sendable {
        case dock = "in the Dock"
        case menuBar = "in the menu bar"
    }

    struct Target: Equatable, Sendable {
        let name: String
        let role: String
        let subrole: String?
        /// AppKit coordinates (bottom-left origin).
        let frame: CGRect
        let place: Place
        /// Every name it answers to; `name` first (a status icon's identifier and owner too).
        let aliases: [String]

        /// "Dock icon \"Safari\" in the Dock": what the model is told was drawn.
        var described: String { "\(RealtimeScreenVerbs.roleWord(role: role, subrole: subrole)) \(UntrustedText(name).forDisplay) \(place.rawValue)" }

        /// point_at's form: its `position` is where it was found.
        var candidate: RealtimeScreenCandidate {
            RealtimeScreenCandidate(name: name, role: role, frame: frame, position: place.rawValue, subrole: subrole)
        }
    }

    // MARK: Pure

    /// A target, or nil: an implausible name (empty, document-length, a control
    /// character), a zero-area frame, or a frame on no screen. An autohidden Dock
    /// publishes its icons off-screen, so a hidden Dock simply has none.
    static func target(name: String?, role: String, subrole: String? = nil, frame: CGRect, place: Place,
                       screens: [CGRect], aliases: [String] = []) -> Target? {
        guard let name, UntrustedText(name).isPlausibleControlLabel,
              frame.width > 0, frame.height > 0, screens.contains(where: { $0.intersects(frame) }) else { return nil }
        let others = aliases.filter { $0 != name && UntrustedText($0).isPlausibleControlLabel }
        return Target(name: name, role: role, subrole: subrole, frame: frame, place: place, aliases: [name] + others)
    }

    /// The targets a spoken name means, by any of their names: exact, then
    /// normalised — the rule annotate and point_at already use in the window
    /// (`RealtimeScreenVerbs.namedMatches`). Each target at most once.
    static func matches(_ name: String, among targets: [Target]) -> [Target] {
        let name = withoutPlaceWords(name)
        let flat = targets.indices.flatMap { index in targets[index].aliases.map { (index, $0) } }
        var seen = Set<Int>()
        return RealtimeScreenVerbs.namedMatches(name, among: flat.map(\.1))
            .map { flat[$0].0 }
            .filter { seen.insert($0).inserted }
            .map { targets[$0] }
    }

    /// Live 2026-10-27 (D02): the model pointed at "Wi-Fi icon in the menu bar", a description, and the "Wi‑Fi" icon was
    /// not matched. For system UI only, trailing place words go: "X icon", "X in the Dock", "X menu-bar icon" are X.
    static func withoutPlaceWords(_ name: String) -> String {
        var trimmed = name.trimmingCharacters(in: .whitespaces)
        let tails = [#"\s+(?:in|on|from)\s+(?:the\s+)?(?:dock|menu[\s-]?bar|status bar)$"#, #"\s+(?:menu[\s-]?bar\s+|dock\s+|status\s+)?(?:icon|button|item|extra)$"#]
        var changed = true
        while changed {
            changed = false
            for tail in tails {
                let next = trimmed.replacingOccurrences(of: tail, with: "", options: [.regularExpression, .caseInsensitive])
                if next != trimmed, !next.isEmpty { trimmed = next; changed = true }
            }
        }
        return trimmed
    }

    /// Live 2026-10-27/28: the owner's Dock auto-hides and the menu bar slides away under a full-screen app, so their
    /// items publish frames off the screen (status icons at y=945 on a 900-pt display). Drawing there helps no one; the
    /// answer says where it is and how the owner shows it. Never move the pointer for them.
    static func hiddenNote(_ place: Place) -> String {
        switch place {
        case .dock:
            return "the Dock is hiding itself, so its icons are off screen now: ask the owner to move the pointer to the "
                + "bottom edge of the screen to show the Dock, then point again while it is showing"
        case .menuBar:
            return "the menu bar is hidden now (the app in front is full screen, or the menu bar hides itself): ask the owner "
                + "to move the pointer to the top edge of the screen to show it, then point again while it is showing"
        }
    }

    /// Every system UI target, split by whether it is on a screen now: the hidden ones are only ever named, never drawn.
    static func readSplit(frontApp: String?, answer: @Sendable (String) -> String, screens: [CGRect]) -> (visible: [Target], hidden: [Target]) {
        let everywhere = [CGRect(x: -100_000, y: -100_000, width: 200_000, height: 200_000)]
        let all = read(frontApp: frontApp, answer: answer, screens: everywhere)
        let onScreen = { (target: Target) in screens.contains { $0.intersects(target.frame) } }
        return (all.filter(onScreen), all.filter { !onScreen($0) })
    }

    /// A front-app read that found no window (the desktop with nothing open):
    /// the system UI is still worth asking. A policy or lock refusal is not.
    static let noWindowErrors: Set<String> = ["noFocusedWindow", "noRootNode"]

    /// Status icons from the harness's `status` read, named by find_menu_bar_items'
    /// own rules (`RealtimeVoiceVerbs.menuBarItemNames`): the Passwords extra,
    /// Clicky's own and a policy-refused owner are never targets.
    static func statusTargets(fromStatusResponse response: [String: Any], ownerMayBeRead: (String?) -> Bool,
                              screens: [CGRect]) -> [Target] {
        guard response["ok"] as? Bool == true else { return [] }
        return (response["items"] as? [[String: Any]] ?? []).compactMap { entry -> Target? in
            let bundle = (entry["owner"] as? [String: Any])?["bundleIdentifier"] as? String
            guard !HarnessServer.isHarnessItself(bundleIdentifier: bundle),
                  let names = RealtimeVoiceVerbs.menuBarItemNames(entry, ownerMayBeRead: ownerMayBeRead),
                  let frame = RealtimeScreenVerbs.frame(entry["frame"]) else { return nil }
            // Spoken as its label or its app ("Wi‑Fi", "Wispr Flow"), listed by find_menu_bar_items as `name`.
            return target(name: names.label ?? names.ownerName ?? names.name, role: AccessibilityMenu.menuBarItemRole,
                          subrole: statusItemSubrole, frame: frame, place: .menuBar, screens: screens,
                          aliases: [names.name] + [names.ownerName].compactMap { $0 } + [shortLabel(names.label)].compactMap { $0 })
        }
    }

    /// "Wi‑Fi, connected, 2 bars" answers to "Wi‑Fi": a status icon's description leads with its name (live 2026-10-28).
    static func shortLabel(_ label: String?) -> String? {
        guard let label, let first = label.split(separator: ",").first.map({ $0.trimmingCharacters(in: .whitespaces) }),
              !first.isEmpty, first != label else { return nil }
        return first
    }

    /// The subrole macOS gives status icons; `roleWord` calls them menu-bar icons.
    static let statusItemSubrole = "AXMenuExtra"

    // MARK: Live (blocking cross-process AX: call off the main thread)

    /// Everything nameable on the Dock and the menu bar, each source only when
    /// the per-app policy lets a model read it (fail closed). `frontApp` is the
    /// bundle whose menu titles are read; never Clicky's.
    static func read(frontApp: String?, answer: @Sendable (String) -> String, screens: [CGRect]) -> [Target] {
        guard !LockScreenGuard.isLockScreen(frontApp) else { return [] }
        let policy = HarnessAppPolicy.load(from: HarnessServer.policyURL)
        let mayBeRead = { (bundle: String?) in HarnessPolicy.policyAllowsModelRead(bundleIdentifier: bundle, load: policy) }
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), AccessibilityMenu.messagingTimeoutInSeconds)
        let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
        func appKit(_ element: AXUIElement) -> CGRect {
            AccessibilityTreeWalker.copyFrame(from: element).frame
                .map { AccessibilityTreeWalker.convertAccessibilityFrameToAppKitFrame($0, primaryDisplayHeightInPoints: primaryHeight) } ?? .zero
        }

        var targets: [Target] = []
        if mayBeRead(dockBundleIdentifier),
           let dock = NSRunningApplication.runningApplications(withBundleIdentifier: dockBundleIdentifier).first {
            // Dock > AXList > AXDockItem (title = the app or folder; subrole AXApplicationDockItem, AXTrashDockItem…).
            for list in children(of: AXUIElementCreateApplication(dock.processIdentifier)) where string(list, kAXRoleAttribute) == "AXList" {
                for item in children(of: list) where string(item, kAXRoleAttribute) == "AXDockItem" {
                    if let found = target(name: string(item, kAXTitleAttribute), role: "AXDockItem", subrole: string(item, kAXSubroleAttribute),
                                          frame: appKit(item), place: .dock, screens: screens) { targets.append(found) }
                }
            }
        }
        if let frontApp, !HarnessServer.isHarnessItself(bundleIdentifier: frontApp), mayBeRead(frontApp),
           let application = NSRunningApplication.runningApplications(withBundleIdentifier: frontApp).first,
           let bar = AccessibilityMenu.menuBarNode(for: application) {
            for title in AccessibilityMenu.liveChildren(of: bar) where title.role == AccessibilityMenu.menuBarItemRole {
                guard let element = title.element,
                      let found = target(name: title.label, role: title.role, frame: appKit(element), place: .menuBar, screens: screens) else { continue }
                targets.append(found)
            }
        }
        targets += statusTargets(fromStatusResponse: RealtimeOpenAppTool.harnessResponseObject(answer("{\"verb\":\"status\"}")),
                                 ownerMayBeRead: mayBeRead, screens: screens)
        return targets
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}
