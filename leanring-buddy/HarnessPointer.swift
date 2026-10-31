//
//  HarnessPointer.swift
//  leanring-buddy
//
//  `pointer`: the universal fallback hand (owner's ruling 2026-10-31). Every other
//  acting verb is scoped to the front app's focused window and needs an AX name or
//  OCR words at the point, so the menu-bar icons the model could SEE could not be
//  clicked. This verb acts at ANY on-screen point; the guards decide by what is
//  there, not by which window holds it.
//
//  Coordinates: the caller's points are AppKit global (bottom-left of the primary
//  display, y up, spanning every display — the `nearPoint` convention). CGEvent and
//  AX are top-left (WindowPositionManager.swift:235): `topLeft` is the one flip,
//  against the PRIMARY display's height, which is what makes it right on a
//  secondary display too (a display above the primary has negative CG y).
//
//  This file is the pure half (a test proves it without one AX read) and the posted
//  events; the guarded verb itself is `HarnessServer.pointerResponse`.
//

import AppKit
import ApplicationServices
import Foundation

enum PointerAction: String, CaseIterable {
    case click, doubleClick, rightClick, move, drag, scroll

    /// Whether the words at the point are judged by the kernel. A hover and a wheel
    /// change nothing a card would protect; every press-shaped action is judged.
    var judgesWords: Bool { self != .move && self != .scroll }
}

enum HarnessPointer {

    // MARK: Pure — where the point is

    /// What kind of screen furniture holds the point, from the window server's
    /// window there (`windowAt`): evidence for the caller, never a permission.
    enum Surface: String { case menuBar, dock, desktop, window, other }

    /// The window server's topmost mouse-accepting window at a point.
    /// `bounds` is CG global (top-left), as `CGWindowListCopyWindowInfo` reports it.
    struct WindowAtPoint: Equatable {
        let number: Int
        let ownerPID: pid_t
        let ownerBundle: String?
        let ownerName: String?
        let layer: Int
        let bounds: CGRect
        /// `kCGWindowName` (readable with Screen Recording): "AirDrop" for Finder's AirDrop window.
        var title: String? = nil
    }

    /// The window at the point is still the one judged (security review 2026-10-31: a banner or a
    /// sheet arriving between the check and the click is another window, or another owner). A window
    /// the server would not describe (number 0) is matched by its owner alone.
    static func sameWindow(judged: WindowAtPoint, now: WindowAtPoint?) -> Bool {
        guard let now, now.ownerPID == judged.ownerPID else { return false }
        return judged.number == 0 || now.number == judged.number
    }

    /// Same constants `EscalationLadder.desktopWindowsToDraw` draws the desktop by:
    /// menu bar and status items at 24/25 inside the strip at the top of their display
    /// (measured 2026-10-30: the bar is 1440x30), the Dock at 20, anything below 0 the
    /// desktop (wallpaper, desktop icons, Stage Manager's backdrop), 0 an app window.
    static func surface(_ window: WindowAtPoint, displayTopLeft: CGRect) -> Surface {
        let menuLevels = [Int(CGWindowLevelForKey(.mainMenuWindow)), Int(CGWindowLevelForKey(.statusWindow))]
        if menuLevels.contains(window.layer), window.bounds.minY >= displayTopLeft.minY - 1,
           window.bounds.maxY <= displayTopLeft.minY + EscalationLadder.menuBarStripHeight {
            return .menuBar
        }
        if window.ownerBundle == "com.apple.dock", window.layer == Int(CGWindowLevelForKey(.dockWindow)) { return .dock }
        if window.layer < 0 { return .desktop }
        return window.layer == 0 ? .window : .other
    }

    /// AppKit global -> CGEvent/AX top-left. One flip, against the primary display.
    static func topLeft(_ point: CGPoint, primaryDisplayHeight: CGFloat) -> CGPoint {
        RealtimeScreenVerbs.topLeftPoint(point, primaryDisplayHeight: primaryDisplayHeight)
    }

    /// The display (AppKit frame) holding the point, or nil: a point on no display is refused.
    static func display(holding point: CGPoint, among displays: [CGRect]) -> CGRect? {
        displays.first { $0.contains(point) }
    }

    // MARK: Pure — the guard order

