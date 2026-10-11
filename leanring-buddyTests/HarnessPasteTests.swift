//
//  HarnessPasteTests.swift
//  leanring-buddyTests
//
//  Multi-line text by paste (owner's ruling 2026-10-10): a line break is allowed
//  only into a note or document editor, by Edit > Paste, never by Return. The
//  pure halves only — whether the pasteboard and the menu press land is proven
//  live by the coordinator. Fixtures are SYNTHETIC.
//

import ApplicationServices
import Foundation
import Testing
@testable import Clicky

struct HarnessPasteTests {

    /// G21 2026-10-11: a new Notes note's body answers AXValue -25212 (no value), so the
    /// paste refused it as unreadable twice. Empty is "", every other error is unreadable.
    @Test func aFieldWithNoValueIsEmptyNotUnreadable() {
        #expect(AccessibilityTypePerformer.stringValue(error: .noValue, value: nil) == "")
        #expect(AccessibilityTypePerformer.stringValue(error: .success, value: "hello" as NSString) == "hello")
        #expect(AccessibilityTypePerformer.stringValue(error: .cannotComplete, value: nil) == nil)
        #expect(AccessibilityTypePerformer.stringValue(error: .attributeUnsupported, value: nil) == nil)
        #expect(AccessibilityTypePerformer.stringValue(error: .success, value: 1 as NSNumber) == nil)
    }

