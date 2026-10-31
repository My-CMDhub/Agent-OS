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
        /// Return/Enter: judged as the window's default button, or as a submit from a text field.
        case returnKey
        /// Space: posted, but a focused named button is judged first — Space presses it.
        case space
        /// Anything else asks (owner: an unknown shortcut may do anything).
        case ask(reason: String)
    }

    static func unmatched(_ chord: KeyChord) -> Unmatched {
        if chord.key == "space", chord.isPlain { return .space }
        if navigationKeys.contains(chord.key), !chord.hasShortcutModifier { return .post }
        if chord.key == "return" || chord.key == "enter", chord.isPlain { return .returnKey }
        return .ask(reason: "\(chord.display) is not a shortcut of any menu item in this app, so what it does is unknown")
    }

    /// Return with the focus where it is: the default button's press when the window
    /// has one (its title through the kernel, as a press of it); a submit from a text
    /// field (`gatingSubmit`, the rule `type` + AXConfirm follows: a sending app asks);
    /// otherwise nothing a card protects.
    static func returnDecision(defaultButtonTitle: String?, focusIsTextInput: Bool, bundleIdentifier: String?,
                               visibleBounds: CGRect, draftScope: Bool) -> SafetyDecision {
        if let title = defaultButtonTitle {
            return HarnessPointer.decision(action: .click, names: [title], label: nil, role: "AXButton", subrole: nil,
                                           frame: visibleBounds, visibleBounds: visibleBounds, ownerBundle: bundleIdentifier,
                                           draftScope: draftScope)
        }
        return focusIsTextInput ? ActionSafetyKernel.gatingSubmit(.allow, thenConfirm: true, bundleIdentifier: bundleIdentifier) : .allow
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

    /// The focused window's `AXDefaultButton` title, read live; nil when there is none.
    static func defaultButtonTitle(processIdentifier: pid_t) -> String? {
        let application = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.5)
        guard let window = HarnessServer.copyAttribute(application, kAXFocusedWindowAttribute),
              CFGetTypeID(window) == AXUIElementGetTypeID(),
              let button = HarnessServer.copyAttribute(window as! AXUIElement, kAXDefaultButtonAttribute),
              CFGetTypeID(button) == AXUIElementGetTypeID() else { return nil }
        let element = button as! AXUIElement
        let name = (HarnessServer.copyAttribute(element, kAXTitleAttribute) as? String)
            ?? (HarnessServer.copyAttribute(element, kAXDescriptionAttribute) as? String)
        // A default button with no name still presses something: judged as "an unnamed default button".
        return name?.isEmpty == false ? name : "an unnamed default button"
    }

    /// The focused element's role, read live (never its value).
    static func focusedRole(processIdentifier: pid_t) -> String? {
        HarnessHands.focusedElement(processIdentifier: processIdentifier)
            .flatMap { HarnessServer.copyAttribute($0, kAXRoleAttribute) as? String }
    }
}
