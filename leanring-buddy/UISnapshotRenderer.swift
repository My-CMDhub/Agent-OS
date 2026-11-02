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
            ("panel-approval-waiting-notch-moved-on", [], true, .intent(title: "Clicking"), nil, [.send], 0, .standby,
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
        let cards: [(name: String, tickets: [Fixture], activity: String?, notch: JarvisNotchGeometry, expanded: Bool, note: String)] = [
            ("card-one", [.send], nil, notched, false, "one ticket, notched screen"),
            ("card-one-notchless", [.send], nil, notchless, false, "one ticket, notchless screen (this Mac)"),
            ("card-two", [.send, .typeNote], nil, notched, false, "two tickets stacked"),
            ("card-destructive", [.moveToBin], nil, notched, false, "destructive: band, inverted fills, Allow once and Deny only"),
            ("card-agent-step", [.send], "Scheduling", notched, false, "asked by a task, with the longest word it can be doing"),
            ("card-three", [.send, .typeNote, .moveToBin], nil, notched, false, "three tickets, the most that can be pending"),
            ("card-long-text", [.typeLong], nil, notched, false, "typed text over 90 characters: a head and \"+N more\""),
            ("card-long-text-expanded", [.typeLong], nil, notched, true,
             "the same with +N more, Details and a rejection open: all below the buttons, which must not move"),
            ("card-one-expanded", [.send], nil, notched, true, "card-one with Details and a rejection open: Deny/Allow where card-one has them"),
        ]
        for card in cards {
            let (confirmations, store) = fixtureConfirmations(tickets: card.tickets, rules: [])
            let grown = ConfirmationCardWindowManager.grownCardForSnapshot(confirmations: confirmations, notch: card.notch, activity: card.activity,
                                                                           expanded: card.expanded)
            manifest += renderBoth(grown.view, name: card.name, note: card.note, size: grown.size, backdropStrip: card.notch)
            _ = store.deleteItem()
        }

        // The notch in every state it can show. Speaking twice: live output bars, and
        // the static fallback drawn until the playback tap's first reading (D7).
        let notchStates: [(name: String, state: JarvisNotchState, outputLevel: CGFloat?)] = [
            ("listening", .listening, nil), ("thinking", .thinking, nil), ("speaking", .speaking, 0.6),
            ("speaking-static", .speaking, nil), ("intent", .intent(title: "Opening Safari\u{2026}"), nil),
            ("task-thinking", .intent(title: AgentActivityWord.thinking), nil), ("task-scheduling", .intent(title: "Scheduling"), nil),
            ("task-typing", .intent(title: "Typing"), nil),
            ("intent-long", .intent(title: "Clicking \u{201C}Show all in Finder and open the enclosing folder\u{201D}\u{2026}"), nil),
            ("proof", .proof(subject: "Wi\u{2011}Fi off"), nil), ("needs-you", .needsYou, nil),
            ("didnt-take", .didntTake(reason: "the button did not respond"), nil), ("no-reply", .noReply, nil),
        ]
        for (screen, geometry) in [("notch", notched), ("notchless", notchless)] {
            for item in notchStates {
                manifest += renderBoth(JarvisNotch.snapshotView(state: item.state, geometry: geometry, outputLevel: item.outputLevel),
                                       name: "notch-\(screen)-\(item.name)", note: "notch \(item.name), \(screen) screen",
                                       size: geometry.panelFrame.size, backdropStrip: geometry)
            }
        }

        // J.A.R.V.I.S.'s marks on other apps (spec §3.6): the ink reticle on a mock
        // window, light and dark, so the keyline is judged on both kinds of content.
        let markScreen = CGRect(x: 0, y: 0, width: 420, height: 170)
        let button = CGRect(x: 160, y: 66, width: 96, height: 28)     // AppKit: y up
        let link = CGRect(x: 40, y: 120, width: 150, height: 18)
        func onMockWindow(_ mark: AnyView) -> AnyView {
            AnyView(ZStack(alignment: .topLeading) {
                MockWindowForMarks(screen: markScreen, button: button, link: link)
                mark
            }.frame(width: markScreen.width, height: markScreen.height))
        }
        func pointer(_ shape: ElementPointerShape, arrived: Bool, at rect: CGRect) -> AnyView {
            let frame = ElementPointer.arrivedFrame(for: rect)
            let side: CGFloat = arrived ? 0 : 24
            let size = arrived ? frame.size : CGSize(width: side, height: side)
            return onMockWindow(AnyView(ElementPointer.snapshotView(shape: shape, arrived: arrived)
                .frame(width: size.width, height: size.height)
                .position(x: arrived ? frame.midX : 330, y: markScreen.height - (arrived ? frame.midY : 40))))
        }
        let marks: [(name: String, view: AnyView, note: String)] = [
            ("overlay-pointer-flight", pointer(.ring, arrived: false, at: button), "point_at in flight: a 1.5 ink ring at 70%"),
            ("overlay-pointer-ring", pointer(.ring, arrived: true, at: button), "point_at landed on a button: its rect framed at radius 6"),
            ("overlay-pointer-underline", pointer(.underline, arrived: true, at: link), "point_at landed on a link: an ink underline"),
            ("overlay-pointer-approximate", pointer(.approximate, arrived: true,
                                                   at: CGRect(x: 300, y: 30, width: ElementPointer.approximateSidePoints, height: ElementPointer.approximateSidePoints)),
             "point_at with nothing nameable at the point: a dashed ring"),
            ("overlay-highlight", onMockWindow(ElementHighlightOverlay.snapshotView(button, label: "Send", screenFrame: markScreen)),
             "the harness's highlight with its label"),
            ("overlay-annotate", onMockWindow(AnnotationOverlay.snapshotView([
                .init(kind: "box", frame: button, label: "Send", described: ""),
                .init(kind: "underline", frame: link, label: nil, described: ""),
                .init(kind: "circle", frame: CGRect(x: 320, y: 110, width: 40, height: 22), label: nil, described: ""),
                .init(kind: "arrow", frame: CGRect(x: 320, y: 30, width: 60, height: 22), label: nil, described: ""),
            ], screenFrame: markScreen)), "annotate: box with caption, underline, circle, arrow"),
        ]
        for mark in marks {
            manifest += renderBoth(mark.view, name: mark.name, note: mark.note, size: markScreen.size)
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

/// Something for the marks to land on: a window with a button, a link and a
/// field, in the appearance being rendered (white page in light, dark in dark).
private struct MockWindowForMarks: View {
    let screen: CGRect
    let button: CGRect
    let link: CGRect

    private func top(_ rect: CGRect) -> CGFloat { screen.height - rect.maxY }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(nsColor: .textBackgroundColor)
            Text("Show all in Finder")
                .font(.system(size: 13)).underline().foregroundStyle(Color(nsColor: .linkColor))
                .frame(width: link.width, height: link.height, alignment: .leading)
                .offset(x: link.minX, y: top(link))
            Text("Send")
                .font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                .frame(width: button.width, height: button.height)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlAccentColor)))
                .offset(x: button.minX, y: top(button))
            Text("Re: Q3 plan \u{2014} the launch moves to the 14th")
                .font(.system(size: 12)).foregroundStyle(Color(nsColor: .secondaryLabelColor))
                .offset(x: 40, y: 18)
        }
        .frame(width: screen.width, height: screen.height)
    }
}