    /// What the window server and the AX hit test say owns the point, before anything acts.
    struct Owner: Equatable {
        var pid: pid_t
        var bundle: String?
    }

    /// The refusals, in the one order they are checked (cheapest and most absolute
    /// first): locked screen, a point on no display, nothing the window server would
    /// hit there, Clicky itself (a synthetic click must never reach the approval card),
    /// a password manager, an app the policy refuses — for the window's owner AND the
    /// app the AX hit names (the menu bar's titles are drawn by the Window Server but
    /// act in the front app) — then the AX hit's own refusal (a password box). `hit`
    /// nil means not read yet: the live code asks this twice, before the AX read (so a
    /// password manager is never read at all) and after it. A policy `confirm` is not a
    /// refusal: it becomes a card at `gate`.
    static func refusal(locked: Bool, onDisplay: Bool, windowOwner: Owner?, hitApp: Owner?, ownPID: pid_t,
                        ownBundle: String?, isRefused: (String?) -> Bool,
                        hit: RealtimeScreenHit? = nil) -> (code: String, message: String)? {
        if locked { return ("screenIsLocked", "the screen is locked — there is nothing of the user's to act on") }
        guard onDisplay else { return ("pointNotOnScreen", "that point is on no display; nothing was done") }
        guard let windowOwner else {
            return ("pointUnreadable", "the window server named no window at that point, so what owns it is unknown; nothing was done")
        }
        let owners = [windowOwner] + (hitApp.map { [$0] } ?? [])
        if owners.contains(where: { $0.pid == ownPID || HarnessServer.isHarnessItself(bundleIdentifier: $0.bundle)
                                     || (ownBundle != nil && $0.bundle == ownBundle) }) {
            return ("targetIsHarnessItself", HarnessServer.harnessItselfMessage)
        }
        if owners.contains(where: { CredentialGuard.isPasswordManager($0.bundle) }) {
            return ("passwordManager", "that point belongs to a password manager — credentials are the owner's alone; nothing was done")
        }
        if let refused = owners.first(where: { isRefused($0.bundle) }) {
            return ("policyRefused", "app policy refuses \(refused.bundle ?? "an app with no bundle identifier") — nothing was done")
        }
        if case .refused(let error)? = hit {
            return (error, error == "secureField" ? "that point is a password field; nothing was done" : HarnessServer.harnessItselfMessage)
        }
        return nil
    }

    // MARK: Pure — what the kernel judges

    /// The kernel on the words at the point, exactly as on a `click`: each name (the AX
    /// name, the pressable ancestor's, or the OCR line) is the target and the model's
    /// `label` is word-checked beside it — an irreversible word refuses, a destructive or
    /// publishing word asks. The role is the element's own when it is one a click
    /// navigates (so a Wi-Fi switch still asks), else a stand-in AXButton, so an AXDockItem
    /// or a status icon is judged by its words alone, never carded as an "unrecognised
    /// role" (owner: cards only for consequential actions). No names and no label: nothing
    /// to judge, allowed. A double-click in Finder opens the item, and opening always asks.
    static func decision(action: PointerAction, names: [String], label: String?, role: String?, subrole: String?,
                         frame: CGRect, visibleBounds: CGRect, ownerBundle: String?, draftScope: Bool) -> SafetyDecision {
        guard action.judgesWords else { return .allow }
        let judgedRole = role.map { ActionSafetyKernel.navigationalRoles(for: .click).contains($0) ? $0 : "AXButton" } ?? "AXButton"
        var decisions = names.map { name -> SafetyDecision in
            let node = AccessibilityElementNode(role: judgedRole, subrole: subrole, title: name, value: nil,
                                                frameInAppKitCoordinates: frame, depth: 0, children: [])
            return ActionSafetyKernel.evaluate(intent: ElementActionIntent(role: nil, title: name, action: .click), resolvedNode: node,
                                               matchCount: 1, visibleBounds: visibleBounds, labelTitle: label, draftScope: draftScope)
        }
        // The model's words alone, when nothing at the point had a name: the same word lists.
        if names.isEmpty, let label { decisions.append(ActionSafetyKernel.evaluateAdjust(name: label)) }
        if action == .doubleClick, ownerBundle == "com.apple.finder" {
            decisions.append(.requireConfirmation(reason: "a double-click in Finder opens the item, and opening always asks"))
        }
        return strongest(decisions)
    }

