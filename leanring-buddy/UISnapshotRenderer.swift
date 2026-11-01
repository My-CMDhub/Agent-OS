//
//  UISnapshotRenderer.swift
//  leanring-buddy
//
//  `--render-ui-snapshots`: every main SwiftUI surface — the menu-bar panel in
//  each onboarding and permission state, the approval card, the notch — to PNG
//  in light and dark, from fixture data, then quits. So a designer can see each
//  surface without the owner driving the app into it.
//
//  Fixtures only: tickets are opened on a throwaway HarnessConfirmations whose
//  "Always" rules live under a unique keychain service deleted at the end; the
//  panel's onboarding and permission state is pinned in memory, never written
//  to UserDefaults or TCC. The one real thing read is how many Always rules the
//  production keychain item holds — a count, never a rule.
//
//  Rendered through an offscreen window's NSHostingView and `cacheDisplay`, NOT
//  `ImageRenderer`: measured 2026-11-01, ImageRenderer drew a ScrollView as
//  nothing, an NSViewRepresentable as a yellow "unsupported" placeholder, and
//  dropped a plain Button — the rules list, the card's placement tracker and
//  every answer button. cacheDisplay has one lie of its own: a STROKED
//  continuous-curve Capsule (SwiftUI's default) gets flat bars at both ends.
//  Measured 2026-11-01, the same view through SCScreenshotManager (the window
//  server) drew clean, old `.stroke` in a plain Button included — so live never
//  clipped. Stroked capsules use `style: .circular`, which both draw the same.
//

import AppKit
import SwiftUI

