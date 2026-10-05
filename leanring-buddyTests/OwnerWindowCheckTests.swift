//
//  OwnerWindowCheckTests.swift
//  leanring-buddyTests
//
//  R3 (2026-10-05 10-41-24Z) aborted on "owner Chrome window gone" while Chrome's
//  own log shows no window closed: a surface that shrank under the 100 pt filter,
//  or a nil second read, reads as "missing". A window is gone only when the window
//  server has no description of its number, and an unread list is unknown.
//

import CoreGraphics
import Foundation
import Testing
@testable import Clicky

@MainActor
struct OwnerWindowCheckTests {

    @Test func anUnreadableAfterListIsUnknownNeverAllGone() {
        #expect(VoiceToolProbe.preexistingWindowsMissing(before: [10, 11], after: nil, stillExists: { _ in false }) == nil)
    }

    @Test func aNumberIsMissingOnlyWhenTheWindowServerHasNoDescriptionOfIt() {
        // Dropped out of the list, still described: shrank under 100 pt, not gone.
        #expect(VoiceToolProbe.preexistingWindowsMissing(before: [10, 11], after: [10], stillExists: { $0 == 11 }) == [])
        #expect(VoiceToolProbe.preexistingWindowsMissing(before: [10, 11], after: [10], stillExists: { _ in false }) == [11])
        // Only the numbers the list lost are asked about.
        var asked: [Int] = []
        _ = VoiceToolProbe.preexistingWindowsMissing(before: [10, 11], after: [10, 11, 99], stillExists: { asked.append($0); return false })
        #expect(asked.isEmpty)
    }

    /// Live, not mocked: the description read answers for a real window and not for a number nobody holds.
    @Test func theDescriptionReadTellsAWindowFromNoWindow() {
        let listed = (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]])?
            .compactMap { $0[kCGWindowNumber as String] as? Int }.first
        if let listed { #expect(VoiceToolProbe.windowExists(listed)) }
        #expect(!VoiceToolProbe.windowExists(Int(Int32.max)))
    }

    @Test func theCheckRecordsNumbersAndBoundsAndOnlyTheShapeOfTitles() throws {
        let owner = WindowServerSurface(number: 1982, bounds: CGRect(x: 0, y: 25, width: 1440, height: 875),
                                        title: "https://www.linkedin.com/feed/?private=1")
        let bubble = WindowServerSurface(number: 2001, bounds: CGRect(x: 900, y: 80, width: 300, height: 120), title: "Quarterly plan draft")
        let check = VoiceToolProbe.ownerWindowCheck(before: [owner, bubble], after: [owner], stillExists: { _ in false })
        #expect(check.missing == [2001])
        #expect(check.record["intact"] as? Bool == false)
        let missing = try #require(check.record["missing"] as? [[String: Any]])
        #expect(missing.map { $0["number"] as? Int } == [2001])
        #expect(missing.first?["bounds"] as? [String: Int] == ["x": 900, "y": 80, "w": 300, "h": 120])
        #expect(missing.first?["titleLength"] as? Int == 20)
        #expect(missing.first?["titleHost"] is NSNull)
        let before = try #require(check.record["before"] as? [[String: Any]])
        #expect(before.first { $0["number"] as? Int == 1982 }?["titleHost"] as? String == "www.linkedin.com")
        #expect((check.record["after"] as? [[String: Any]])?.map { $0["number"] as? Int } == [1982])
        let written = MeasurementLogFile.jsonLine(check.record) ?? ""
        #expect(!written.isEmpty && !written.contains("feed") && !written.contains("Quarterly"))

        // Shrunk, not gone: recorded as unlisted-but-present, and intact.
        let shrunk = VoiceToolProbe.ownerWindowCheck(before: [owner, bubble], after: [owner], stillExists: { _ in true })
        #expect(shrunk.missing == [])
        #expect(shrunk.record["intact"] as? Bool == true)
        #expect(shrunk.record["unlistedButPresent"] as? [Int] == [2001])

        // Unread: unknown, never "all missing".
        let unknown = VoiceToolProbe.ownerWindowCheck(before: [owner], after: nil, stillExists: { _ in false })
        #expect(unknown.missing == nil)
        #expect(unknown.record["intact"] is NSNull)
        #expect(unknown.record["after"] is NSNull)
    }
}
