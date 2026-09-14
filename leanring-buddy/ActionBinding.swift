//
//  ActionBinding.swift
//  leanring-buddy
//
//  A ticket binds the request's WORDS: verb, app, target, qualifiers. That is
//  not the same as binding the THING. Mail's toolbar Delete deletes whatever is
//  selected at the moment it is pressed, so between the owner's Allow and the
//  re-issued request (up to 60 s) a changed selection turns the same approved
//  words into a different deletion — and the card never said what would go.
//
//  So a ticket opened for press / menu / open / type also records:
//    - the resolved element's identity (`AccessibilityElementKey`, CFEqual), and
//    - the selection the action would act on: which container, which items
//      (by identity), and a fingerprint of their texts.
//  At use both are read again. Anything that moved makes the ticket stale.
//
//  Measured 2026-09-14 on this Mac, read-only:
//    - The APPLICATION element's `AXFocusedUIElement` names the selecting
//      container in 0.1 ms (the window's answers -25205).
//    - Finder list view: `AXOutline.AXSelectedRows`; column view: `AXBrowser` >
//      one `AXList` per column, and the real selection is the LAST column with a
//      non-empty `AXSelectedChildren`; icon view: `AXList` (AXCollectionList)
//      `AXSelectedChildren`, named only by `AXGroup > AXImage.AXDescription`.
//    - Mail: `AXTable.AXSelectedRows`. Never scan rows for `AXSelected` — 660 ms
//      over 18,013 rows.
//    - Buttons, menu items and containers keep their identity across re-walks;
//      after a selection change the selected row is a DIFFERENT element.
//

import AppKit
import ApplicationServices
import CryptoKit
import Foundation

struct ActionBinding: Equatable {

    struct PublishedSelection: Equatable {
        let containerKey: AccessibilityElementKey
        /// How to read the container again: `AXSelectedRows`, `AXSelectedChildren`,
        /// or `AXBrowser` for "the last non-empty column".
        let selectionAttribute: String
        let selectedItemKeys: Set<AccessibilityElementKey>
        /// SHA-256 over every selected item's texts, in order. Identity alone is not
        /// enough when an app reuses a row element for different content.
        let namesFingerprint: String
        let count: Int
        /// The first text of each selected item, in order — ONLY for apps in
        /// `appsWhoseItemNamesMayBeShown`. nil for every other app, so a Mail
        /// message preview never reaches a card, a response or an audit line.
        let displayNames: [String]?
    }

    enum Selection: Equatable {
        case published(PublishedSelection)
        /// Our words and a raw AXError — never app-written text.
        case unavailable(reason: String)
    }

    /// nil when the verb acts on no element.
    let targetElementKey: AccessibilityElementKey?
    let selection: Selection
    let readMilliseconds: Int

    /// The element and process a binding is read from.
    struct Subject {
        let targetElement: AXUIElement?
        let processIdentifier: pid_t?
    }

    /// Apps whose selected item names are safe to show on the card and in a
    /// response. Finder's are file names the owner is looking at; Mail's are a
    /// sender, a subject and a 403-character message preview. Opt-in, one app at
    /// a time — every other app shows a count.
    static let appsWhoseItemNamesMayBeShown: Set<String> = ["com.apple.finder"]

    static let messagingTimeoutInSeconds: Float = 0.5
    /// How far up from the focused element a selecting container is looked for.
    /// A Finder outline IS the focused element; six hops reaches the window.
    static let maximumAncestorHops = 6
    /// Texts are looked for this deep inside one item (row > cell > unknown > text).
    static let maximumItemTextDepth = 4
    static let maximumNamesShown = 3

    // MARK: Pure

    static func itemNamesMayBeShown(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return appsWhoseItemNamesMayBeShown.contains(bundleIdentifier.lowercased())
    }

    /// JSON of the nested array, so ["ab"] and ["a","b"] cannot hash alike.
    static func namesFingerprint(itemTexts: [[String]]) -> String {
        let encoded = (try? JSONEncoder().encode(itemTexts)) ?? Data()
        return SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined()
    }

    /// Column view keeps every ancestor column's selection (the folder you came
    /// through), so the item an action affects is in the LAST column that has one.
    static func lastNonEmptyColumnIndex(selectedCountsByColumn: [Int]) -> Int? {
        selectedCountsByColumn.lastIndex { $0 > 0 }
    }

    /// Which part of the approved binding no longer holds, or nil.
    /// `currentSelection` is ignored when the approved selection was unavailable:
    /// only the target could be bound then.
    static func movedPart(approved: ActionBinding, currentTargetKey: AccessibilityElementKey?,
                          currentSelection: Selection) -> String? {
        if approved.targetElementKey != currentTargetKey { return "target" }
        guard case .published(let then) = approved.selection else { return nil }
        guard case .published(let now) = currentSelection,
              now.containerKey == then.containerKey,
              now.selectedItemKeys == then.selectedItemKeys,
              now.namesFingerprint == then.namesFingerprint else { return "selection" }
        return nil
    }