    /// A Dock element as read at the point: its role, subrole and AXURL. `readFailed`: one of
    /// them failed to read (an absent attribute is not a failure).
    struct DockItem: Equatable {
        var role: String? = nil
        var subrole: String? = nil
        var url: URL? = nil
        var readFailed = false
    }

    /// What a Dock element opens, judged like `open` and `launch` (security review 2026-10-31): an
    /// application item is `ActionSafetyKernel.evaluateLaunch`'s answer for its app (Terminal and
    /// Passwords ask, Safari does not — the owner wants "click Safari in the Dock" to just work); a
    /// file, URL or stack item opens what it holds, and opening always asks; a drop onto an application
    /// opens the dropped item with it. A read that failed asks. `appBundleIdentifier`: the
    /// application item's own, resolved from its AXURL by the caller.
    static func dockDecision(action: PointerAction, isDropEnd: Bool, item: DockItem, appBundleIdentifier: String?) -> SafetyDecision {
        if item.readFailed {
            return .requireConfirmation(reason: "what this Dock item opens could not be read, so it is asked")
        }
        let isApplication = item.subrole == "AXApplicationDockItem"
        if isDropEnd {
            return isApplication ? .requireConfirmation(reason: "dropping onto an application in the Dock opens the item with it") : .allow
        }
        guard action == .click || action == .doubleClick else { return .allow }
        if isApplication {
            guard let appBundleIdentifier else {
                return .requireConfirmation(reason: "which application this Dock item launches could not be read, so it is asked")
            }
            return ActionSafetyKernel.evaluateLaunch(bundleIdentifier: appBundleIdentifier)
        }
        if ["AXDocumentDockItem", "AXURLDockItem", "AXFolderDockItem"].contains(item.subrole ?? "")
            || (item.role != "AXDockItem" && item.url != nil) {
            return .requireConfirmation(reason: "a Dock file, link or stack item opens what it holds, and opening always asks")
        }
        return .allow
    }

    /// A drop onto an AirDrop destination sends the item to another person: publishing, asked once.
    static func airDropDecision(isDropEnd: Bool, names: [String], windowTitle: String?) -> SafetyDecision {
        guard isDropEnd else { return .allow }
        let said = (names + [windowTitle ?? ""]).map { " " + $0.lowercased().split { !$0.isLetter }.joined(separator: " ") + " " }
        guard said.contains(where: { $0.contains(" airdrop ") || $0.contains(" air drop ") }) else { return .allow }
        return .requireConfirmation(reason: "dropping onto AirDrop sends the item to someone else", destructive: true)
    }

    /// A target nothing at the point named (no AX name, no reported OCR words) binds only its point
    /// and app, and the card's only description is the model's label: Allow once, never "Always".
    static func onceOnlyWhenUnnamed(_ decision: SafetyDecision, everyEndNamed: Bool) -> SafetyDecision {
        guard !everyEndNamed, case .requireConfirmation(let reason, false) = decision else { return decision }
        return .requireConfirmation(reason: reason, destructive: true)
    }

    /// Before the drop: the point still shows what the drop end was judged as — the same app, and the
    /// same AX name when it had one — or the drag is put back (a magnifying Dock slides a neighbour
    /// under the point; a sheet arrives). A refused hit (a password box, Clicky) never matches.
    static func dropStillMatches(judgedName: String?, judgedBundle: String?, now: RealtimeScreenHit, nowBundle: String?) -> Bool {
        if case .refused = now { return false }
        guard nowBundle == judgedBundle else { return false }
        return judgedName == nil || now.name == judgedName
    }

    /// The most cautious of several decisions: refuse > ask (destructive first) > allow.
    static func strongest(_ decisions: [SafetyDecision]) -> SafetyDecision {
        func rank(_ decision: SafetyDecision) -> Int {
            switch decision {
            case .refuse: return 3
            case .requireConfirmation(_, let destructive): return destructive ? 2 : 1
            case .allow: return 0
            }
        }
        return decisions.max { rank($0) < rank($1) } ?? .allow
    }

