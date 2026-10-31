//
//  HarnessKeys.swift
//  leanring-buddy
//
//  `key`: a keyboard shortcut or navigation key for the front app (owner's ruling
//  2026-10-31). A shortcut is first resolved to the menu item that owns it and pressed
//  through the guarded `menu` path — the kernel judges that item's title exactly as a
//  `menu` request's, and it is verified as menus are — because most shortcuts have a
//  menu item behind them (CLAUDE.md: press that instead of synthesising keys). Only
//  what no menu item owns is posted as a key event, and of that only navigation keys
//  go without a card.
//
//  This file is the pure half: parsing, menu matching, the route. The live half is
//  `HarnessServer.keyResponse`.
//

import AppKit
import ApplicationServices
import Foundation

/// One parsed `keys` string: "cmd+shift+d", "escape", "shift+tab", "page down".
struct KeyChord: Equatable {
    var command = false
    var shift = false
    var option = false
    var control = false
    /// Canonical key: a single character ("d", "1", "/"), or a name from `HarnessKeys.namedKeys`.
    let key: String

    var hasShortcutModifier: Bool { command || option || control }
    var isPlain: Bool { !command && !shift && !option && !control }

    /// `AXMenuItemCmdModifiers`' encoding: Shift 1, Option 2, Control 4, and 8 means NO Command.
    var menuModifierMask: Int { (shift ? 1 : 0) | (option ? 2 : 0) | (control ? 4 : 0) | (command ? 0 : 8) }

    /// The character a menu item publishes as `AXMenuItemCmdChar` for this key.
    var menuCharacter: String { HarnessKeys.menuCharacters[key] ?? key }

    /// As a menu shows it ("⇧⌘D"), the form `AccessibilityMenu` lists shortcuts in — so a
    /// match is a string comparison against what `menus` already reports.
    var display: String {
        AccessibilityMenu.describeShortcut(character: menuCharacter, modifiers: menuModifierMask)
            ?? key
    }
}

enum HarnessKeys {

    /// Named keys: canonical name -> US-ANSI virtual key code.
    static let namedKeys: [String: CGKeyCode] = [
        "return": 36, "enter": 76, "tab": 48, "space": 49, "delete": 51, "escape": 53, "forwarddelete": 117,
        "home": 115, "end": 119, "pageup": 116, "pagedown": 121, "left": 123, "right": 124, "down": 125, "up": 126,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100, "f9": 101, "f10": 109,
        "f11": 103, "f12": 111
    ]

    static let aliases: [String: String] = [
        "esc": "escape", "ret": "return", "backspace": "delete", "del": "forwarddelete", "pgup": "pageup", "pgdn": "pagedown",
        "pagedn": "pagedown", "arrowup": "up", "arrowdown": "down", "arrowleft": "left", "arrowright": "right",
        "uparrow": "up", "downarrow": "down", "leftarrow": "left", "rightarrow": "right", "spacebar": "space"
    ]