@MainActor
enum UISnapshotRenderer {
    static let directory = URL(fileURLWithPath: "/private/tmp/clicky-ui-snapshots", isDirectory: true)
    /// A 14-inch MacBook Pro's notch on its 1512-pt screen; and a notchless screen like this Mac's.
    static let notched = JarvisNotchGeometry(hasNotch: true, anchor: CGRect(x: 663.5, y: 950, width: 185, height: 32))
    static let notchless = JarvisNotchGeometry.resolve(screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900), safeAreaTop: 0,
                                                       auxiliaryTopLeftWidth: nil, auxiliaryTopRightWidth: nil, menuBarHeight: 30)

    static func run(companionManager: CompanionManager) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var manifest: [String] = []
        let realRules: String
        switch ApprovalRulesKeychainStore().load() {
        case .success(let rules): realRules = "\(rules.count)"
        case .failure(let failure): realRules = "unreadable (\(failure.reason))"
        }
        manifest.append("production keychain Always rules: \(realRules) (count only, none rendered)")

        // The menu-bar panel, one file per state the owner can be in. The notch state
        // and the receipt are pinned on the view, never driven through the live notch.
        let all = Set(PanelPermission.allCases)
        let receipt = JarvisProofReceipt(subject: "Wi\u{2011}Fi off", at: Date().addingTimeInterval(-125))
        let panelStates: [(name: String, missing: Set<PanelPermission>, onboarded: Bool, state: JarvisNotchState, receipt: JarvisProofReceipt?,
                           tickets: [Fixture], rules: Int, page: CompanionPanelView.Page, note: String)] = [
            ("panel-ready", [], true, .idle, nil, [], 0, .standby, "Standby: onboarded, all permissions, nothing pending, nothing proven yet"),
            ("panel-ready-receipt", [], true, .idle, receipt, [], 3, .standby, "Standby after a proof: the session's last-verified receipt, three rules"),
            ("panel-acting", [], true, .intent(title: "Opening Safari\u{2026}"), receipt, [], 3, .standby, "the state line mirrors the notch: acting"),
            ("panel-thinking", [], true, .thinking, nil, [], 0, .standby, "the state line mirrors the notch: thinking (orbit glyph)"),
            ("panel-approval-waiting", [], true, .needsYou, nil, [.send, .typeNote], 3, .standby,
             "two tickets pending, notch says needs you: the state line is the waiting row, no answer controls"),
            ("panel-approval-waiting-notch-moved-on", [], true, .intent(title: "Doing \u{00B7} 3"), nil, [.send], 0, .standby,
             "a ticket still waits while the notch moved on: its own row under the state line"),
            ("panel-rules-page-7", [], true, .idle, nil, [], 7, .rules, "Always allowed page: seven rules grouped by app, scope never cut"),
            ("panel-rules-page-empty", [], true, .idle, nil, [], 0, .rules, "Always allowed page with no rules"),
            ("panel-permissions-revoked", [.accessibility], true, .idle, nil, [], 0, .standby,
             "onboarded, Accessibility revoked: one action at a time"),
            ("panel-screen-content", [.screenContent], true, .idle, nil, [], 0, .standby, "the fourth row, which exists only after Screen Recording"),
            ("panel-first-run", all, false, .idle, nil, [], 0, .standby, "first launch: greeting and the first of three steps"),
            ("panel-begin", [], false, .idle, nil, [], 0, .standby, "permissions granted, not yet onboarded: Begin"),
        ]
        for state in panelStates {
            companionManager.pinPanelStateForSnapshot(missing: state.missing, onboarded: state.onboarded)
            let (confirmations, store) = fixtureConfirmations(tickets: state.tickets, rules: Array(Fixture.rules.prefix(state.rules)))
            let view = CompanionPanelView(companionManager: companionManager, confirmations: confirmations,
                                          pinnedState: state.state, pinnedReceipt: state.receipt, page: state.page)
            manifest += renderBoth(AnyView(view), name: state.name, note: state.note)
            _ = store.deleteItem()
        }
        // An item that is there but cannot be decoded: the panel says what that means, never the raw error.
        companionManager.pinPanelStateForSnapshot(missing: [], onboarded: true)
        let unreadableStore = ApprovalRulesKeychainStore(serviceName: "\(ApprovalRulesKeychainStore.productionServiceName).ui-snapshot-\(UUID().uuidString)")
        _ = unreadableStore.write(Data("not json".utf8))
        let unreadable = HarnessConfirmations(rulesStore: unreadableStore)
        for page in [CompanionPanelView.Page.standby, .rules] {
            manifest += renderBoth(AnyView(CompanionPanelView(companionManager: companionManager, confirmations: unreadable,
                                                              pinnedState: .idle, page: page)),
                                   name: page == .standby ? "panel-rules-unreadable" : "panel-rules-unreadable-page",
                                   note: "Always rules item unreadable: \"Unreadable\", none in effect, Copy details on the page")
        }
        _ = unreadableStore.deleteItem()

        // The menu-bar icon: the open arc, a template image, on a light and a dark bar.
        manifest += renderBoth(AnyView(Image(nsImage: MenuBarPanelManager.makeArcMenuBarIcon()).renderingMode(.template)
                                    .foregroundStyle(.primary).frame(width: 44, height: 24)),
                               name: "menubar-icon", note: "the arc icon at 18 x 18 pt")

        // The approval card, grown, on a notched and a notchless screen.
        let cards: [(name: String, tickets: [Fixture], step: ConfirmationStep?, notch: JarvisNotchGeometry, expanded: Bool, note: String)] = [
            ("card-one", [.send], nil, notched, false, "one ticket, notched screen"),
            ("card-one-notchless", [.send], nil, notchless, false, "one ticket, notchless screen (this Mac)"),
            ("card-two", [.send, .typeNote], nil, notched, false, "two tickets stacked"),
            ("card-destructive", [.moveToBin], nil, notched, false, "destructive: band, inverted fills, Allow once and Deny only"),
            ("card-agent-step", [.send], ConfirmationStep(current: 3, total: 5), notched, false, "asked from step 3 of 5 of a task"),
            ("card-three", [.send, .typeNote, .moveToBin], nil, notched, false, "three tickets, the most that can be pending"),
            ("card-long-text", [.typeLong], nil, notched, false, "typed text over 90 characters: a head and \"+N more\""),
            ("card-long-text-expanded", [.typeLong], nil, notched, true,
             "the same with +N more, Details and a rejection open: all below the buttons, which must not move"),
            ("card-one-expanded", [.send], nil, notched, true, "card-one with Details and a rejection open: Deny/Allow where card-one has them"),
        ]
        for card in cards {
            let (confirmations, store) = fixtureConfirmations(tickets: card.tickets, rules: [])
            let grown = ConfirmationCardWindowManager.grownCardForSnapshot(confirmations: confirmations, notch: card.notch, step: card.step,
                                                                           expanded: card.expanded)
            manifest += renderBoth(grown.view, name: card.name, note: card.note, size: grown.size, backdropStrip: card.notch)
            _ = store.deleteItem()
        }

        // The notch in every state it can show.
        let notchStates: [(name: String, state: JarvisNotchState)] = [
            ("listening", .listening), ("thinking", .thinking), ("intent", .intent(title: "Opening Safari")),
            ("proof", .proof(subject: "Wi\u{2011}Fi off")), ("needs-you", .needsYou),
            ("didnt-take", .didntTake(reason: "the button did not respond")), ("no-reply", .noReply),
        ]
        for (screen, geometry) in [("notch", notched), ("notchless", notchless)] {
            for item in notchStates {
                manifest += renderBoth(JarvisNotch.snapshotView(state: item.state, geometry: geometry),
                                       name: "notch-\(screen)-\(item.name)", note: "notch \(item.name), \(screen) screen",
                                       size: geometry.panelFrame.size, backdropStrip: geometry)
            }
        }

        let manifestURL = directory.appendingPathComponent("manifest.txt")
        try? (manifest.joined(separator: "\n") + "\n").write(to: manifestURL, atomically: true, encoding: .utf8)
        print("🧪 ui snapshots: \(manifest.count - 1) files -> \(directory.path)")
    }

    // MARK: - Fixtures

    enum Fixture {
        case send, typeNote, typeLong, moveToBin

        var shape: HarnessConfirmations.Shape {
            switch self {
            case .send:
                return .init(verb: "press", bundleIdentifier: "com.apple.mail", rawTarget: "Send", withinNamed: "Re: Q3 plan", role: "AXButton")
            case .typeNote:
                return .init(verb: "type", bundleIdentifier: "com.apple.Notes", rawTarget: "Body", text: "Buy oat milk and call the bank",
                             mode: "insert", withinNamed: "Groceries")
            case .typeLong:
                return .init(verb: "type", bundleIdentifier: "com.apple.mail", rawTarget: "Body",
                             text: "Thanks for the notes on the Q3 plan. I've moved the launch to the 14th so design has a full week, "
                                 + "and I'll send the revised budget by Friday once finance signs off.",
                             mode: "insert", withinNamed: "Re: Q3 plan", thenConfirm: false)
            case .moveToBin:
                return .init(verb: "press", bundleIdentifier: "com.apple.finder", rawTarget: "Move to Bin", withinNamed: "Downloads",
                             role: "AXMenuItem")
            }
        }
        var appName: String {
            switch self {
            case .send: "Mail"
            case .typeNote: "Notes"
            case .typeLong: "Mail"
            case .moveToBin: "Finder"
            }
        }
        var destructive: Bool { self == .moveToBin }

        static let rules: [HarnessConfirmations.ApprovalRule] = [
            .init(bundleIdentifier: "com.apple.Terminal", verb: "launch", target: nil),
            .init(bundleIdentifier: "com.apple.mail", verb: "press", target: "Send", withinNamed: "Drafts", role: "AXButton"),
            .init(bundleIdentifier: "com.apple.Notes", verb: "type", target: "Body", text: "Daily standup notes", mode: "insert"),
            .init(bundleIdentifier: "com.apple.Safari", verb: "focus", target: nil),
            .init(bundleIdentifier: "com.apple.finder", verb: "select", target: "Downloads", withinNamed: "Sidebar"),
            .init(bundleIdentifier: "com.google.Chrome", verb: "pointer.click", target: "Sign in", nearPoint: CGPoint(x: 1180, y: 96)),
            .init(bundleIdentifier: "com.apple.systempreferences", verb: "press", target: "Wi\u{2011}Fi", role: "AXCheckBox"),
        ]
    }

    /// A HarnessConfirmations of its own, rules under a unique keychain service the caller deletes.
    private static func fixtureConfirmations(tickets: [Fixture], rules: [HarnessConfirmations.ApprovalRule])
        -> (HarnessConfirmations, ApprovalRulesKeychainStore) {
        let store = ApprovalRulesKeychainStore(serviceName: "\(ApprovalRulesKeychainStore.productionServiceName).ui-snapshot-\(UUID().uuidString)")
        if !rules.isEmpty { _ = store.save(rules) }
        let confirmations = HarnessConfirmations(rulesStore: store)
        for ticket in tickets {
            if case .refused(let code, let message) = confirmations.open(ticket.shape, appName: ticket.appName, reason: "fixture",
                                                                         destructive: ticket.destructive) {
                print("🧪 ui snapshots: fixture ticket refused \(code): \(message)")
            }
        }
        return (confirmations, store)
    }

    // MARK: - Rendering

    private static func renderBoth(_ view: AnyView, name: String, note: String, size: CGSize? = nil,
                                   backdropStrip: JarvisNotchGeometry? = nil) -> [String] {
        [false, true].map { dark in
            let file = "\(name)-\(dark ? "dark" : "light").png"
            let written = render(view, size: size, dark: dark, backdropStrip: backdropStrip, to: directory.appendingPathComponent(file))
            return written.map { "\(file)  \($0)  \(note)" } ?? "\(file)  NOT WRITTEN  \(note)"
        }
    }

    /// Draws `view` on a desktop-like backdrop (with a menu-bar strip when it hangs from the
    /// notch) in an offscreen window, and writes a PNG. Returns "w x h px", or nil.
    private static func render(_ view: AnyView, size: CGSize?, dark: Bool, backdropStrip: JarvisNotchGeometry?, to url: URL) -> String? {
        let desktop = dark ? Color(white: 0.16) : Color(white: 0.86)
        let menuBar = dark ? Color(white: 0.24) : Color(white: 0.96)
        let stripHeight = backdropStrip.map { $0.hasNotch ? $0.anchor.height : 30 } ?? 0
        let content = view
            .frame(width: size?.width, height: size?.height, alignment: .top)
            .padding(backdropStrip == nil ? 24 : 0)
            .background(alignment: .top) {
                VStack(spacing: 0) {
                    menuBar.frame(height: stripHeight)
                    desktop
                }
            }
            .environment(\.colorScheme, dark ? .dark : .light)
        let hostingView = NSHostingView(rootView: content)
        let fitting = hostingView.fittingSize
        guard fitting.width > 0, fitting.height > 0 else { return nil }
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: fitting.width, height: fitting.height),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        hostingView.frame = NSRect(origin: .zero, size: fitting)
        hostingView.layoutSubtreeIfNeeded()
        // One run-loop turn so onAppear / GeometryReader updates land before the picture.
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        hostingView.layoutSubtreeIfNeeded()
        guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else { return nil }
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]), (try? png.write(to: url)) != nil else { return nil }
        return "\(bitmap.pixelsWide)x\(bitmap.pixelsHigh) px"
    }
}