    /// The OCR words the kernel judges: the line holding the word at the point, or the
    /// word alone when the line is not a plain label (a paragraph is not a name).
    static func judgedOCRText(word: String, line: String?) -> String {
        guard let line, UntrustedText(line).isPlausibleControlLabel else { return word }
        return line
    }

    /// Where the event lands: a named control's visible centre (its frame clipped to the
    /// display) — the same aim `click` takes — when the requested point is inside it and
    /// it is control-sized; otherwise the requested point itself, so a hit that snapped
    /// to a whole pane or list does not drag the click to the pane's middle.
    static let maximumAimedElementSide: CGFloat = 400

    static func aimPoint(requested: CGPoint, elementFrame: CGRect?, display: CGRect) -> CGPoint {
        guard let frame = elementFrame?.intersection(display), !frame.isNull, frame.width > 0, frame.height > 0,
              frame.contains(requested), frame.width <= maximumAimedElementSide, frame.height <= maximumAimedElementSide
        else { return requested }
        return CGPoint(x: frame.midX, y: frame.midY)
    }

    /// What a ticket and an Always rule bind beyond verb, app and point (owner's
    /// ruling: action, point, to, label, target name): one target string, compared
    /// exactly, so a re-issue whose drop end or words differ is a different question.
    /// The points themselves ride in `nearPoint` (from) and here (to), rounded at decode.
    static func cardTarget(action: PointerAction, from: String?, to: String?, toPoint: CGPoint?, label: String?) -> String {
        let fromName = from.map { "\u{201C}\($0)\u{201D}" } ?? "what is drawn there"
        var target = fromName
        if action == .drag {
            let toName = to.map { "\u{201C}\($0)\u{201D}" } ?? "the point"
            target += " onto \(toName)" + (toPoint.map { " at (\(Int($0.x)), \(Int($0.y)))" } ?? "")
        }
        if let label, label != from { target += " (the model called it \u{201C}\(label)\u{201D})" }
        return target
    }

    // MARK: Pure — evidence

    /// The window-list change between two on-screen reads, keyed by window number:
    /// which windows appeared and which went, as "owner (layer)" — an independent
    /// witness the posted event cannot fake (a Control Centre panel is a new window).
    static func windowListChange(before: [Int: String], after: [Int: String]) -> (appeared: [String], disappeared: [String]) {
        (after.keys.filter { before[$0] == nil }.sorted().compactMap { after[$0] },
         before.keys.filter { after[$0] == nil }.sorted().compactMap { before[$0] })
    }

    /// The crop whose pixels are compared before and after: a square round the point,
    /// kept on its display. AppKit.
    static let evidenceSidePoints: CGFloat = 240

    static func evidenceRegion(around point: CGPoint, display: CGRect) -> CGRect {
        let side = min(evidenceSidePoints, display.width, display.height)
        let x = min(max(point.x - side / 2, display.minX), display.maxX - side)
        let y = min(max(point.y - side / 2, display.minY), display.maxY - side)
        return CGRect(x: x, y: y, width: side, height: side)
    }

    /// Wheel steps for `pages`: a page is 0.8 of half the display, `HarnessScroll`'s rule
    /// with the half display standing in for a container the pointer did not resolve.
    static func wheelSteps(pages: Double, display: CGRect, horizontal: Bool) -> Int {
        HarnessScroll.wheelSteps(pages: pages, extent: (horizontal ? display.width : display.height) / 2)
    }

    // MARK: Live reads

