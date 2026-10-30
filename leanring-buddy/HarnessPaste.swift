//
//  HarnessPaste.swift
//  leanring-buddy
//
//  Multi-line text, by the app's own Edit > Paste (owner's ruling 2026-10-10).
//
//  Return SENDS in a chat composer and runs a command in a terminal, and every
//  keystroke tool we read (xdotool, Playwright, Puppeteer, browser-use) types
//  `\n` as Return. A paste is a different event: no keydown, so no send. So a
//  text with a line break never goes by keystrokes or an AX write — it goes on
//  the pasteboard and the app's Paste item is pressed through AX, only into a
//  note or document editor, and the owner's clipboard is put back.
//  Design: docs/superpowers/research/2026-10-10-multiline-text-entry.md.
//

import AppKit
import ApplicationServices
import Foundation

enum HarnessPaste {

    // ponytail: allowlist by bundle; probe each app live before adding any. No
    // terminal, chat, mail or browser app belongs here — Return sends or runs there.
    static let pasteLineBreakEditors: Set<String> = [
        "com.apple.TextEdit", "com.apple.Notes", "com.apple.iWork.Pages", "com.apple.Stickies"
    ]

    // MARK: the boundary

    /// `\r\n` and a lone `\r` become `\n`, so one character means "line break".
    static func normalisedLineBreaks(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    /// Any control character but `\n` (Tab, Escape, U+2028...) — still refused everywhere.
    static func containsControlCharactersOtherThanLineFeed(_ text: String) -> Bool {
        HarnessHands.containsControlCharacters(text.replacingOccurrences(of: "\n", with: ""))
    }

    // MARK: the gate

    /// Why a line break may not be pasted here, or nil. A secret outranks everything.
    static func gateRefusal(bundleIdentifier: String?, role: String, mode: TypeMode, secureInputOn: Bool,
                            focusedMightBeSecure: Bool, focusIsOnTarget: Bool) -> HandsRefusal? {
        if secureInputOn {
            return HandsRefusal(code: "handOver", message: "secure typing is on — a password is the owner's to type; nothing was pasted")
        }
        if focusedMightBeSecure || role == "AXSecureTextField" {
            return HandsRefusal(code: "secureField", message: ActionSafetyKernel.unreadableSubroleTypeRefusalReason)
        }
        guard let bundleIdentifier, pasteLineBreakEditors.contains(bundleIdentifier) else {
            return HandsRefusal(code: "lineBreakNeedsDocumentEditor",
                                message: "a line break goes only into a note or document editor (TextEdit, Notes, Pages, Stickies); "
                                    + "anywhere else Return may send or run it. Nothing was typed — type one line at a time.")
        }
        // The right app, the wrong element. Launch M01 2026-10-17: aimed at "New Note" (a button) in Notes,
        // told "only a note editor, type one line at a time", Haiku typed title and body as two single
        // lines and they ran together ("JARVIS weatherSydney…"). Say where the line break CAN go.
        guard AccessibilityElementNode.textInputRoles.contains(role) else {
            return HandsRefusal(code: "lineBreakNeedsTextArea",
                                message: "that is a \(role), not the text itself; nothing was typed. A line break goes into the note's or "
                                    + "document's own text: call type_text again with the SAME text and no name to type where the keyboard "
                                    + "focus is, or aim it at the text area. Do not split the text into single lines.")
        }
        if mode == .replace {
            return HandsRefusal(code: "lineBreakInsertOnly", message: "multi-line text is inserted at the end, never replaces a field; nothing was pasted. "
                                    + "Call type_text again with mode insert to add it after what is there.")
        }
        if !focusIsOnTarget {
            return HandsRefusal(code: "fieldNotFocused",
                                message: "keyboard focus is not on the field, so a paste would land elsewhere; nothing was pasted")
        }
        return nil
    }

    /// Replacing an EMPTY field is inserting: nothing can be discarded. Launch M01 2026-10-17: Haiku typed
    /// a title and body into a brand-new note with mode replace and was refused `lineBreakInsertOnly`.
    /// Only a value read as empty counts (`stringValue` reads -25212 as ""); unreadable stays replace.
    static func pasteMode(_ mode: TypeMode, currentValue: String?) -> TypeMode {
        mode == .replace && currentValue == "" ? .insert : mode
    }

    // MARK: Edit > Paste, by its shortcut

    /// ⌘V with no other modifier — the character and mask, not the title, so a
    /// localised "Einsetzen" is found and "Paste and Match Style" (⌥⇧⌘V) is not.
    static let pasteShortcut = AccessibilityMenu.describeShortcut(character: "V", modifiers: 0)

    static func pasteMenuItem(in bar: AccessibilityMenu.Node,
                              children: (AccessibilityMenu.Node) -> [AccessibilityMenu.Node]) -> Result<AccessibilityMenu.Node, HandsRefusal> {
        let matches = menuItems(withShortcut: pasteShortcut, in: bar, children: children)
        guard matches.count == 1, let item = matches.first else {
            return .failure(HandsRefusal(code: "pasteUnavailable", message: matches.isEmpty
                ? "the app's menus have no ⌘V Paste item; nothing was pasted"
                : "\(matches.count) menu items carry ⌘V; nothing was pasted"))
        }
        // Not judged by AXEnabled here: Paste is enabled by what the CLIPBOARD holds, so the
        // owner's image greys it out for a text field until our text is written. `paste`
        // re-reads it after the write (G04 2026-10-11: pasteUnavailable 5x in one run).
        return .success(item)
    }

    /// Every menu item, one level under each bar item, whose shortcut is exactly `shortcut`.
    static func menuItems(withShortcut shortcut: String?, in bar: AccessibilityMenu.Node,
                          children: (AccessibilityMenu.Node) -> [AccessibilityMenu.Node]) -> [AccessibilityMenu.Node] {
        AccessibilityMenu.entries(of: bar, children: children)
            .flatMap { AccessibilityMenu.entries(of: $0, children: children) }
            .filter { $0.role == AccessibilityMenu.menuItemRole && $0.shortcut == shortcut }
    }

    // MARK: verification and restore

    private static func nonWhitespace(_ text: String) -> String { String(text.filter { !$0.isWhitespace }) }

    /// The field now holds the pasted text's non-whitespace characters, and grew
    /// by exactly that many. Whitespace is loose on purpose: an editor may store
    /// a line break as U+2028, a paragraph, or a space.
    static func pasteLanded(valueBefore: String, valueAfter: String?, pasted: String) -> Bool {
        guard let valueAfter else { return false }
        let before = nonWhitespace(valueBefore), after = nonWhitespace(valueAfter), text = nonWhitespace(pasted)
        return after.contains(text) && after.count - before.count == text.count
    }

    static let landedEvidence = "the field's text now holds the pasted text"

    enum RestoreDecision: String, Equatable {
        case restore = "restored"
        case keepNewer = "clipboardKeptNewerContents"
    }

    /// Restore only while the pasteboard is still what WE wrote: a newer change
    /// is the owner's copy, and overwriting it loses their data (Peekaboo's guard).
    static func restoreDecision(ourChangeCount: Int, currentChangeCount: Int) -> RestoreDecision {
        ourChangeCount == currentChangeCount ? .restore : .keepNewer
    }

    /// `NSPasteboard.AccessBehavior` raw value (nil before macOS 15.4). `.default`
    /// (0) is what an app that never raised an alert reads, so it passes only
    /// while the pasteboard-privacy preview is off; `.alwaysAllow` (2) always.
    /// From macOS 26 the privacy preview is simply on (toolchain review 2026-10-30: the SDK says the general pasteboard
    /// asks on programmatic access by default), so `.default` would raise a system alert or read nothing, and the
    /// restore would then wipe the owner's clipboard. Only `.alwaysAllow` passes there.
    static func pasteboardReadAllowed(behaviorRawValue: Int?, privacyPreviewOn: Bool,
                                      osMajorVersion: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion) -> Bool {
        switch behaviorRawValue {
        case nil, 2: return true
        case 0: return !privacyPreviewOn && osMajorVersion < 26
        default: return false
        }
    }

    static let privacyPreviewDefaultsKey = "EnablePasteboardPrivacyDeveloperPreview"
    static let markerTypes = [NSPasteboard.PasteboardType("org.nspasteboard.TransientType"),
                              NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType")]
    static let verifySeconds = 2.0

    // MARK: the live part

    enum Outcome {
        case refused(HandsRefusal)
        /// `payload` carries counts and lengths only — never a byte of the clipboard.
        case pasted(payload: [String: Any], verified: Bool)
    }

    /// Every item, every type's data — in memory only, never logged or sent.
    static func snapshot(_ pasteboard: NSPasteboard) -> [[(NSPasteboard.PasteboardType, Data)]] {
        (pasteboard.pasteboardItems ?? []).map { item in item.types.compactMap { type in item.data(forType: type).map { (type, $0) } } }
    }

    static func restore(_ saved: [[(NSPasteboard.PasteboardType, Data)]], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let items = saved.map { entries -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in entries { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { pasteboard.writeObjects(items) }
    }

    /// Plain text, this Mac only (no Universal Clipboard), marked transient so
    /// clipboard managers skip it. Returns our changeCount.
    private static func write(_ text: String, to pasteboard: NSPasteboard) -> Int {
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        pasteboard.setString(text, forType: .string)
        for marker in markerTypes { pasteboard.setData(Data(), forType: marker) }
        return pasteboard.changeCount
    }

    /// The gate already passed. Never presses Return, never falls back to keystrokes.
    /// How long Paste may take to enable once our text is on the clipboard. Notes re-checks
    /// the clipboard on a ~1 s cycle, not on the write: measured 2026-10-15, 5/5 writes onto an
    /// empty clipboard enabled Paste 689-704 ms later and a clear disabled it 1,003-1,016 ms
    /// later. The old 0.3 s caught it only when Paste was already on (G04/G21 pasteUnavailable).
    static let enabledAfterWriteSeconds = 1.5

    static func paste(_ text: String, into element: AXUIElement, application: NSRunningApplication,
                      secureInput: () -> SecureInputState) -> Outcome {
        let processIdentifier = application.processIdentifier
        let pasteboard = NSPasteboard.general
        var behavior: Int?
        if #available(macOS 15.4, *) { behavior = pasteboard.accessBehavior.rawValue }
        guard pasteboardReadAllowed(behaviorRawValue: behavior,
                                    privacyPreviewOn: UserDefaults.standard.bool(forKey: privacyPreviewDefaultsKey)) else {
            return .refused(HandsRefusal(code: "pasteboardAccessNotAllowed",
                                         message: "this Mac asks before an app reads the clipboard, so it was not saved or used; nothing was pasted"))
        }
        // Found before the clipboard is touched: an app with no enabled Paste costs nothing.
        guard let bar = AccessibilityMenu.menuBarNode(for: application) else {
            return .refused(HandsRefusal(code: "pasteUnavailable", message: "the app publishes no menu bar; nothing was pasted"))
        }
        let item: AccessibilityMenu.Node
        switch pasteMenuItem(in: bar, children: AccessibilityMenu.liveChildren) {
        case .failure(let refusal): return .refused(refusal)
        case .success(let found): item = found
        }
        guard let itemElement = item.element else {
            return .refused(HandsRefusal(code: "pasteUnavailable", message: "the Paste item could not be read; nothing was pasted"))
        }
        // Unreadable is not empty: without the text before, the paste cannot be verified.
        AXUIElementSetMessagingTimeout(element, AccessibilityTypePerformer.typingTimeoutInSeconds)
        guard let valueBefore = AccessibilityTypePerformer.stringValue(of: element) else {
            return .refused(HandsRefusal(code: "valueUnreadable", message: "the field's text could not be read, so a paste could not be verified; nothing was pasted"))
        }
        // A paste replaces the selection, like an AXSelectedText write: caret to the end first.
        if let refusal = AccessibilityTypePerformer.caretAtEnd(of: element, valueBefore: valueBefore) {
            return .refused(HandsRefusal(code: "selectionNotEmpty", message: refusal))
        }
        // The last look before the owner's clipboard is touched.
        if secureInput().isOn {
            return .refused(HandsRefusal(code: "handOver", message: "secure typing is on — a password is the owner's to type; nothing was pasted"))
        }
        guard HarnessHands.targetIsFrontmost(processIdentifier) else { return .refused(HarnessHands.frontmostChangedRefusal) }

        let saved = snapshot(pasteboard)
        let ours = write(text, to: pasteboard)
        // Enabled is judged now, with our text on the clipboard; still disabled -> put the
        // owner's clipboard back and refuse (a disabled item "succeeds" and does nothing).
        let enabled = HarnessHands.waitUntil(seconds: enabledAfterWriteSeconds) {
            var value: AnyObject?
            return AXUIElementCopyAttributeValue(itemElement, kAXEnabledAttribute as CFString, &value) == .success && (value as? Bool) == true
        }
        guard enabled else {
            if restoreDecision(ourChangeCount: ours, currentChangeCount: pasteboard.changeCount) == .restore { restore(saved, to: pasteboard) }
            return .refused(HandsRefusal(code: "pasteUnavailable",
                                         message: "the app's Paste item stayed disabled with the text on the clipboard; nothing was pasted"))
        }
        let startedAt = Date()
        let press = AccessibilityActionPerformer.perform(kAXPressAction, on: itemElement)
        // Polled even after an error: -25204 "does not necessarily mean the function has failed".
        var valueAfter: String?
        let landed = HarnessHands.waitUntil(seconds: verifySeconds) {
            valueAfter = AccessibilityTypePerformer.stringValue(of: element)
            return pasteLanded(valueBefore: valueBefore, valueAfter: valueAfter, pasted: text)
        }
        let decision = restoreDecision(ourChangeCount: ours, currentChangeCount: pasteboard.changeCount)
        if decision == .restore { restore(saved, to: pasteboard) }

        return .pasted(payload: [
            "status": press.error == .success ? "sent" : "failed",
            "method": "paste",
            "axErrorRawValue": press.error.rawValue,
            "milliseconds": Int(Date().timeIntervalSince(startedAt) * 1000),
            "pastedLength": text.count,
            "lineCount": text.split(separator: "\n", omittingEmptySubsequences: false).count,
            "valueLengthBefore": valueBefore.count,
            "valueLengthAfter": valueAfter.map { $0.count as Any } ?? NSNull(),
            "clipboard": ["itemsSaved": saved.count, "typesSaved": saved.reduce(0) { $0 + $1.count }, "outcome": decision.rawValue]
        ], verified: landed)
    }
}
