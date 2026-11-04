//
//  JarvisPermissionsTests.swift
//  leanring-buddyTests
//
//  The state table only: status -> row -> action. Pure, so nothing here can raise a system prompt.
//  What macOS does when asked is live evidence and needs the owner's click.
//

import EventKit
import Foundation
import Testing
@testable import Clicky

struct JarvisPermissionsTests {
    private func row(_ permission: JarvisPermission, _ reading: PermissionReading, visited: Bool = false) -> PermissionRowModel {
        PermissionRowModel.make(permission, reading, visitedSettings: visited)
    }

    @Test func aGrantedRowOffersNothing() {
        for permission in JarvisPermission.allCases {
            #expect(row(permission, .granted) == PermissionRowModel(detail: nil, button: nil, secondary: nil))
        }
    }

    @Test func anAnswerableRowAsksAndASpentOneOpensSettings() {
        for permission in [JarvisPermission.microphone, .calendars, .reminders] {
            #expect(row(permission, .neverAsked).button == .ask)
            #expect(row(permission, .off).button == .openSettings)
            #expect(row(permission, .off).detail?.contains("Clicky") == true, "Settings lists the app as Clicky")
        }
    }

    @Test func aProfileBlockOffersNoButtonAnywhere() {
        for permission in JarvisPermission.allCases {
            #expect(row(permission, .blocked).button == nil)
        }
    }

    /// EventKit's status -> reading, including the orphaned-row case that refused the owner.
    @Test func eventKitStatusesMapToTheirReadings() {
        #expect(EventKitAccess.reading(.fullAccess, askedWithNoAnswer: false) == .granted)
        #expect(EventKitAccess.reading(.writeOnly, askedWithNoAnswer: false) == .addOnly)
        #expect(EventKitAccess.reading(.denied, askedWithNoAnswer: false) == .off)
        #expect(EventKitAccess.reading(.restricted, askedWithNoAnswer: false) == .blocked)
        #expect(EventKitAccess.reading(.notDetermined, askedWithNoAnswer: false) == .neverAsked)
        #expect(EventKitAccess.reading(.notDetermined, askedWithNoAnswer: true) == .askedWithNoAnswer)
        #expect(row(.calendars, .askedWithNoAnswer).button == .askAgain)
        #expect(row(.calendars, .addOnly).button == .openSettings)
        #expect(row(.calendars, .addOnly).detail?.contains("Full Access") == true)
    }

    /// Prompts that only point at Settings say so; a Settings trip adds Reopen and names the stale-row trap.
    @Test func accessibilityAndScreenRecordingLeadToTheSwitch() {
        #expect(row(.accessibility, .off).button == .ask)
        #expect(row(.accessibility, .off, visited: true).button == .openSettings)
        #expect(row(.accessibility, .off, visited: true).secondary == .reopen)
        #expect(row(.screenRecording, .off).button == .openSettings)
        #expect(row(.screenRecording, .off).detail?.contains("reopen me") == true, "the restart is said before it is needed")
        #expect(row(.screenRecording, .off, visited: true).secondary == .reopen)
        #expect(row(.screenRecording, .off, visited: true).detail?.contains("older build") == true)
    }

    @Test func filesAndFoldersIsAskedOnlyByAClickAndNotCountedUntilRead() {
        #expect(row(.filesAndFolders, .unknownUntilUsed).button == .ask)
        #expect(row(.filesAndFolders, .off).button == .openSettings)
        var readings = Dictionary(uniqueKeysWithValues: JarvisPermission.allCases.map { ($0, PermissionReading.granted) })
        readings[.filesAndFolders] = .unknownUntilUsed
        #expect(PermissionRowModel.missingCount(readings) == 0)
        #expect(PermissionRowModel.summary(missing: 0) == "All on")
        readings[.filesAndFolders] = .off
        #expect(PermissionRowModel.missingCount(readings) == 1)
    }

    /// Screen Content has no row, and no count, until Screen Recording is on: setup's own rule.
    @Test func screenContentCountsOnlyOnceScreenRecordingIsOn() {
        var readings = Dictionary(uniqueKeysWithValues: JarvisPermission.allCases.map { ($0, PermissionReading.granted) })
        readings[.filesAndFolders] = .unknownUntilUsed
        readings[.screenRecording] = .off
        readings[.screenContent] = .neverAsked
        #expect(PermissionRowModel.missingCount(readings) == 1)
        #expect(!PermissionRowModel.visible(JarvisPermission.essentials, readings: readings).contains(.screenContent))
        readings[.screenRecording] = .granted
        #expect(PermissionRowModel.missingCount(readings) == 1)
        #expect(PermissionRowModel.visible(JarvisPermission.essentials, readings: readings).contains(.screenContent))
        #expect(PermissionRowModel.summary(missing: 2) == "2 missing")
    }

    /// Every row that can open Settings has a pane to open.
    @Test func everyPaneThatARowCanOpenHasALink() {
        for permission in JarvisPermission.allCases where permission != .screenContent {
            #expect(permission.settingsURL?.absoluteString.hasPrefix("x-apple.systempreferences:com.apple.preference.security?Privacy_") == true)
        }
        #expect(JarvisPermission.screenContent.settingsURL == nil)
    }

    /// The guard that keeps an unattended run from raising a prompt nobody will answer.
    @Test func onlyTheOwnersNormalLaunchAsksAtTheMomentOfNeed() {
        let binary = "/x/Clicky"
        #expect(EventKitAccess.isOwnerSession(arguments: [binary], environment: [:]))
        #expect(EventKitAccess.isOwnerSession(arguments: [binary, "-NSDocumentRevisionsDebugMode", "YES"], environment: [:]), "Xcode's Cmd+R")
        #expect(!EventKitAccess.isOwnerSession(arguments: [binary, "--harness"], environment: [:]))
        #expect(!EventKitAccess.isOwnerSession(arguments: [binary, "--launch-suite"], environment: [:]))
        #expect(!EventKitAccess.isOwnerSession(arguments: [binary, "--harness-dry-run"], environment: [:]))
        #expect(!EventKitAccess.isOwnerSession(arguments: [binary], environment: ["XCTestConfigurationFilePath": "/x"]))
        #expect(EventKitAccess.shouldAskAtMomentOfNeed(.notDetermined, ownerSession: true))
        #expect(!EventKitAccess.shouldAskAtMomentOfNeed(.notDetermined, ownerSession: false))
        for spent in [EKAuthorizationStatus.denied, .restricted, .writeOnly, .fullAccess] {
            #expect(!EventKitAccess.shouldAskAtMomentOfNeed(spent, ownerSession: true), "a prompt cannot return")
        }
        #expect(!EventKitAccess.isOwnerSession, "this very test host must never prompt")
    }

    @Test func eachEventKitToolNamesItsEntity() {
        #expect(EventKitAccess.entity(forTool: RealtimeVoiceVerbs.createEventName) == .event)
        #expect(EventKitAccess.entity(forTool: RealtimeVoiceVerbs.readCalendarName) == .event)
        #expect(EventKitAccess.entity(forTool: RealtimeVoiceVerbs.createReminderName) == .reminder)
        #expect(EventKitAccess.entity(forTool: RealtimeVoiceVerbs.typeTextName) == nil)
    }
}