    /// The card's lines for this binding. Names only for an allow-set app,
    /// escaped in full, at most three, and never a line over the card's budget —
    /// names that do not fit are counted instead of cut.
    static func displayLines(for binding: ActionBinding, bundleIdentifier: String?) -> [String] {
        guard case .published(let selection) = binding.selection else {
            return ["can't see what this will affect"]
        }
        var lines = ["affects: \(selection.count) selected item\(selection.count == 1 ? "" : "s")"]
        guard itemNamesMayBeShown(bundleIdentifier: bundleIdentifier),
              let names = selection.displayNames, !names.isEmpty else { return lines }
        let budget = HarnessConfirmations.maximumDisplayLineLength
        for shownCount in stride(from: min(maximumNamesShown, names.count), through: 1, by: -1) {
            let remaining = names.count - shownCount
            let line = "selected: "
                + names.prefix(shownCount).map { UntrustedText($0).forDisplayInFull }.joined(separator: ", ")
                + (remaining > 0 ? " and \(remaining) more" : "")
            if line.unicodeScalars.count <= budget {
                lines.append(line)
                return lines
            }
        }
        lines.append("selected: names too long to show in full")
        return lines
    }

    /// What a socket response carries. Names only for an allow-set app; never the
    /// fingerprint or the keys.
    static func responsePayload(_ binding: ActionBinding, bundleIdentifier: String?, stalePart: String? = nil) -> [String: Any] {
        var payload: [String: Any] = ["readMilliseconds": binding.readMilliseconds]
        switch binding.selection {
        case .published(let selection):
            payload["available"] = true
            payload["count"] = selection.count
            if itemNamesMayBeShown(bundleIdentifier: bundleIdentifier), let names = selection.displayNames {
                payload["names"] = names.map { UntrustedText($0).forDisplay }
            }
        case .unavailable(let reason):
            payload["available"] = false
            payload["reason"] = reason
        }
        if let stalePart { payload["stale"] = stalePart }
        return payload
    }

    // MARK: Live reads

    private struct ReadFailure: Error { let reason: String }

    /// -25205 (attribute unsupported) and -25212 (no value) are "not here", every
    /// other error is "could not tell" — and "could not tell" must never be
    /// returned as "no selection".
    private static func isAbsence(_ error: AXError) -> Bool {
        error == .attributeUnsupported || error == .noValue
    }

