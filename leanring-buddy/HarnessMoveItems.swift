//
//  HarnessMoveItems.swift
//  leanring-buddy
//
//  `moveItems`: move files or folders listed in the front Finder window (list
//  view) into another folder. Finder has no Cut for files, and its Copy item is
//  titled with the selection (`Copy “invoice-a.pdf”`), so both items are found
//  by SHORTCUT, never title. Measured by the coordinator 2026-10-13 08:25,
//  Finder list view, one file selected: Edit lists `Copy “move-me.txt”` (⌘C,
//  enabled), `Paste` (⌘V) and its Option alternate `Move Item Here` (⌥⌘V) as a
//  real AX menu item, disabled until something is copied. So:
//    1. AXSelectedRows on the list's AXOutline = every item's AXRow;
//    2. press the ⌘C item (the owner's clipboard is saved first);
//    3. Go > Go to Folder… the destination (`HarnessGoToFolder.go`);
//    4. the destination list must not already hold any of the names;
//    5. press the ⌥⌘V item (must be enabled), then re-read the list until every
//       name shows (2 s), and put the owner's clipboard back.
//  The pure half (names, the destination path, the shortcuts) is unit-tested;
//  the live half is proven by running it.
//

import AppKit
import ApplicationServices
import Foundation

nonisolated enum HarnessMoveItems {
    typealias Failure = HarnessRenameItem.Failure

    static let maximumItems = 20
    /// ⌘C: Copy, whatever its title says about the selection.
    static let copyShortcut = AccessibilityMenu.describeShortcut(character: "C", modifiers: 0)
    /// ⌥⌘V: Move Item Here (Option is mask bit 1, value 2).
    static let moveHereShortcut = AccessibilityMenu.describeShortcut(character: "V", modifiers: 2)
    static let enabledDeadlineSeconds = 2.0
    static let copyDeadlineSeconds = 1.0
    static let verifyDeadlineSeconds = 2.0
    static let writeTimeoutSeconds: Float = 1.0

    // MARK: Pure

    /// The one item carrying `shortcut`, nil for none or several.
    static func menuItem(withShortcut shortcut: String?, in bar: AccessibilityMenu.Node,
                         children: (AccessibilityMenu.Node) -> [AccessibilityMenu.Node]) -> AccessibilityMenu.Node? {
        let matches = HarnessPaste.menuItems(withShortcut: shortcut, in: bar, children: children)
        return matches.count == 1 ? matches[0] : nil
    }

    /// Each name's one row, in the order asked.
    static func resolveItems(_ names: [String], among listed: [String?]) -> Result<[Int], Failure> {
        var indices: [Int] = []
        for name in names {
            switch HarnessRenameItem.resolveItem(named: name, among: listed) {
            case .found(let index): indices.append(index)
            case .notFound:
                return .failure(Failure(code: "moveItemNotFound", message: "no item listed exactly as \(UntrustedText(name).forDisplay) in the Finder "
                                        + "window in front (name as listed, with its extension); nothing was moved"))
            case .ambiguous(let count):
                return .failure(Failure(code: "ambiguous", message: "\(count) items are listed as \(UntrustedText(name).forDisplay); nothing was moved"))
            }
        }
        return .success(indices)
    }

    /// The destination as a path: one starting with / or ~ as given, or a
    /// folder name joined to the folder the window shows. Never the folder the
    /// items are already in, nor one of the items themselves.
    static func destinationPath(_ destination: String, sourceFolder: String?, names: [String], home: String) -> Result<String, Failure> {
        let path: String
        if destination.hasPrefix("/") || destination.hasPrefix("~") {
            if let problem = HarnessGoToFolder.pathProblem(destination) {
                return .failure(Failure(code: "moveDestinationUnknown", message: "the destination is \(problem); nothing was moved"))
            }
            path = HarnessGoToFolder.standardized(destination, home: home)
        } else {
            guard HarnessRenameItem.nameProblem(destination) == nil, let sourceFolder else {
                return .failure(Failure(code: "moveDestinationUnknown", message: "the destination must be a folder's path (starting with / or ~)"
                                        + (sourceFolder == nil ? " — the window in front does not say which folder it shows" : "") + "; nothing was moved"))
            }
            path = HarnessGoToFolder.standardized(sourceFolder + "/" + destination, home: home)
        }
        if let sourceFolder {
            let source = HarnessGoToFolder.standardized(sourceFolder, home: home)
            if path == source {
                return .failure(Failure(code: "moveDestinationUnknown", message: "the items are already in that folder; nothing was moved"))
            }
            if names.contains(where: { path == HarnessGoToFolder.standardized(source + "/" + $0, home: home) || path.hasPrefix(source + "/" + $0 + "/") }) {
                return .failure(Failure(code: "moveDestinationUnknown", message: "a folder cannot be moved into itself; nothing was moved"))
            }
        }
        return .success(path)
    }

    /// The folder a Finder window shows, from its AXDocument (a file URL string).
    static func folderPath(document: String?) -> String? {
        guard let document, let url = URL(string: document), url.isFileURL else { return nil }
        return url.path
    }

    /// The folder from Finder's path bar (View > Show Path Bar), volume first. Finder's
    /// windows answer AXDocument -25212 and their rows carry no AXURL (live, 2026-10-13),
    /// so the path bar is the only place a window says where it is. A shown "/" is a ":"
    /// on disk, so such a name is refused rather than guessed.
    /// ponytail: "Recents"/"iCloud Drive" chains give a wrong path; go_to_folder then fails, nothing moves.
    static func folderPath(pathBar: [String], rootVolumeName: String?) -> String? {
        guard let volume = pathBar.first, !pathBar.contains(where: { $0.isEmpty || $0.contains("/") }) else { return nil }
        let base = volume == rootVolumeName ? "" : "/Volumes/" + volume
        let rest = pathBar.dropFirst().joined(separator: "/")
        return rest.isEmpty ? (base.isEmpty ? "/" : base) : base + "/" + rest
    }

    /// The window's folder chain from its path bar. With exactly one item selected the bar
    /// ends in THAT item (… > JARVIS-sandbox > Receipts in a window titled "JARVIS-sandbox",
    /// launch E08 2026-10-13), so it is dropped; otherwise the bar must end in the title.
    static func folderChain(pathBar names: [String], title: String?, selected: [String?]) -> [String]? {
        guard let title, let last = names.last else { return nil }
        // A row whose rename field is open reads its name EMPTY (launch E08 2026-10-14, diagnostic: "path bar: 5
        // names ending "untitled folder"; window "JARVIS-sandbox"; 1 selected") — still the one selected item.
        // And Finder does not refresh the bar after a rename: launch E08 2026-10-14 20:33 read "5 names ending
        // "untitled folder"" with the row already "Receipts". With one row selected, the one name past the
        // title is the selection's, whatever it reads.
        if selected.count == 1, names.dropLast().last == title {
            return Array(names.dropLast())
        }
        return last == title ? names : nil
    }

    /// The path bar's names: a list of only static texts that includes the window's title.
    static func pathBarNames(in window: AXUIElement) -> [String]? {
        let title = HarnessRenameItem.string(window, kAXTitleAttribute)
        var queue = [(window, 0)]
        while !queue.isEmpty {
            let (node, depth) = queue.removeFirst()
            for child in HarnessRenameItem.elements(node, kAXChildrenAttribute) {
                guard HarnessRenameItem.string(child, kAXRoleAttribute) == kAXListRole as String else {
                    if depth < HarnessRenameItem.listSearchDepth { queue.append((child, depth + 1)) }
                    continue
                }
                let items = HarnessRenameItem.elements(child, kAXChildrenAttribute)
                let names = items.compactMap { item in
                    HarnessRenameItem.string(item, kAXRoleAttribute) == kAXStaticTextRole as String
                        ? HarnessRenameItem.string(item, kAXValueAttribute) ?? HarnessRenameItem.string(item, kAXTitleAttribute)
                            ?? HarnessRenameItem.string(item, kAXDescriptionAttribute) : nil
                }
                if !names.isEmpty, names.count == items.count, let title, names.contains(title) { return names }
            }
        }
        return nil
    }

    /// The first name the destination already lists — case-insensitive, like APFS.
    static func takenName(_ names: [String], destinationListed: [String?]) -> String? {
        names.first { name in destinationListed.contains { $0.map { $0.compare(name, options: .caseInsensitive) == .orderedSame } == true } }
    }

    // MARK: Live

    struct Plan {
        let processIdentifier: pid_t
        let outline: AXUIElement
        let rows: [AXUIElement]
        let names: [String]
        let destination: String
        let listedCount: Int
    }

    /// Reads the list, resolves every name and the destination. Reads only — a dry run stops here.
    static func plan(names: [String], destination: String, processIdentifier: pid_t) -> Result<Plan, Failure> {
        // The Copy overwrites the owner's clipboard; without reading it first it could not be put back.
        var behavior: Int?
        if #available(macOS 15.4, *) { behavior = NSPasteboard.general.accessBehavior.rawValue }
        guard HarnessPaste.pasteboardReadAllowed(behaviorRawValue: behavior,
                                                 privacyPreviewOn: UserDefaults.standard.bool(forKey: HarnessPaste.privacyPreviewDefaultsKey)) else {
            return .failure(Failure(code: "pasteboardAccessNotAllowed",
                                    message: "this Mac asks before an app reads the clipboard, so it could not be saved and put back; nothing was moved"))
        }
        let list: HarnessRenameItem.FileList
        switch HarnessRenameItem.fileList(processIdentifier: processIdentifier) {
        case .noWindow: return .failure(Failure(code: "moveItemNotFound", message: "Finder has no browser window open; nothing was moved"))
        case .noSingleList:
            return .failure(Failure(code: "moveItemNotFound",
                                    message: "the Finder window in front shows no single file list — moving works in list view (View > as List); nothing was moved"))
        case .list(let read): list = read
        }
        let indices: [Int]
        switch resolveItems(names, among: list.names) {
        case .failure(let failure): return .failure(failure)
        case .success(let found): indices = found
        }
        let rootVolume = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeNameKey]).volumeName
        let bar = pathBarNames(in: list.window)
        let title = HarnessRenameItem.string(list.window, kAXTitleAttribute)
        let selected = HarnessRenameItem.elements(list.outline, kAXSelectedRowsAttribute).map(HarnessRenameItem.rowName)
        let source = folderPath(document: HarnessRenameItem.string(list.window, kAXDocumentAttribute))
            ?? bar.flatMap { folderChain(pathBar: $0, title: title, selected: selected) }.flatMap { folderPath(pathBar: $0, rootVolumeName: rootVolume) }
        switch destinationPath(destination, sourceFolder: source, names: names, home: NSHomeDirectory()) {
        case .failure(let failure):
            // Launch E08 read moveDestinationUnknown after New Folder + rename and it never reproduced by hand:
            // say what the window showed, so the next run names the cause. Names are app-written: quoted.
            guard source == nil else { return .failure(failure) }
            let seen = " [path bar: " + (bar.map { "\($0.count) names ending \(UntrustedText($0.last ?? "").forDisplay)" } ?? "none found")
                + "; window \(UntrustedText(title ?? "").forDisplay); \(selected.count) selected]"
            return .failure(Failure(code: failure.code, message: failure.message + seen))
        case .success(let path):
            return .success(Plan(processIdentifier: processIdentifier, outline: list.outline, rows: indices.map { list.rows[$0] },
                                 names: names, destination: path, listedCount: list.names.count))
        }
    }

    struct Run {
        var report: [String: Any] = [:]
        /// nil when the destination lists every moved name.
        var failure: Failure?
    }

    /// Steps 1-5 above. Nothing more is pressed once a step fails; from the Copy
    /// on, every exit puts the owner's clipboard back while it is still ours.
    static func move(_ plan: Plan, bar: AccessibilityMenu.Node, goToFolderItem: AXUIElement) -> Run {
        var run = Run()
        let pasteboard = NSPasteboard.general
        var saved: [[(NSPasteboard.PasteboardType, Data)]]?
        var ours = 0
        func fail(_ code: String, _ message: String) -> Run {
            if let saved { restoreClipboard(saved, ours: ours, pasteboard: pasteboard, into: &run) }
            run.failure = Failure(code: code, message: message)
            return run
        }
        func enabledItem(_ shortcut: String?) -> AXUIElement? {
            var found: AXUIElement?
            HarnessHands.waitUntil(seconds: enabledDeadlineSeconds) {
                let item = menuItem(withShortcut: shortcut, in: bar, children: AccessibilityMenu.liveChildren)
                found = item?.isEnabled == true ? item?.element : nil
                return found != nil
            }
            return found
        }

        // 1. Select every item.
        AXUIElementSetMessagingTimeout(plan.outline, writeTimeoutSeconds)
        let selection = AXUIElementSetAttributeValue(plan.outline, kAXSelectedRowsAttribute as CFString, plan.rows as CFArray)
        run.report["selectAxError"] = selection.rawValue
        let selected = HarnessHands.waitUntil(seconds: enabledDeadlineSeconds) {
            let now = HarnessRenameItem.elements(plan.outline, kAXSelectedRowsAttribute)
            return now.count == plan.rows.count && plan.rows.allSatisfy { row in now.contains { CFEqual($0, row) } }
        }
        guard selected else { return fail("moveFailed", "the items could not all be selected (AXError \(selection.rawValue)); nothing was moved") }

        // 2. Copy, by ⌘C, with the owner's clipboard saved.
        guard let copy = enabledItem(copyShortcut) else {
            return fail("moveFailed", "Finder's menus have no single enabled ⌘C Copy item with the items selected; nothing was moved")
        }
        guard HarnessHands.targetIsFrontmost(plan.processIdentifier) else { return fail("moveFailed", "Finder is no longer in front; nothing was moved") }
        let snapshot = HarnessPaste.snapshot(pasteboard)
        let before = pasteboard.changeCount
        let copied = AccessibilityActionPerformer.perform(kAXPressAction, on: copy, timeoutInSeconds: 1.0)
        run.report["copyAxError"] = copied.error.rawValue
        guard HarnessHands.waitUntil(seconds: copyDeadlineSeconds, { pasteboard.changeCount != before }) else {
            return fail("moveFailed", "Copy did not put the items on the clipboard; nothing was moved and the clipboard is untouched")
        }
        saved = snapshot
        // ponytail: Finder writes once per Copy as measured; a second write would read as the owner's and keep it.
        ours = pasteboard.changeCount

        // 3. Go to the destination.
        let going = HarnessGoToFolder.go(to: plan.destination, menuItem: goToFolderItem, processIdentifier: plan.processIdentifier)
        run.report["goToFolder"] = going.report
        if let failure = going.failure {
            return fail("moveDestinationUnavailable", "the destination could not be shown (\(failure.message)); nothing was moved")
        }

        // 4. Nothing there may share a name.
        guard case .list(let destination) = HarnessRenameItem.fileList(processIdentifier: plan.processIdentifier) else {
            return fail("moveDestinationUnavailable", "the destination folder is not shown as a list (View > as List), so the move could not be "
                        + "checked; nothing was moved — Finder now shows the destination")
        }
        if let taken = takenName(plan.names, destinationListed: destination.names) {
            return fail("moveNameTaken", "the destination already lists \(UntrustedText(taken).forDisplay); nothing was moved — Finder now shows the destination")
        }

        // 5. Move Item Here, by ⌥⌘V, then the list must show every name.
        guard let moveHere = enabledItem(moveHereShortcut) else {
            return fail("moveFailed", "Finder's menus have no single enabled ⌥⌘V Move Item Here item; nothing was moved — Finder now shows the destination")
        }
        guard HarnessHands.targetIsFrontmost(plan.processIdentifier) else { return fail("moveFailed", "Finder is no longer in front; nothing was moved") }
        let moving = Date()
        let pressed = AccessibilityActionPerformer.perform(kAXPressAction, on: moveHere, timeoutInSeconds: 2.0)
        run.report["moveAxError"] = pressed.error.rawValue
        var listed: [String?] = []
        let confirmed = HarnessHands.waitUntil(seconds: verifyDeadlineSeconds) {
            listed = HarnessRenameItem.rows(of: destination.outline).map(HarnessRenameItem.rowName)
            return plan.names.allSatisfy(listed.contains)
        }
        run.report["verifyMs"] = Int(Date().timeIntervalSince(moving) * 1000)
        if let saved { restoreClipboard(saved, ours: ours, pasteboard: pasteboard, into: &run) }
        guard confirmed else {
            run.failure = Failure(code: "notObserved", message: "Move Item Here was pressed and the destination did not list every item within "
                                  + "\(Int(verifyDeadlineSeconds * 1000)) ms; whatever Finder shows now (perhaps an alert) is left for the owner")
            return run
        }
        run.report["evidence"] = "the destination lists all \(plan.names.count) moved item(s)"
        return run
    }

    /// Back as it was, only while the clipboard is still our Copy's. Counts only — never a byte of it.
    private static func restoreClipboard(_ saved: [[(NSPasteboard.PasteboardType, Data)]], ours: Int, pasteboard: NSPasteboard, into run: inout Run) {
        let decision = HarnessPaste.restoreDecision(ourChangeCount: ours, currentChangeCount: pasteboard.changeCount)
        if decision == .restore { HarnessPaste.restore(saved, to: pasteboard) }
        run.report["clipboard"] = ["itemsSaved": saved.count, "typesSaved": saved.reduce(0) { $0 + $1.count }, "outcome": decision.rawValue]
    }
}
