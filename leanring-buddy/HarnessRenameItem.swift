//
//  HarnessRenameItem.swift
//  leanring-buddy
//
//  `renameItem`: rename a file or folder listed in the front Finder window's
//  list view. Owner's ruling 2026-10-11: renaming is not destructive (the words
//  in both names are still judged). Every step is what the coordinator measured
//  2026-10-13 on Finder list view, `probe-file.txt` in ~/JARVIS-probe:
//    1. AXSelectedRows on the list's AXOutline = [the item's AXRow] -> err 0.
//    2. File > Rename (enabled only with a selection) opens a floating editor.
//    3. The app's focused element becomes an AXTextField, AXIdentifier
//       "ShrinkToFit Text Field", AXParent the APPLICATION, value the full name,
//       AXSelectedTextRange the name without its extension. It publishes NO actions.
//    4. Writing its AXValue -> err 0 and NOTHING renames yet. No AXConfirm; focusing
//       the outline -> err 0 and nothing commits; the function row offers only
//       "emoji & symbols".
//    5. ONE posted left click on EMPTY space in the file area (below the last row)
//       committed it: the folder then held `probe-renamed.txt`.
//  Return is never typed. The pure half (name rules, the item, the empty point)
//  is unit-tested; the live half is proven by running it.
//

import AppKit
import ApplicationServices
import Foundation