    private static func element(_ element: AXUIElement, _ attribute: String) throws -> AXUIElement? {
        var value: AnyObject?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        if isAbsence(error) { return nil }
        guard error == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            throw ReadFailure(reason: "reading \(attribute) failed: AXError \(error.rawValue)")
        }
        return (value as! AXUIElement)
    }

    private static func elements(_ element: AXUIElement, _ attribute: String) throws -> [AXUIElement]? {
        var value: AnyObject?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        if isAbsence(error) { return nil }
        guard error == .success else {
            throw ReadFailure(reason: "reading \(attribute) failed: AXError \(error.rawValue)")
        }
        return (value as? [AXUIElement]) ?? []
    }

    private static func string(_ element: AXUIElement, _ attribute: String) throws -> String? {
        var value: AnyObject?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        if isAbsence(error) { return nil }
        guard error == .success else {
            throw ReadFailure(reason: "reading \(attribute) failed: AXError \(error.rawValue)")
        }
        return value as? String
    }

    /// Text-field and static-text values in document order; image descriptions
    /// only when an item has no text at all (Finder's icon view).
    private static func texts(of item: AXUIElement) throws -> [String] {
        var values: [String] = []
        var images: [AXUIElement] = []
        func visit(_ element: AXUIElement, depth: Int) throws {
            let role = try string(element, kAXRoleAttribute) ?? ""
            if role == kAXTextFieldRole || role == kAXStaticTextRole, let value = try string(element, kAXValueAttribute) {
                values.append(value)
            } else if role == kAXImageRole {
                images.append(element)
            }
            guard depth < maximumItemTextDepth else { return }
            for child in try elements(element, kAXChildrenAttribute) ?? [] { try visit(child, depth: depth + 1) }
        }
        try visit(item, depth: 0)
        guard values.isEmpty else { return values }
        // Measured 2026-09-14: in Finder's LIST view the row's file icon answers
        // AXDescription with -25200, and reading it unconditionally threw the whole
        // binding away — the card said "can't see" and a selection change was not
        // caught. Images are asked only when an item has no text (icon view), and a
        // name that cannot be read is skipped, not fatal: names are the fingerprint
        // and the card line, while the selected items' KEYS are what detect a change.
        return images.compactMap { try? string($0, kAXDescriptionAttribute) ?? nil }
    }

    // ponytail: reads every selected item's texts; a 5,000-file selection is
    // ~50,000 reads on the main thread. Cap the texts (keys still bind) if a
    // real selection that size ever shows up in readMilliseconds.
    private static func publishedSelection(container: AXUIElement, attribute: String, items: [AXUIElement],
                                            bundleIdentifier: String?) throws -> PublishedSelection {
        let itemTexts = try items.map(texts(of:))
        return PublishedSelection(
            containerKey: AccessibilityElementKey(element: container),
            selectionAttribute: attribute,
            selectedItemKeys: Set(items.map(AccessibilityElementKey.init)),
            namesFingerprint: namesFingerprint(itemTexts: itemTexts),
            count: items.count,
            displayNames: itemNamesMayBeShown(bundleIdentifier: bundleIdentifier) ? itemTexts.map { $0.first ?? "" } : nil
        )
    }

    /// The column lists of a browser, in document order.
    private static func columnLists(of browser: AXUIElement) throws -> [AXUIElement] {
        var lists: [AXUIElement] = []
        func visit(_ element: AXUIElement, depth: Int) throws {
            for child in try elements(element, kAXChildrenAttribute) ?? [] {
                if try string(child, kAXRoleAttribute) == kAXListRole {
                    lists.append(child)
                } else if depth < 3 {
                    try visit(child, depth: depth + 1)
                }
            }
        }
        try visit(browser, depth: 0)
        return lists
    }

    private static func readSelection(container: AXUIElement, attribute: String, bundleIdentifier: String?) throws -> PublishedSelection {
        AXUIElementSetMessagingTimeout(container, messagingTimeoutInSeconds)
        if attribute == kAXBrowserRole {
            let columns = try columnLists(of: container)
            let selectedByColumn = try columns.map { try elements($0, kAXSelectedChildrenAttribute) ?? [] }
            let chosen = lastNonEmptyColumnIndex(selectedCountsByColumn: selectedByColumn.map(\.count))
            return try publishedSelection(container: container, attribute: attribute,
                                          items: chosen.map { selectedByColumn[$0] } ?? [], bundleIdentifier: bundleIdentifier)
        }
        guard let items = try elements(container, attribute) else {
            throw ReadFailure(reason: "the container no longer publishes \(attribute)")
        }
        return try publishedSelection(container: container, attribute: attribute, items: items, bundleIdentifier: bundleIdentifier)
    }

    private static func findSelection(processIdentifier: pid_t, bundleIdentifier: String?) throws -> PublishedSelection {
        let application = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(application, messagingTimeoutInSeconds)
        // The application's, not the window's: the window answers -25205.
        guard let focused = try element(application, kAXFocusedUIElementAttribute) else {
            throw ReadFailure(reason: "the application reports no focused element")
        }
        var chain: [AXUIElement] = [focused]
        while chain.count <= maximumAncestorHops, let parent = try element(chain[chain.count - 1], kAXParentAttribute) {
            chain.append(parent)
        }
        // A browser anywhere above wins: its focused column list may not be the
        // column holding the item the action affects.
        for candidate in chain {
            if try string(candidate, kAXRoleAttribute) == kAXBrowserRole {
                return try readSelection(container: candidate, attribute: kAXBrowserRole, bundleIdentifier: bundleIdentifier)
            }
        }
        for candidate in chain {
            for attribute in [kAXSelectedRowsAttribute, kAXSelectedChildrenAttribute] {
                if try elements(candidate, attribute) != nil {
                    return try readSelection(container: candidate, attribute: attribute, bundleIdentifier: bundleIdentifier)
                }
            }
        }
        throw ReadFailure(reason: "neither the focused element nor its \(chain.count - 1) ancestors publish a selection")
    }

    private static func timed(_ read: () -> Selection) -> (Selection, Int) {
        let startedAt = Date()
        let selection = read()
        return (selection, Int(Date().timeIntervalSince(startedAt) * 1000))
    }

    /// Read when a ticket is opened.
    static func capture(_ subject: Subject, bundleIdentifier: String?) -> ActionBinding {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), messagingTimeoutInSeconds)
        let (selection, milliseconds) = timed {
            guard let processIdentifier = subject.processIdentifier else {
                return .unavailable(reason: "no application process to ask")
            }
            do {
                return .published(try findSelection(processIdentifier: processIdentifier, bundleIdentifier: bundleIdentifier))
            } catch let failure as ReadFailure {
                return .unavailable(reason: failure.reason)
            } catch {
                return .unavailable(reason: String(describing: error))
            }
        }
        return ActionBinding(targetElementKey: subject.targetElement.map(AccessibilityElementKey.init),
                             selection: selection, readMilliseconds: milliseconds)
    }

    /// Read when a ticket is used: the SAME container, by the key stored at open —
    /// never a fresh search, which would follow focus to whatever is selected now.
    static func recheck(_ approved: ActionBinding, subject: Subject, bundleIdentifier: String?) -> (current: ActionBinding, movedPart: String?) {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), messagingTimeoutInSeconds)
        let (selection, milliseconds) = timed {
            guard case .published(let then) = approved.selection else { return approved.selection }
            do {
                return .published(try readSelection(container: then.containerKey.element,
                                                     attribute: then.selectionAttribute, bundleIdentifier: bundleIdentifier))
            } catch let failure as ReadFailure {
                return .unavailable(reason: failure.reason)
            } catch {
                return .unavailable(reason: String(describing: error))
            }
        }
        let current = ActionBinding(targetElementKey: subject.targetElement.map(AccessibilityElementKey.init),
                                    selection: selection, readMilliseconds: milliseconds)
        return (current, movedPart(approved: approved, currentTargetKey: current.targetElementKey, currentSelection: selection))
    }
}