    private func decodeType(_ text: String, extra: [String: Any] = [:]) -> Result<HarnessRequest, HarnessRequestError> {
        var object: [String: Any] = ["verb": "type", "target": "focused", "text": text]
        object.merge(extra) { _, new in new }
        return HarnessPolicy.decode(line: String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self))
    }

    // MARK: the boundary

    @Test func aLineBreakIsAcceptedAtTheBoundaryAndNormalisedToLineFeed() {
        for (sent, kept) in [("one\ntwo", "one\ntwo"), ("one\r\ntwo", "one\ntwo"), ("one\rtwo", "one\ntwo"), ("a\r\n\r\nb\n", "a\n\nb\n")] {
            guard case .success(let request) = decodeType(sent) else { Issue.record("\(sent.debugDescription) was refused"); continue }
            #expect(request.text == kept)
        }
    }

    @Test func everyOtherControlCharacterIsStillRefusedAtTheBoundary() {
        for text in ["tab\there", "beep\u{7}", "a\u{2028}b", "a\u{2029}b", "esc\u{1b}", "one\ntwo\tthree"] {
            guard case .failure(let error) = decodeType(text) else { Issue.record("\(text.debugDescription) decoded"); continue }
            #expect(error.code == "invalidField")
        }
    }

    /// AXConfirm after a multi-line paste is a submit by another name; a forced
    /// method would route a line break to keystrokes or an AX write.
    @Test func aLineBreakNeverRidesWithConfirmOrAForcedMethod() {
        for extra in [["thenConfirm": true], ["method": "keystrokes"], ["method": "axWrite"]] as [[String: Any]] {
            guard case .failure(let error) = decodeType("one\ntwo", extra: extra) else { Issue.record("\(extra) decoded"); continue }
            #expect(error.code == "invalidField")
        }
        guard case .success = decodeType("one line", extra: ["method": "keystrokes"]) else { Issue.record("one line refused"); return }
    }

    // MARK: the gate

    private func gate(_ bundle: String?, role: String = "AXTextArea", mode: TypeMode = .insert, secureInputOn: Bool = false,
                      focusedMightBeSecure: Bool = false, focusIsOnTarget: Bool = true) -> HandsRefusal? {
        HarnessPaste.gateRefusal(bundleIdentifier: bundle, role: role, mode: mode, secureInputOn: secureInputOn,
                                 focusedMightBeSecure: focusedMightBeSecure, focusIsOnTarget: focusIsOnTarget)
    }

    @Test func onlyANoteOrDocumentEditorTakesALineBreak() {
        for bundle in ["com.apple.TextEdit", "com.apple.Notes", "com.apple.iWork.Pages", "com.apple.Stickies"] {
            #expect(gate(bundle) == nil, "\(bundle)")
        }
        // Chat, mail and browser composers keep refusing: Return sends there.
        for bundle in ["com.apple.MobileSMS", "com.apple.mail", "net.whatsapp.WhatsApp", "com.tinyspeck.slackmacgap",
                       "com.google.Chrome", "com.apple.Safari", "com.hnc.Discord", nil] as [String?] {
            #expect(gate(bundle)?.code == "lineBreakNeedsDocumentEditor", "\(bundle ?? "nil")")
        }
    }

    @Test func noTerminalIsEverAnEditor() {
        let terminals = ["com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.mitchellh.ghostty",
                         "net.kovidgoyal.kitty", "io.alacritty"]
        #expect(HarnessPaste.pasteLineBreakEditors.isDisjoint(with: terminals))
        for terminal in terminals { #expect(gate(terminal)?.code == "lineBreakNeedsDocumentEditor") }
    }

    @Test func theGateRefusesASecretAFieldOutOfFocusAndAReplace() {
        #expect(gate("com.apple.Notes", secureInputOn: true)?.code == "handOver")
        #expect(gate("com.apple.Notes", focusedMightBeSecure: true)?.code == "secureField")
        #expect(gate("com.apple.Notes", role: "AXSecureTextField")?.code == "secureField")
        #expect(gate("com.apple.Notes", role: "AXButton")?.code == "lineBreakNeedsDocumentEditor")
        #expect(gate("com.apple.Notes", focusIsOnTarget: false)?.code == "fieldNotFocused")
        #expect(gate("com.apple.Notes", mode: .replace)?.code == "lineBreakInsertOnly")
        // A secret outranks the allowlist: refused as a secret even in a chat app.
        #expect(gate("com.apple.MobileSMS", secureInputOn: true)?.code == "handOver")
    }

    // MARK: Edit > Paste, found by its shortcut

    private func item(_ label: String, _ character: String?, _ modifiers: Int = 0, enabled: Bool = true) -> AccessibilityMenu.Node {
        AccessibilityMenu.Node(label: label, role: AccessibilityMenu.menuItemRole, isEnabled: enabled,
                               shortcut: AccessibilityMenu.describeShortcut(character: character, modifiers: modifiers))
    }

    private func bar(_ menus: [(String, [AccessibilityMenu.Node])]) -> AccessibilityMenu.Node {
        AccessibilityMenu.Node(label: nil, role: AccessibilityMenu.menuBarRole, children: menus.map { title, items in
            AccessibilityMenu.Node(label: title, role: AccessibilityMenu.menuBarItemRole, children: [
                AccessibilityMenu.Node(label: nil, role: AccessibilityMenu.menuRole, children: items)
            ])
        })
    }

    @Test func pasteIsFoundByCommandVNotByItsTitle() {
        // Bit 3 set = no Command; 1 = Shift, 2 = Option. ⌥⇧⌘V is Paste and Match Style.
        let english = bar([("File", [item("Print…", "P")]),
                           ("Edit", [item("Copy", "C"), item("Paste", "V"), item("Paste and Match Style", "V", 3),
                                     item("Paste Without Cmd", "V", 8)])])
        guard case .success(let found) = HarnessPaste.pasteMenuItem(in: english, children: \.children) else {
            Issue.record("Paste not found"); return
        }
        #expect(found.label == "Paste")
        let german = bar([("Bearbeiten", [item("Kopieren", "C"), item("Einsetzen", "v")])])
        guard case .success(let einsetzen) = HarnessPaste.pasteMenuItem(in: german, children: \.children) else {
            Issue.record("Einsetzen not found"); return
        }
        #expect(einsetzen.label == "Einsetzen")
    }

    @Test func aMissingDisabledOrDoubledPasteIsUnavailable() {
        let cases = [
            bar([("Edit", [item("Copy", "C")])]),
            bar([("Edit", [item("Paste", "V", enabled: false)])]),
            bar([("Edit", [item("Paste", "V")]), ("Format", [item("Paste Style", "V")])]),
        ]
        for menuBar in cases {
            guard case .failure(let refusal) = HarnessPaste.pasteMenuItem(in: menuBar, children: \.children) else {
                Issue.record("a Paste was chosen"); continue
            }
            #expect(refusal.code == "pasteUnavailable")
        }
    }

    // MARK: verification and restore

    @Test func thePasteIsSeenByItsNonWhitespaceCharacters() {
        let pasted = "Groceries\n- eggs\n- milk"
        #expect(HarnessPaste.pasteLanded(valueBefore: "", valueAfter: "Groceries\n- eggs\n- milk", pasted: pasted))
        #expect(HarnessPaste.pasteLanded(valueBefore: "Title\n", valueAfter: "Title\nGroceries\u{2028}- eggs - milk", pasted: pasted))
        #expect(!HarnessPaste.pasteLanded(valueBefore: "", valueAfter: nil, pasted: pasted))
        #expect(!HarnessPaste.pasteLanded(valueBefore: "", valueAfter: "", pasted: pasted))
        #expect(!HarnessPaste.pasteLanded(valueBefore: "", valueAfter: "Groceries\n- eggs", pasted: pasted))
        // Already there before: unchanged is not a paste.
        #expect(!HarnessPaste.pasteLanded(valueBefore: pasted, valueAfter: pasted, pasted: pasted))
    }

    @Test func theClipboardIsRestoredOnlyWhileItIsStillOurs() {
        #expect(HarnessPaste.restoreDecision(ourChangeCount: 41, currentChangeCount: 41) == .restore)
        #expect(HarnessPaste.restoreDecision(ourChangeCount: 41, currentChangeCount: 42) == .keepNewer)
        #expect(HarnessPaste.RestoreDecision.keepNewer.rawValue == "clipboardKeptNewerContents")
    }

    /// `.default` is what an app that never raised an alert reads (SDK header),
    /// so it passes only while the privacy preview is off.
    @Test func theClipboardIsReadOnlyWhereTheSystemAllowsIt() {
        #expect(HarnessPaste.pasteboardReadAllowed(behaviorRawValue: nil, privacyPreviewOn: false))
        #expect(HarnessPaste.pasteboardReadAllowed(behaviorRawValue: 2, privacyPreviewOn: true))
        #expect(HarnessPaste.pasteboardReadAllowed(behaviorRawValue: 0, privacyPreviewOn: false))
        #expect(!HarnessPaste.pasteboardReadAllowed(behaviorRawValue: 0, privacyPreviewOn: true))
        #expect(!HarnessPaste.pasteboardReadAllowed(behaviorRawValue: 1, privacyPreviewOn: false))
        #expect(!HarnessPaste.pasteboardReadAllowed(behaviorRawValue: 3, privacyPreviewOn: false))
    }

    // MARK: the voice tool lets a line break through to the gate

    @Test func theVoiceToolPassesALineBreakAndStillRefusesATab() {
        guard case .success(let line) = RealtimeOpenAppTool.harnessRequestLine(
            for: RealtimeToolCall(callID: "t", name: "type_text", appName: "com.apple.Notes", text: "one\r\ntwo"), expectApp: "com.apple.Notes"),
              case .success(let request) = HarnessPolicy.decode(line: line) else { Issue.record("a line break was refused"); return }
        #expect(request.text == "one\ntwo")
        guard case .failure(let refusal) = RealtimeOpenAppTool.harnessRequestLine(
            for: RealtimeToolCall(callID: "t", name: "type_text", appName: "com.apple.Notes", text: "tab\there"), expectApp: "com.apple.Notes")
        else { Issue.record("a tab was typed"); return }
        #expect(refusal.error == "controlCharacterInText")
    }
}