    /// Single characters, US-ANSI. ponytail: a non-US layout puts some of these on other
    /// keys; menu-matched shortcuts are unaffected (they are pressed, not typed).
    static let characterKeys: [Character: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
        "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25,
        "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38,
        "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "`": 50
    ]

    /// What a menu publishes as its cmd char for a named key (AppKit's NS*FunctionKey
    /// private-use characters for arrows and F-keys, control characters for the rest).
    static let menuCharacters: [String: String] = [
        "return": "\r", "enter": "\u{3}", "tab": "\t", "space": " ", "delete": "\u{8}", "escape": "\u{1b}",
        "forwarddelete": "\u{7f}", "up": "\u{F700}", "down": "\u{F701}", "left": "\u{F702}", "right": "\u{F703}",
        "home": "\u{F729}", "end": "\u{F72B}", "pageup": "\u{F72C}", "pagedown": "\u{F72D}",
        "f1": "\u{F704}", "f2": "\u{F705}", "f3": "\u{F706}", "f4": "\u{F707}", "f5": "\u{F708}", "f6": "\u{F709}",
        "f7": "\u{F70A}", "f8": "\u{F70B}", "f9": "\u{F70C}", "f10": "\u{F70D}", "f11": "\u{F70E}", "f12": "\u{F70F}"
    ]

    /// Keys that move focus, selection or scroll position and act on nothing by
    /// themselves: posted without a card when no menu item owns them.
    static let navigationKeys: Set<String> = ["up", "down", "left", "right", "tab", "escape", "space", "pageup", "pagedown", "home", "end"]

    /// nil for anything that is not exactly modifiers and one key.
    static func parse(_ text: String) -> KeyChord? {
        let pieces = text.lowercased().split(separator: "+", omittingEmptySubsequences: false)
            .map { $0.filter { $0 != " " && $0 != "_" } }
        guard let last = pieces.last, !last.isEmpty, pieces.dropLast().allSatisfy({ !$0.isEmpty }) else { return nil }
        let name = aliases[last] ?? last
        let key: String
        if namedKeys[name] != nil {
            key = name
        } else if name.count == 1, let character = name.first, characterKeys[character] != nil {
            key = name
        } else {
            return nil
        }
        var chord = KeyChord(key: key)
        for modifier in pieces.dropLast() {
            switch modifier {
            case "cmd", "command", "⌘", "meta": chord.command = true
            case "shift", "⇧": chord.shift = true
            case "opt", "option", "alt", "⌥": chord.option = true
            case "ctrl", "control", "⌃": chord.control = true
            default: return nil
            }
        }
        return chord
    }

    static func keyCode(for chord: KeyChord) -> CGKeyCode? {
        namedKeys[chord.key] ?? chord.key.first.flatMap { characterKeys[$0] }
    }

    /// Whether the front app's menus are asked first. A plain key and a Shift-only
    /// navigation key (Shift-Tab) are not: menus own shortcuts, not bare arrows.
    static func asksMenus(_ chord: KeyChord) -> Bool {
        chord.hasShortcutModifier || (chord.shift && !navigationKeys.contains(chord.key))
    }

    /// The listed menu items whose shortcut is this chord. Several matches settle on the
    /// one enabled item; more than one enabled is never a coin flip.
    static func menuMatch(_ chord: KeyChord, in items: [AccessibilityMenu.ListedItem]) -> MenuMatch {
        let matches = items.filter { $0.shortcut == chord.display && !$0.hasSubmenu }
        if matches.count == 1 { return .one(matches[0].path) }
        let enabled = matches.filter(\.isEnabled)
        if enabled.count == 1 { return .one(enabled[0].path) }
        return matches.isEmpty ? .none : .ambiguous(matches.map { $0.path.joined(separator: " > ") })
    }

    enum MenuMatch: Equatable {
        case none
        case one([String])
        case ambiguous([String])
    }

    /// What `key` does with a chord no menu item owns.
    enum Unmatched: Equatable {
        /// Posted with no card: a navigation key, alone or with Shift.
        case post
        /// Return/Enter: judged as what it presses (`returnDecision`).
        case returnKey
        /// Space, alone or with Shift: judged as a press of the focused control (`pressDecision`).
        case space
        /// Asked, Allow once only (`destructive`): an unknown shortcut may do anything, and a
        /// menu item publishing its shortcut as a glyph or virtual key is invisible to the match.
        case ask(reason: String)
        /// Never posted: a human presses this one.
        case refuse(reason: String)
    }

    static func unmatched(_ chord: KeyChord) -> Unmatched {
        if chord.key == "space", !chord.hasShortcutModifier { return .space }
        if navigationKeys.contains(chord.key), !chord.hasShortcutModifier { return .post }
        if chord.key == "return" || chord.key == "enter", chord.isPlain { return .returnKey }
        // Command or Option with Delete deletes (Finder's ⌘⌫ Move to Bin) or empties the bin (⌥⇧⌘⌫, a hidden
        // alternate a listing does not show): unmatched, it is never posted blind (security review 2026-10-31).
        if chord.key == "delete" || chord.key == "forwarddelete", chord.command || chord.option {
            return .refuse(reason: "\(chord.display) deletes in most apps (Empty Bin is \u{2325}\u{21E7}\u{2318}\u{232B}) and no menu item owning it was found — a human presses this one")
        }
        return .ask(reason: "\(chord.display) is not a shortcut of any menu item in this app, so what it does is unknown")
    }

    /// The decision for an unmatched chord that is not posted freely: asked once (never "Always"), or refused.
    static func unmatchedDecision(_ route: Unmatched) -> SafetyDecision? {
        switch route {
        case .ask(let reason): return .requireConfirmation(reason: reason, destructive: true)
        case .refuse(let reason): return .refuse(reason: reason)
        case .post, .returnKey, .space: return nil
        }
    }

    /// A read of the focused element, for what Return or Space presses. Never its value.
    /// `unreadable` is a failed read — never "nothing focused" (read failures are never absence).
    enum FocusRead: Equatable {
        case none
        case unreadable
        case element(role: String, name: String?)
    }

    /// A read of the focused window's `AXDefaultButton`, failure kept apart from absence.
    enum DefaultButtonRead: Equatable {
        case none
        case unreadable
        case button(name: String?)
    }

    /// What a key pressing the focused element decides: a control Return or Space presses is
    /// judged by its name exactly as a click on it is (`HarnessPointer.decision`); unnamed, or a
    /// failed read, it is asked — what it presses is unknown. nil: not a control (nothing to judge).
    /// Security review 2026-10-31: a web page publishes no AXDefaultButton, so tab-tab-Return on
    /// "Delete account" went out unjudged.
    static func pressDecision(_ focus: FocusRead, bundleIdentifier: String?, visibleBounds: CGRect, draftScope: Bool) -> SafetyDecision? {
        switch focus {
        case .none:
            return nil
        case .unreadable:
            return .requireConfirmation(reason: "the focused element could not be read, so what the key presses is unknown")
        case .element(let role, let name):
            guard HarnessHands.activeRoles.contains(role), !AccessibilityElementNode.textInputRoles.contains(role) else { return nil }
            guard let name, !name.isEmpty else {
                return .requireConfirmation(reason: "the focused \(role) has no name, so what the key presses is unknown")
            }
            return HarnessPointer.decision(action: .click, names: [name], label: nil, role: role, subrole: nil, frame: visibleBounds,
                                           visibleBounds: visibleBounds, ownerBundle: bundleIdentifier, draftScope: draftScope)
        }
    }

    /// Return with the focus where it is: the window's default button's press (its name through the
    /// kernel; unnamed or unreadable, asked); else a submit from a text field (`gatingSubmit`, the
    /// rule `type` + AXConfirm follows: a sending app asks); else the focused control's press
    /// (`pressDecision`); else nothing a card protects.
    static func returnDecision(defaultButton: DefaultButtonRead, focus: FocusRead, bundleIdentifier: String?,
                               visibleBounds: CGRect, draftScope: Bool) -> SafetyDecision {
        switch defaultButton {
        case .unreadable:
            return .requireConfirmation(reason: "the window's default button could not be read, so what Return presses is unknown")
        case .button(let name?) where !name.isEmpty:
            return HarnessPointer.decision(action: .click, names: [name], label: nil, role: "AXButton", subrole: nil,
                                           frame: visibleBounds, visibleBounds: visibleBounds, ownerBundle: bundleIdentifier,
                                           draftScope: draftScope)
        case .button:
            return .requireConfirmation(reason: "the window's default button has no name, so what Return presses is unknown")
        case .none:
            break
        }
        if case .element(let role, _) = focus, AccessibilityElementNode.textInputRoles.contains(role) || role == "AXWebArea" {
            return ActionSafetyKernel.gatingSubmit(.allow, thenConfirm: true, bundleIdentifier: bundleIdentifier)
        }
        return pressDecision(focus, bundleIdentifier: bundleIdentifier, visibleBounds: visibleBounds, draftScope: draftScope) ?? .allow
    }

    // MARK: Live

    /// One key down/up with its modifiers, at the HID tap (the front app receives it).
    @discardableResult
    static func post(_ chord: KeyChord) -> Bool {
        guard let code = keyCode(for: chord), let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) else { return false }
        var flags: CGEventFlags = []
        if chord.command { flags.insert(.maskCommand) }
        if chord.shift { flags.insert(.maskShift) }
        if chord.option { flags.insert(.maskAlternate) }
        if chord.control { flags.insert(.maskControl) }
        down.flags = flags
        up.flags = flags
        HarnessHands.ownInput.mark()
        down.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.02)
        up.post(tap: .cghidEventTap)
        HarnessHands.ownInput.mark()
        return true
    }

    /// What the response's `judged` says and what a ticket binds (`title`) for Return / Space.
    static func judgement(_ chord: KeyChord, route: Unmatched, defaultButton: DefaultButtonRead, focus: FocusRead) -> (judged: String, target: String) {
        if route == .returnKey {
            switch defaultButton {
            case .button(let name): return ("default button", "\(chord.display) \u{2014} presses \u{201C}\(name ?? "an unnamed default button")\u{201D}")
            case .unreadable: return ("unreadable default button", chord.display)
            case .none: break
            }
        }
        switch focus {
        case .unreadable:
            return ("unreadable focus", chord.display)
        case .element(let role, _) where route == .returnKey
            && (AccessibilityElementNode.textInputRoles.contains(role) || role == "AXWebArea"):
            return ("submit", "\(chord.display) \u{2014} submits the focused field")
        case .element(let role, let name) where HarnessHands.activeRoles.contains(role) && !AccessibilityElementNode.textInputRoles.contains(role):
            return ("focused control", "\(chord.display) \u{2014} presses \u{201C}\(name ?? "an unnamed \(role)")\u{201D}")
        default:
            return ("navigation", chord.display)
        }
    }

    /// The same element (or both none) by identity, the way a ticket's binding compares.
    static func sameElement(_ a: AXUIElement?, _ b: AXUIElement?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (a?, b?): return CFEqual(a, b)
        default: return false
        }
    }

    /// One attribute: its value, or whether it is ABSENT (no value / unsupported) — any other error is neither.
    private static func read(_ element: AXUIElement, _ attribute: String) -> (value: AnyObject?, absent: Bool) {
        var value: AnyObject?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        if error == .success { return (value, false) }
        return (nil, error == .noValue || error == .attributeUnsupported)
    }

    private static func element(_ value: AnyObject?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    /// A control's name as the walk names it, never its value: title, description, label link.
    static func controlName(_ element: AXUIElement) -> String? {
        [HarnessServer.copyAttribute(element, kAXTitleAttribute) as? String,
         HarnessServer.copyAttribute(element, kAXDescriptionAttribute) as? String,
         AccessibilityTreeWalker.copyLabelLinkText(from: element)].compactMap { $0 }.first { !$0.isEmpty }
    }

    /// The focused window's `AXDefaultButton`, read live.
    static func defaultButtonRead(processIdentifier: pid_t) -> DefaultButtonRead {
        let application = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.5)
        let window = read(application, kAXFocusedWindowAttribute)
        if window.absent { return .none }
        guard let windowElement = element(window.value) else { return .unreadable }
        AXUIElementSetMessagingTimeout(windowElement, 0.5)
        let button = read(windowElement, kAXDefaultButtonAttribute)
        if button.absent { return .none }
        guard let buttonElement = element(button.value) else { return .unreadable }
        return .button(name: controlName(buttonElement))
    }

    /// The focused element and what it is, read live: the element too, so the last moment before the
    /// key is posted can check it is still the one judged.
    static func focusRead(processIdentifier: pid_t) -> (read: FocusRead, element: AXUIElement?) {
        let application = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.5)
        let focused = read(application, kAXFocusedUIElementAttribute)
        if focused.absent { return (.none, nil) }
        guard let focusedElement = element(focused.value) else { return (.unreadable, nil) }
        AXUIElementSetMessagingTimeout(focusedElement, 0.5)
        guard let role = read(focusedElement, kAXRoleAttribute).value as? String else { return (.unreadable, focusedElement) }
        return (.element(role: role, name: controlName(focusedElement)), focusedElement)
    }
}