    /// The window a mouse-down at the point would hit (click-through windows such as our
    /// own overlay are skipped by the window server), with its owner. nil when none reads.
    static func windowAt(_ point: CGPoint) -> WindowAtPoint? {
        // One main-thread read: the window number, and whether it is one of OUR windows — AppKit's own list,
        // authoritative and no IPC (security review 2026-10-31), whatever the window server says of it.
        let ask = { () -> (number: Int, ours: Bool) in
            let number = NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0)
            return (number, number > 0 && NSApp.windows.contains { $0.windowNumber == number })
        }
        let (number, ours) = Thread.isMainThread ? ask() : DispatchQueue.main.sync(execute: ask)
        if ours {
            return WindowAtPoint(number: number, ownerPID: getpid(), ownerBundle: Bundle.main.bundleIdentifier, ownerName: "Clicky",
                                 layer: 0, bounds: .zero)
        }
        guard number > 0, let info = (CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(number)) as? [[String: Any]])?.first,
              let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value else { return nil }
        let bounds = (info[kCGWindowBounds as String] as? [String: Any]).flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) } ?? .zero
        return WindowAtPoint(number: number, ownerPID: pid, ownerBundle: NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
                             ownerName: info[kCGWindowOwnerName as String] as? String,
                             layer: (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0, bounds: bounds,
                             title: info[kCGWindowName as String] as? String)
    }

    /// The Dock element at a point (or its AXDockItem, up to three parents), read for `dockDecision`.
    static func dockItem(at point: CGPoint, primaryDisplayHeight: CGFloat) -> DockItem {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, RealtimeScreenHitTest.messagingTimeoutSeconds)
        let topLeft = topLeft(point, primaryDisplayHeight: primaryDisplayHeight)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(topLeft.x), Float(topLeft.y), &hit) == .success, var element = hit else {
            return DockItem(readFailed: true)
        }
        func read(_ element: AXUIElement, _ attribute: String) -> (value: AnyObject?, failed: Bool) {
            AXUIElementSetMessagingTimeout(element, RealtimeScreenHitTest.messagingTimeoutSeconds)
            var value: AnyObject?
            let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
            return (value, error != .success && error != .noValue && error != .attributeUnsupported)
        }
        // The hit or its AXDockItem up to three parents; a stack's own file item (no AXDockItem above it) stays the hit.
        var current = element
        for _ in 0...3 {
            if read(current, kAXRoleAttribute).value as? String == "AXDockItem" { element = current; break }
            guard let parent = read(current, kAXParentAttribute).value, CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
            current = parent as! AXUIElement
        }
        let role = read(element, kAXRoleAttribute)
        let subrole = read(element, kAXSubroleAttribute)
        let url = read(element, kAXURLAttribute)
        return DockItem(role: role.value as? String, subrole: subrole.value as? String,
                        url: (url.value as? URL) ?? (url.value as? String).flatMap(URL.init(string:)),
                        readFailed: role.failed || subrole.failed || url.failed)
    }

    /// A point whose window the window server will not describe (live 2026-10-31: Clicky's own
    /// status item came back as a window number `CGWindowListCopyWindowInfo` lists nothing for),
    /// owned by the AX element's process instead: `layer` is unknown, so the surface reads `other`.
    static func unlistedWindow(owner: Owner) -> WindowAtPoint {
        WindowAtPoint(number: 0, ownerPID: owner.pid, ownerBundle: owner.bundle,
                      ownerName: NSRunningApplication(processIdentifier: owner.pid)?.localizedName, layer: 1, bounds: .zero)
    }

    /// The process that owns the AX element at a point, when the hit test named nothing — or the
    /// window server named no window: a status icon with no name still belongs to its app, and that
    /// app's policy still applies. The process only; no name is read.
    static func axOwner(at point: CGPoint, primaryDisplayHeight: CGFloat) -> Owner? {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, RealtimeScreenHitTest.messagingTimeoutSeconds)
        let topLeft = topLeft(point, primaryDisplayHeight: primaryDisplayHeight)
        var element: AXUIElement?
        var pid: pid_t = 0
        guard AXUIElementCopyElementAtPosition(systemWide, Float(topLeft.x), Float(topLeft.y), &element) == .success, let element,
              AXUIElementGetPid(element, &pid) == .success, pid > 0 else { return nil }
        return Owner(pid: pid, bundle: NSRunningApplication(processIdentifier: pid)?.bundleIdentifier)
    }

    /// Every on-screen window as number -> "owner (layer N)": the evidence baseline. The cursor's
    /// own windows (cursor level, measured 2026-10-31: two 28x28 Window Server windows appear on every
    /// pointer move) are left out, or every move would "open a window".
    static func onScreenWindows() -> [Int: String] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let cursorLevel = Int(CGWindowLevelForKey(.cursorWindow))
        var windows: [Int: String] = [:]
        for info in list {
            guard let number = (info[kCGWindowNumber as String] as? NSNumber)?.intValue,
                  (info[kCGWindowLayer as String] as? NSNumber)?.intValue != cursorLevel else { continue }
            let owner = (info[kCGWindowOwnerName as String] as? String).map(HarnessPolicy.cappedAuditTarget) ?? "unknown"
            windows[number] = "\(owner) (layer \((info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0))"
        }
        return windows
    }

    static var screenIsLocked: Bool {
        (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool == true
            || LockScreenGuard.isLockScreen(AccessibilityTreeWalker.focusedApplication()?.bundleIdentifier)
    }

    // MARK: Posted events (top-left points)

    private static func post(_ type: CGEventType, at point: CGPoint, button: CGMouseButton, clickState: Int64 = 1,
                             source: CGEventSource) -> Bool {
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button) else { return false }
        // A held modifier must not turn a click into a Cmd-click or a Ctrl-click.
        event.flags = []
        event.setIntegerValueField(.mouseEventClickState, value: clickState)
        event.post(tap: .cghidEventTap)
        HarnessHands.ownInput.mark()
        return true
    }

    enum Performed: Equatable {
        case sent
        case eventFailed
        /// The drop point no longer showed what was judged; the drag was carried back and cancelled.
        case dropAborted
    }

    /// The action's events at `from` (and `to` for a drag). `dropStillValid` is asked with the button
    /// still down over `to`: false carries the drag back to `from`, cancels it with Escape, and
    /// releases there — nothing is dropped where it was not judged.
    static func perform(_ action: PointerAction, at from: CGPoint, to: CGPoint?, scroll: (direction: ScrollDirection, steps: Int)?,
                        dropStillValid: (() -> Bool)? = nil) -> Performed {
        func sent(_ posted: Bool) -> Performed { posted ? .sent : .eventFailed }
        guard let source = CGEventSource(stateID: .hidSystemState) else { return .eventFailed }
        func pause(_ seconds: Double) { Thread.sleep(forTimeInterval: seconds) }
        switch action {
        case .move:
            return sent(HarnessHands.postMouseMove(atTopLeft: from))
        case .click:
            return sent(HarnessHands.postClick(atTopLeft: from))
        case .rightClick:
            guard post(.rightMouseDown, at: from, button: .right, source: source) else { return .eventFailed }
            pause(0.03)
            return sent(post(.rightMouseUp, at: from, button: .right, source: source))
        case .doubleClick:
            for state in [Int64(1), 2] {
                guard post(.leftMouseDown, at: from, button: .left, clickState: state, source: source) else { return .eventFailed }
                pause(0.03)
                guard post(.leftMouseUp, at: from, button: .left, clickState: state, source: source) else { return .eventFailed }
                pause(0.06)
            }
            return .sent
        case .drag:
            guard let to else { return .eventFailed }
            guard post(.leftMouseDown, at: from, button: .left, source: source) else { return .eventFailed }
            // Finder starts a drag only after the button has been down a moment and moved a few points.
            pause(0.15)
            let steps = 12
            for step in 1...steps {
                let t = CGFloat(step) / CGFloat(steps)
                guard post(.leftMouseDragged, at: CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t),
                           button: .left, source: source) else {
                    _ = post(.leftMouseUp, at: from, button: .left, source: source)
                    return .eventFailed
                }
                pause(0.025)
            }
            // A drop target highlights on hover before it accepts.
            pause(0.2)
            if let dropStillValid, !dropStillValid() {
                for step in 1...6 {
                    let t = CGFloat(step) / 6
                    _ = post(.leftMouseDragged, at: CGPoint(x: to.x + (from.x - to.x) * t, y: to.y + (from.y - to.y) * t), button: .left, source: source)
                    pause(0.025)
                }
                HarnessKeys.post(KeyChord(key: "escape"))
                pause(0.05)
                _ = post(.leftMouseUp, at: from, button: .left, source: source)
                return .dropAborted
            }
            return sent(post(.leftMouseUp, at: to, button: .left, source: source))
        case .scroll:
            guard let scroll else { return .eventFailed }
            HarnessHands.postMouseMove(atTopLeft: from)
            return sent(SyntheticScroller.scroll(atTopLeftPoint: from, wheelDelta: scroll.direction.pageDirection.syntheticWheelDelta,
                                                 steps: scroll.steps, horizontal: scroll.direction.isHorizontal))
        }
    }
}