nonisolated enum HarnessRenameItem {
    static let fileMenuTitle = "File"
    static let editorIdentifier = "ShrinkToFit Text Field"
    /// APFS: a name is at most 255 UTF-8 bytes.
    static let maximumNameBytes = 255
    static let listRoles: Set<String> = ["AXOutline", "AXTable"]
    static let readTimeoutSeconds: Float = 0.5
    static let writeTimeoutSeconds: Float = 1.0
    static let menuEnabledDeadlineSeconds = 2.0   // live 2026-10-13: 0.5 s refused a selection Finder enabled Rename for moments later
    static let editorDeadlineSeconds = 1.5
    static let verifyDeadlineSeconds = 2.0
    static let pollIntervalSeconds = 0.05
    /// Clearance between the committing click and the last row / the area's edge.
    static let emptyMargin: CGFloat = 8
    /// How deep under the window the list is looked for (window > split group > scroll area > outline).
    static let listSearchDepth = 6

    // MARK: Pure

    /// Why `name` may not be a new name, nil when it may.
    static func nameProblem(_ name: String) -> String? {
        if name.allSatisfy(\.isWhitespace) { return "empty" }
        if name.utf8.count > maximumNameBytes { return "longer than \(maximumNameBytes) bytes" }
        if name.contains("/") || name.contains(":") { return "a / or :" }
        if name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) { return "a control character" }
        if name.hasPrefix(".") { return "starting with . (a hidden name)" }
        return nil
    }

    /// ponytail: English titles only, as measured; another language reads as unavailable.
    static func isRenameItem(_ label: String?) -> Bool {
        label == "Rename" || label == "Rename\u{2026}" || label == "Rename..."
    }

    enum ItemResolution: Equatable {
        case found(Int)
        case notFound
        case ambiguous(Int)
    }

    /// The one row listed exactly as `name`.
    static func resolveItem(named name: String, among names: [String?]) -> ItemResolution {
        let matches = names.indices.filter { names[$0] == name }
        switch matches.count {
        case 1: return .found(matches[0])
        case 0: return .notFound
        default: return .ambiguous(matches.count)
        }
    }

    /// Whether ANOTHER listed item already has `newName`. Case-insensitive like
    /// APFS's default, so "a.txt" blocks "A.txt" elsewhere; the item itself is
    /// excluded, so a case-only rename of it passes.
    static func nameTaken(_ newName: String, among names: [String?], except index: Int) -> Bool {
        names.indices.contains { $0 != index && names[$0].map { $0.compare(newName, options: .caseInsensitive) == .orderedSame } == true }
    }

    /// The committing click's point, in top-left screen coordinates (AX's and
    /// CGEvent's): the middle of the empty space below the last row inside
    /// `area`. nil when there is none — the rows reach the bottom, or a row read
    /// a degenerate frame (a scrolled-out row reads (0,0,0,0) or fails).
    static func emptyPoint(area: CGRect, rowFrames: [CGRect]) -> CGPoint? {
        guard area.width > 2 * emptyMargin, area.height > 0, !rowFrames.isEmpty,
              rowFrames.allSatisfy({ $0.width > 0 && $0.height > 0 }),
              let lastRowBottom = rowFrames.map(\.maxY).max() else { return nil }
        let top = max(lastRowBottom, area.minY)
        guard area.maxY - top >= 3 * emptyMargin else { return nil }
        return CGPoint(x: area.midX, y: top + (area.maxY - top) / 2)
    }

    /// The browser window: the app's MAIN window, or with none (or no list in it)
    /// the first standard window holding a list. Never the focused window — after
    /// File > New Folder that is the floating name editor (launch suite E08,
    /// 2026-10-13: "Finder has no window in front" twice). Falls back to `main`
    /// so a window in icon view still gets the "list view" answer.
    static func browserWindow<W>(main: W?, windows: [W], isStandard: (W) -> Bool, hasList: (W) -> Bool) -> W? {
        if let main, hasList(main) { return main }
        return windows.first { isStandard($0) && hasList($0) } ?? main
    }

    enum OpenEditor: Equatable {
        case none
        /// Open on the item: its text (typed text included) or the one selected row's name is the item.
        case onItem
        /// Open on something else, or on a row that cannot be told — touch nothing.
        case onAnother
    }

    static func openEditor(isOpen: Bool, value: String?, selectedNames: [String?], item: String) -> OpenEditor {
        guard isOpen else { return .none }
        return selectedNames.count == 1 && (value == item || selectedNames[0] == item) ? .onItem : .onAnother
    }

    // MARK: Live

    struct Failure: Error {
        let code: String
        let message: String
    }

    /// What a rename acts on, read before anything is pressed.
    struct Plan {
        let processIdentifier: pid_t
        let outline: AXUIElement
        let row: AXUIElement
        let oldName: String
        let point: CGPoint
        let listedCount: Int
        /// Non-nil: Finder's name editor was already open on the item holding
        /// this text (File > New Folder leaves it open), so select and File >
        /// Rename are skipped.
        var editorValue: String? = nil
    }

    /// Reads the front window's list, resolves the item, checks the new name is
    /// free and finds empty space to click. Reads only — a dry run stops here.
    static func plan(item: String, newName: String, processIdentifier: pid_t) -> Result<Plan, Failure> {
        // Bound every read below, not just the first element's (CLAUDE.md: set it system-wide).
        let outline: AXUIElement, listRows: [AXUIElement], names: [String?]
        switch fileList(processIdentifier: processIdentifier) {
        case .noWindow:
            return .failure(Failure(code: "renameItemNotFound", message: "Finder has no browser window open; nothing was renamed"))
        case .noSingleList:
            return .failure(Failure(code: "renameItemNotFound",
                                    message: "the Finder window in front shows no single file list — rename works in list view (View > as List); nothing was renamed"))
        case .list(let list): (outline, listRows, names) = (list.outline, list.rows, list.names)
        }
        // Finder's name editor already open (File > New Folder leaves it open, maybe with typed text in it).
        let focused = HarnessHands.focusedElement(processIdentifier: processIdentifier)
        let editor = focused.flatMap { string($0, kAXIdentifierAttribute) == editorIdentifier ? $0 : nil }
        let editorValue = editor.flatMap { string($0, kAXValueAttribute) }
        let selected = elements(outline, kAXSelectedRowsAttribute)
        let index: Int
        var item = item
        var openValue: String?
        switch openEditor(isOpen: editor != nil, value: editorValue, selectedNames: selected.map(rowName), item: item) {
        case .onAnother:
            return .failure(Failure(code: "renameBusy", message: "Finder's rename field is open on another item; nothing was touched — "
                                    + "finish or close that rename first"))
        case .onItem:
            // While the editor is open on a row, that row's own name field reads empty (live E08
            // 2026-10-13 21-02-32Z, twice): the editor's text — else the requested name — is its name.
            guard let found = listRows.firstIndex(where: { CFEqual($0, selected[0]) }),
                  let listed = names[found] ?? editorValue ?? Optional(item) else {
                return .failure(Failure(code: "renameItemNotFound", message: "the item Finder's rename field is open on is not in the file list; nothing was touched"))
            }
            // The listed name is what the list must stop showing; the editor's text is what it must still hold.
            index = found
            item = listed
            openValue = editorValue ?? listed
        case .none:
            switch resolveItem(named: item, among: names) {
            case .found(let found): index = found
            case .notFound:
                return .failure(Failure(code: "renameItemNotFound",
                                        message: "no item listed exactly as \(UntrustedText(item).forDisplay) in the Finder window in front (name as listed, with its extension); nothing was renamed"))
            case .ambiguous(let count):
                return .failure(Failure(code: "ambiguous", message: "\(count) items are listed as \(UntrustedText(item).forDisplay); nothing was renamed"))
            }
        }
        if newName == item {
            return .failure(Failure(code: "renameNameTaken", message: "the item is already named \(UntrustedText(newName).forDisplay); nothing was renamed"))
        }
        if nameTaken(newName, among: names, except: index) {
            return .failure(Failure(code: "renameNameTaken",
                                    message: "the window already lists \(UntrustedText(newName).forDisplay); nothing was renamed"))
        }
        // The visible part of the list: its frame inside its scroll area's.
        guard var area = AccessibilityTreeWalker.copyFrame(from: outline).frame else {
            return .failure(Failure(code: "renameNotCommitted", message: "the file list's frame could not be read, so there is nowhere known to click; nothing was renamed"))
        }
        if let parent = element(outline, kAXParentAttribute), let parentFrame = AccessibilityTreeWalker.copyFrame(from: parent).frame {
            area = area.intersection(parentFrame)
        }
        // Rows are listed top to bottom, so the last one is where they end.
        let lastFrame = listRows.last.flatMap { AccessibilityTreeWalker.copyFrame(from: $0).frame } ?? .zero
        guard let point = emptyPoint(area: area, rowFrames: [lastFrame]) else {
            return .failure(Failure(code: "renameNotCommitted",
                                    message: "the file list has no empty space below its last row to click, and a rename commits only on such a click; nothing was renamed"))
        }
        return .success(Plan(processIdentifier: processIdentifier, outline: outline, row: listRows[index], oldName: item,
                             point: point, listedCount: names.count, editorValue: openValue))
    }

    struct FileList {
        let window: AXUIElement
        let outline: AXUIElement
        let rows: [AXUIElement]
        let names: [String?]
    }

    enum FileListRead {
        case list(FileList)
        case noWindow
        case noSingleList
    }

    /// The browser window's one file list (list view), its rows and their names. Reads only.
    static func fileList(processIdentifier: pid_t) -> FileListRead {
        // Bound every read below, not just the first element's (CLAUDE.md: set it system-wide).
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), readTimeoutSeconds)
        let application = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(application, readTimeoutSeconds)
        guard let window = browserWindow(main: element(application, kAXMainWindowAttribute), windows: elements(application, kAXWindowsAttribute),
                                         isStandard: { string($0, kAXSubroleAttribute) == kAXStandardWindowSubrole as String },
                                         hasList: { !findLists(under: $0, depth: listSearchDepth).isEmpty }) else { return .noWindow }
        // The file list is the one list whose rows carry names; the sidebar's rows carry none.
        let lists = findLists(under: window, depth: listSearchDepth).compactMap { list -> FileList? in
            let listRows = rows(of: list)
            let names = listRows.map(rowName)
            return names.contains { $0 != nil } ? FileList(window: window, outline: list, rows: listRows, names: names) : nil
        }
        guard lists.count == 1 else { return .noSingleList }
        return .list(lists[0])
    }

    struct Run {
        var report: [String: Any] = [:]
        /// nil when the list now shows the new name and not the old.
        var failure: Failure?
    }

    /// Steps 1-5 above, then reads the list again. Nothing more is pressed once
    /// a step fails; an editor left open is reported, and after a written name
    /// it is put back to the old one first.
    static func rename(_ plan: Plan, to newName: String, fileMenu: AccessibilityMenu.Node) -> Run {
        var run = Run()
        var timings: [String: Int] = [:]
        func milliseconds(since start: Date) -> Int { Int(Date().timeIntervalSince(start) * 1000) }
        func fail(_ code: String, _ message: String) -> Run {
            run.report["timings"] = timings
            run.failure = Failure(code: code, message: message)
            return run
        }
        let started = Date()
        run.report["editorWasOpen"] = plan.editorValue != nil
        if plan.editorValue == nil {
            AXUIElementSetMessagingTimeout(plan.outline, writeTimeoutSeconds)
            let selection = AXUIElementSetAttributeValue(plan.outline, kAXSelectedRowsAttribute as CFString, [plan.row] as CFArray)
            run.report["selectAxError"] = selection.rawValue
            guard selection == .success else {
                return fail("renameFailed", "the item could not be selected (AXError \(selection.rawValue)); nothing was renamed")
            }

            // Enabled only once the selection has landed.
            var menuItem: AccessibilityMenu.Node?
            HarnessHands.waitUntil(seconds: menuEnabledDeadlineSeconds) {
                let items = AccessibilityMenu.entries(of: fileMenu, children: AccessibilityMenu.liveChildren).filter { isRenameItem($0.label) }
                menuItem = items.count == 1 && items[0].isEnabled ? items[0] : nil
                return menuItem != nil
            }
            guard let element = menuItem?.element else {
                return fail("renameFailed", "Finder's File menu has no single enabled Rename item with the item selected; nothing was renamed")
            }
            let press = AccessibilityActionPerformer.perform(kAXPressAction, on: element, timeoutInSeconds: 2.0)
            run.report["menuPressAxError"] = press.error.rawValue
            // -25204: the press may be held while the editor animates in; the editor decides.
            guard press.error == .success || press.error == .cannotComplete else {
                return fail("renameFailed", "File > Rename did not press (AXError \(press.error.rawValue)); nothing was renamed")
            }
        }
        var editor: AXUIElement?
        HarnessHands.waitUntil(seconds: editorDeadlineSeconds) {
            editor = HarnessHands.focusedElement(processIdentifier: plan.processIdentifier)
                .flatMap { string($0, kAXIdentifierAttribute) == editorIdentifier ? $0 : nil }
            return editor != nil
        }
        timings["editorMs"] = milliseconds(since: started)
        guard let editor else {
            return fail("renameEditorMissing", "Finder's rename field did not appear within \(Int(editorDeadlineSeconds * 1000)) ms; nothing more was pressed or typed")
        }
        AXUIElementSetMessagingTimeout(editor, writeTimeoutSeconds)
        let heldValue = plan.editorValue ?? plan.oldName
        guard string(editor, kAXValueAttribute) == heldValue else {
            return fail("renameEditorMissing", "the rename field does not hold \(UntrustedText(heldValue).forDisplay); nothing was typed, "
                + "and the field is left open unchanged — clicking elsewhere closes it")
        }
        let write = AXUIElementSetAttributeValue(editor, kAXValueAttribute as CFString, newName as CFString)
        run.report["writeAxError"] = write.rawValue
        guard write == .success else {
            return fail("renameNotCommitted", "the rename field did not take the name (AXError \(write.rawValue)); it is left open unchanged")
        }

        // The commit: one click, only on the list itself, the owner's hands off and Finder in front.
        func putBack(_ why: String) -> Run {
            let restored = AXUIElementSetAttributeValue(editor, kAXValueAttribute as CFString, heldValue as CFString)
            run.report["restoredOldName"] = restored == .success
            return fail("renameNotCommitted", why + "; nothing was clicked and the rename field "
                + (restored == .success ? "was put back as it was and left open" : "is left open with the new name — the owner may need to close it"))
        }
        guard HarnessHands.waitUntil(seconds: HarnessHands.ownerIdleWaitSeconds, { HarnessHands.ownerIsIdleNow() }) else {
            return putBack("the owner was using the keyboard or mouse")
        }
        guard HarnessHands.targetIsFrontmost(plan.processIdentifier) else { return putBack("Finder is no longer in front") }
        let hit = HarnessHands.hitRelation(atTopLeft: plan.point, target: plan.outline, processIdentifier: plan.processIdentifier)
        run.report["hit"] = "\(hit)"
        guard hit == .target else { return putBack("the empty space below the last row is not the file list itself at the moment of clicking") }
        guard HarnessHands.postClick(atTopLeft: plan.point) else { return putBack("the click event could not be created") }
        run.report["clickedAt"] = [plan.point.x, plan.point.y]

        let committing = Date()
        var names: [String?] = []
        let confirmed = HarnessHands.waitUntil(seconds: verifyDeadlineSeconds) {
            names = rows(of: plan.outline).map(rowName)
            return names.contains(newName) && !names.contains(plan.oldName)
        }
        timings["verifyMs"] = milliseconds(since: committing)
        run.report["timings"] = timings
        guard confirmed else {
            let open = HarnessHands.focusedElement(processIdentifier: plan.processIdentifier).map { string($0, kAXIdentifierAttribute) == editorIdentifier } ?? false
            run.report["editorStillOpen"] = open
            run.failure = Failure(code: "notObserved", message: "the click was posted and the list did not show \(UntrustedText(newName).forDisplay) in place of "
                + "\(UntrustedText(plan.oldName).forDisplay) within \(Int(verifyDeadlineSeconds * 1000)) ms"
                + (open ? "; the rename field is still open" : "; whatever Finder shows now (perhaps an alert) is left for the owner"))
            return run
        }
        run.report["evidence"] = "the list shows \(UntrustedText(newName).forDisplay) and no longer \(UntrustedText(plan.oldName).forDisplay)"
        return run
    }

    // MARK: Reads

    static func findLists(under element: AXUIElement, depth: Int) -> [AXUIElement] {
        guard depth > 0 else { return [] }
        return children(element).flatMap { child -> [AXUIElement] in
            string(child, kAXRoleAttribute).map(listRoles.contains) == true ? [child] : findLists(under: child, depth: depth - 1)
        }
    }

    /// ponytail: every row is read (names AND the name-taken check need them all); a
    /// folder of thousands costs seconds — read `AXVisibleRows` for frames if it bites.
    static func rows(of list: AXUIElement) -> [AXUIElement] {
        var value: AnyObject?
        AXUIElementCopyAttributeValue(list, kAXRowsAttribute as CFString, &value)
        return (value as? [AXUIElement]) ?? []
    }

    /// The row's name field's value: the first AXTextField in its cells (Name is
    /// Finder's first, fixed column). nil when it has none (a sidebar row).
    static func rowName(_ row: AXUIElement) -> String? {
        for cell in children(row) {
            for candidate in [cell] + children(cell) where string(candidate, kAXRoleAttribute) == kAXTextFieldRole as String {
                return string(candidate, kAXValueAttribute)
            }
        }
        return nil
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success ? value as? String : nil
    }

    static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    static func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        var value: AnyObject?
        AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return (value as? [AXUIElement]) ?? []
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        var value: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value)
        return (value as? [AXUIElement]) ?? []
    }
}
