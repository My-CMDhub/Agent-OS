//
//  BackgroundMenuTests.swift
//  leanring-buddyTests
//
//  `menu`/`menus` with `expectApp` read THAT app's menu bar even in the
//  background (live 2026-10-26: an approved Chrome > Quit was refused
//  `frontmostChanged` four times while Wispr Flow or Clicky's card was in front).
//

import AppKit
import Testing
@testable import Clicky

private let chrome = (bundleIdentifier: Optional("com.google.Chrome"), name: Optional("Google Chrome"))
private let cursor = (bundleIdentifier: Optional("com.todesktop.230313mzl4w4u92"), name: Optional("Cursor"))
private let wispr = (bundleIdentifier: Optional("com.electron.wispr-flow"), name: Optional("Wispr Flow"))

@Test func aMenuRequestReadsTheExpectedAppInTheBackgroundOnlyWhenItIsNotInFront() {
    let running = [wispr, chrome, cursor]
    // No expectApp: today's frontmost behaviour, byte for byte.
    #expect(HarnessServer.backgroundMenuApplicationIndex(expectApp: nil, frontmost: wispr, regularApps: running) == nil)
    // Already in front: the frontmost path, unchanged.
    #expect(HarnessServer.backgroundMenuApplicationIndex(expectApp: "com.google.Chrome", frontmost: chrome, regularApps: running) == nil)
    // Someone else in front: the named app's own bar, by bundle id or by name.
    #expect(HarnessServer.backgroundMenuApplicationIndex(expectApp: "com.google.Chrome", frontmost: wispr, regularApps: running) == 1)
    #expect(HarnessServer.backgroundMenuApplicationIndex(expectApp: "cursor", frontmost: chrome, regularApps: running) == 2)
    // Not running, or two candidates: keep the frontmost, so the request is refused as before.
    #expect(HarnessServer.backgroundMenuApplicationIndex(expectApp: "com.apple.mail", frontmost: wispr, regularApps: running) == nil)
    #expect(HarnessServer.backgroundMenuApplicationIndex(expectApp: "Cursor", frontmost: wispr, regularApps: running + [cursor]) == nil)
    // Never a prefix.
    #expect(HarnessServer.backgroundMenuApplicationIndex(expectApp: "Curs", frontmost: wispr, regularApps: running) == nil)
}

@Test func clickyNamedAsTheBackgroundTargetIsStillChosenSoItIsRefusedAsItself() throws {
    let own = try #require(Bundle.main.bundleIdentifier)
    let clicky = (bundleIdentifier: Optional(own), name: Optional("Clicky"))
    let index = HarnessServer.backgroundMenuApplicationIndex(expectApp: own, frontmost: chrome, regularApps: [chrome, clicky])
    #expect(index == 1)
    // The chosen app is what `frontmostChangedRefusal` checks: Clicky refuses `targetIsHarnessItself`.
    #expect(HarnessServer.isHarnessItself(bundleIdentifier: [chrome, clicky][index ?? 0].bundleIdentifier))
}

@Test func aTicketForChromesQuitNeverPressesInAnotherApp() throws {
    guard case .success(let request) = HarnessPolicy.decode(
        line: #"{"verb":"menu","path":["Chrome","Quit Google Chrome"],"expectApp":"com.google.Chrome"}"#) else {
        Issue.record("expected a decoded menu request"); return
    }
    let approved = HarnessServer.confirmationShape(for: request, bundleIdentifier: "com.google.Chrome")
    let elsewhere = HarnessServer.confirmationShape(for: request, bundleIdentifier: cursor.bundleIdentifier)
    #expect(HarnessConfirmations.mismatchedField(approved: approved, elsewhere) == "bundleIdentifier")
    #expect(HarnessConfirmations.mismatchedField(approved: approved, approved) == nil)
}

@Test func aRunningAppHasNotQuit() {
    #expect(HarnessServer.hasQuit(NSRunningApplication.current) == false)
}
