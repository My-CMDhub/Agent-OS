//
//  CredentialGuardTests.swift
//  leanring-buddyTests
//
//  The credential guard's pure half (2026-10-02): what the scanner calls a
//  secret and what it must leave alone, redaction, the recursive scrub every
//  on-disk JSON writer makes, the password-manager list, the secure-input
//  holder read from an `IOConsoleUsers` shape, and the AX -> image-pixel rect
//  mapping the screenshot blackout draws with. Whether a live screen is
//  redacted is `--secret-guard-probe`'s question, never a unit test's.
//
//  Every key below is SYNTHETIC and assembled at runtime, so no source line
//  carries a contiguous token a secret scanner (ours or a host's) would flag.
//

import ApplicationServices
import CoreGraphics
import Foundation
import Testing
@testable import Clicky

struct CredentialGuardTests {

    private func kinds(_ text: String) -> [SecretScanner.Kind] {
        SecretScanner.matches(in: text).map(\.kind)
    }

    @Test func everyKindIsFound() {
        let samples: [(SecretScanner.Kind, String)] = [
            (.anthropicKey, "key " + "sk-ant-" + "api03-AbCdEf0123456789ghIJkl_mnop-QRS"),
            (.openAIKey, "sk-" + "proj-Ab12Cd34Ef56Gh78Ij90KlMnOpQr"),
            (.stripeKey, "sk" + "_live_" + "abcdefghIJKL12345678"),
            (.githubToken, "gh" + "p_" + String(repeating: "aB3", count: 12)),
            (.githubToken, "github" + "_pat_" + "11ABCDEFG0123456789_abcdefghij"),
            (.gitlabToken, "gl" + "pat-" + "abcdefghij1234567890"),
            (.slackToken, "xox" + "b-1234567890-abcdefghij"),
            (.awsAccessKey, "id=" + "AKIA" + "ABCDEFGHIJ234567"),
            (.googleAPIKey, "AIza" + "SyA1234567890abcdefghijklmnopqrstuv"),
            (.npmToken, "npm" + "_" + String(repeating: "x9Y", count: 12)),
            (.privateKey, "-----BEGIN RSA " + "PRIVATE KEY-----\nMIIEow\n-----END RSA PRIVATE KEY-----"),
            (.jwt, "eyJ" + "hbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9P"),
            (.namedSecret, "export API_KEY=hunter22"),
            (.namedSecret, #"{"password": "correct horse"}"#),
            (.namedSecret, "Authorization: Bearer abc123def"),
            (.highEntropy, "Q2x1Y2t5U2VjcmV0R3VhcmQ5Wk0zN2RmNHBxOFhyVnc")
        ]
        for (kind, text) in samples {
            #expect(kinds(text) == [kind], "\(kind.rawValue) in \(text.count)-char sample")
        }
        // Every kind has a sample above.
        #expect(Set(samples.map(\.0)) == Set(SecretScanner.Kind.allCases))
    }

    @Test func ordinaryTextIsLeftAlone() {
        let negatives = [
            "The password is required to continue.",
            "Author: Dhruv Patel",
            "https://example.com/oauth/authorize?next=/home",
            "/Users/mybookpro/Library/Developer/Xcode/DerivedData/leanring-buddy-eljcrompchcbuefnluulcygynvxh/Build",
            "/private/tmp/claude-502/-Applications-Journey-of-pro-Heyclicky/05dc6682-1f18-46d9-940b-a4fd12273dc1/scratchpad",
            "commit 58ff491e2b0c7a9d3f1e6b5a4c3d2e1f0a9b8c7d",
            "id 05DC6682-1F18-46D9-940B-A4FD12273DC1",
            "QmFzZTY0TG9va2luZ1dvcmQ1",               // base64-looking, under 32
            "NSAccessibilityBoundsForRange2Parameterized", // a long identifier, not a key
            "sk-learn-is-a-python-library-for-ml",       // "sk-" with no digit
            "task-abcdefghijklmnopqrstuvwxyz0123"        // "sk-" inside a word
        ]
        for text in negatives {
            #expect(SecretScanner.matches(in: text).isEmpty, "flagged: \(text)")
            #expect(SecretScanner.redact(text) == text)
        }
    }

    @Test func redactionReplacesOnlyTheSecret() {
        let key = "sk-ant-" + "AbCdEf0123456789ghIJkl"
        #expect(SecretScanner.redact("use \(key) now") == "use [REDACTED:anthropicKey] now")
        // A named secret loses its value, not its name; a quoted value goes whole.
        #expect(SecretScanner.redact("export API_KEY=hunter22") == "export API_KEY=[REDACTED:namedSecret]")
        #expect(SecretScanner.redact(#"{"password": "correct horse"}"#) == #"{"password": "[REDACTED:namedSecret]"}"#)
        // A PEM block whose END line is off screen is redacted to the end.
        #expect(SecretScanner.redact("-----BEGIN OPENSSH " + "PRIVATE KEY-----\nb3BlbnNz") == "[REDACTED:privateKey]")
        // Ranges are UTF-16, so text before a secret may be any script.
        let text = "клю́ч 🔑 " + key
        let match = SecretScanner.matches(in: text).first
        #expect(match.map { (text as NSString).substring(with: $0.range) } == key)
    }

    @Test func scrubWalksNestedJSON() {
        let key = "sk-ant-" + "AbCdEf0123456789ghIJkl"
        let aws = "AKIA" + "ABCDEFGHIJ234567"
        let scrubbed = SecretScanner.scrub([
            "said": "the key is \(key)",
            "nested": ["api_key": "abc", "GITHUB_TOKEN": "x", "max_tokens": 5, "author": "Dhruv",
                       "list": [aws, 1, NSNull(), ["deeper": key]]] as [String: Any],
            "count": 3
        ])
        #expect(scrubbed["said"] as? String == "the key is [REDACTED:anthropicKey]")
        #expect(scrubbed["count"] as? Int == 3)
        let nested = scrubbed["nested"] as? [String: Any]
        // Nothing secret-shaped in "abc": the key's name decides.
        #expect(nested?["api_key"] as? String == "[REDACTED:namedSecret]")
        #expect(nested?["GITHUB_TOKEN"] as? String == "[REDACTED:namedSecret]")
        #expect(nested?["max_tokens"] as? Int == 5)
        #expect(nested?["author"] as? String == "Dhruv")
        let list = nested?["list"] as? [Any]
        #expect(list?.first as? String == "[REDACTED:awsAccessKey]")
        #expect(list?[2] is NSNull)
        #expect((list?[3] as? [String: Any])?["deeper"] as? String == "[REDACTED:anthropicKey]")
        #expect(SecretScanner.isSecretName("api key") && SecretScanner.isSecretName("private_key"))
        #expect(!SecretScanner.isSecretName("author") && !SecretScanner.isSecretName("turnId"))
    }

    @Test func passwordManagersAreKnownByBundle() {
        #expect(CredentialGuard.isPasswordManager("com.1password.1password"))
        #expect(CredentialGuard.isPasswordManager("com.apple.Passwords"))
        #expect(CredentialGuard.isPasswordManager("COM.APPLE.KEYCHAINACCESS"))
        #expect(!CredentialGuard.isPasswordManager("com.google.Chrome"))
        #expect(!CredentialGuard.isPasswordManager(nil))
    }

    @Test func secureInputHolderIsReadForThisUserOnly() {
        let users: [[String: Any]] = [
            ["kCGSSessionUserIDKey": NSNumber(value: 502), "kCGSSessionOnConsoleKey": true],
            ["kCGSSessionUserIDKey": NSNumber(value: 501), "kCGSSessionSecureInputPID": NSNumber(value: 4242)]
        ]
        #expect(SecureInputState.holderPID(consoleUsers: users, userID: 501) == 4242)
        // Another session's flag is not this keyboard; at rest the key is absent.
        #expect(SecureInputState.holderPID(consoleUsers: users, userID: 502) == nil)
        #expect(SecureInputState.holderPID(consoleUsers: [], userID: 501) == nil)
        #expect(SecureInputState.off.isOn == false)
    }

    @Test func rectsMapIntoImagePixels() {
        // Retina 1440x900 pt (2880x1800 px) captured at 1920x1200: 4/3 px per point.
        let display = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let image = CGSize(width: 1920, height: 1200)
        // AppKit y=450..540 is 360..450 down from the top.
        #expect(CredentialGuard.imagePixelRect(forAppKitRect: CGRect(x: 144, y: 450, width: 144, height: 90),
                                               displayFrame: display, imageSize: image)
                == CGRect(x: 192, y: 480, width: 192, height: 120))
        // The same rect in AX (top-left) coordinates lands in the same place.
        #expect(CredentialGuard.imagePixelRect(forAXRect: CGRect(x: 144, y: 360, width: 144, height: 90),
                                               primaryDisplayHeight: 900, displayFrame: display, imageSize: image)
                == CGRect(x: 192, y: 480, width: 192, height: 120))
        // A secondary display to the right, 1:1: its own origin, clipped at its edge.
        let secondary = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        #expect(CredentialGuard.imagePixelRect(forAppKitRect: CGRect(x: 3300, y: 1000, width: 100, height: 100),
                                               displayFrame: secondary, imageSize: CGSize(width: 1920, height: 1080))
                == CGRect(x: 1860, y: 0, width: 60, height: 80))
        // Off this display entirely: nothing to draw.
        #expect(CredentialGuard.imagePixelRect(forAppKitRect: CGRect(x: 100, y: 100, width: 10, height: 10),
                                               displayFrame: secondary, imageSize: image) == nil)
    }

    // MARK: On-disk writers

    /// The writer itself scrubs, through a real append into a temp directory:
    /// a key the owner read aloud and a secret-named field never reach the file.
    @Test func aLogLineIsWrittenScrubbed() throws {
        let key = "sk-ant-" + "AbCdEf0123456789ghIJkl"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("credential-guard-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let line = RealtimeTranscriptLog.line(turnID: "T", stack: "geminiLive", date: Date(timeIntervalSince1970: 0),
                                              heard: "my key is \(key)", heardComplete: true, said: "noted", decisions: [])
        RealtimeTranscriptLog.append(line.merging(["api_key": "plain-words"]) { $1 }, in: directory)
        MeasurementLogFile.waitForPendingWrites()
        let written = try String(contentsOf: directory.appendingPathComponent(RealtimeTranscriptLog.fileName), encoding: .utf8)
        #expect(!written.contains(key) && !written.contains("plain-words"))
        #expect(written.contains("my key is [REDACTED:anthropicKey]"))
        #expect(written.contains(#""api_key":"[REDACTED:namedSecret]""#))
    }

    @Test func anAuditLineIsScrubbed() {
        let key = "sk-ant-" + "AbCdEf0123456789ghIJkl"
        let line = HarnessPolicy.auditLine(at: Date(timeIntervalSince1970: 0), id: "a", verb: "type", target: "paste \(key)",
                                           app: nil, session: "s", dryRun: true, confirmed: false, kernel: "allow",
                                           outcome: "ok", milliseconds: 1)
        #expect(!line.contains(key))
        #expect(line.contains("[REDACTED:anthropicKey]"))
    }

    // MARK: Screenshot guard

    /// The fail-closed table: anything short of a finished, whole, located check withholds.
    @Test func anIncompleteCheckWithholdsTheScreenshot() {
        typealias Inspection = ScreenSecretGuard.Inspection
        func with(_ change: (inout Inspection) -> Void) -> Inspection {
            var inspection = Inspection()
            change(&inspection)
            return inspection
        }
        #expect(ScreenSecretGuard.withholdReason(nil) == "walkDeadline")
        #expect(ScreenSecretGuard.withholdReason(Inspection()) == nil)
        #expect(ScreenSecretGuard.withholdReason(with { $0.failure = "noFocusedWindow" }) == "noFocusedWindow")
        #expect(ScreenSecretGuard.withholdReason(with { $0.stopReasons = ["timeLimit"] }) == "timeLimit")
        #expect(ScreenSecretGuard.withholdReason(with { $0.subtreesLostToFailedReads = 1 }) == "subtreesLost")
        #expect(ScreenSecretGuard.withholdReason(with { $0.focusChangedDuringWalk = true }) == "focusChanged")
        #expect(ScreenSecretGuard.withholdReason(with { $0.unlocatedSecrets = 1 }) == "unlocatedSecret")
        // Clicky or a password manager in front: excluded from the capture, nothing to walk.
        #expect(ScreenSecretGuard.withholdReason(with { $0.notWalkedReason = "passwordManager" }) == nil)
        // Redactions found is not a reason: they are drawn.
        #expect(ScreenSecretGuard.withholdReason(with {
            $0.redactions = [.init(kind: "secureField", appKitRect: CGRect(x: 0, y: 0, width: 9, height: 9), source: "frame")]
        }) == nil)
    }

    @Test func passwordBoxesAndSecretsBecomeRedactions() {
        let key = "sk-ant-" + "AbCdEf0123456789ghIJkl"
        let field = CGRect(x: 100, y: 500, width: 200, height: 24)
        let anyElement = AXUIElementCreateSystemWide()
        func node(role: String = "AXStaticText", subrole: String? = nil, title: String? = nil, value: String? = nil,
                  frame: CGRect = field, subroleReadFailed: Bool = false, element: AXUIElement? = nil) -> AccessibilityElementNode {
            AccessibilityElementNode(role: role, subrole: subrole, title: title, value: value, frameInAppKitCoordinates: frame,
                                     depth: 1, children: [], subroleReadFailed: subroleReadFailed, accessibilityElement: element)
        }
        let nodes = [
            node(role: "AXTextField", subrole: "AXSecureTextField", value: "••••"),       // a password box
            node(role: "AXSecureTextField", value: "••••", frame: .zero),                 // scrolled out: nothing to cover
            node(role: "AXTextField", value: "hello", subroleReadFailed: true),          // may be one
            node(value: "key: \(key)", element: anyElement),                              // exact glyph rect
            node(title: "token=\(key)"),                                                  // a title: the frame
            node(value: "plain words"),
            node(value: key, frame: .zero)                                                 // nowhere to draw
        ]
        // AX top-left (110, 376) on a 900-pt primary display is AppKit y = 900 - 376 - 20 = 504.
        let found = ScreenSecretGuard.redactions(in: nodes, primaryDisplayHeight: 900) { _, range in
            #expect(range == NSRange(location: 5, length: (key as NSString).length))
            return CGRect(x: 110, y: 376, width: 150, height: 20)
        }
        // "token=<key>": the key's own kind wins the overlap with the named value.
        #expect(found.redactions.map(\.kind) == ["secureField", "secureField", "anthropicKey", "anthropicKey"])
        #expect(found.redactions[2] == .init(kind: "anthropicKey", appKitRect: CGRect(x: 110, y: 504, width: 150, height: 20), source: "range"))
        #expect(found.redactions[3].appKitRect == field && found.redactions[3].source == "frame")
        #expect(found.unlocated == 1)
        // The app did not answer AXBoundsForRange: the element's frame.
        let fallback = ScreenSecretGuard.redactions(in: [node(value: key, element: anyElement)], primaryDisplayHeight: 900) { _, _ in nil }
        #expect(fallback.redactions == [.init(kind: "anthropicKey", appKitRect: field, source: "frame")])
    }

    /// Drawn on the real pixels: black inside the padded rect, untouched outside.
    @Test func theBlackoutLandsOnThePixels() throws {
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let white = try #require(CGContext(data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                                           bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
        white.setFillColor(CGColor(gray: 1, alpha: 1))
        white.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
        let image = try #require(white.makeImage())
        // A 40x20 pt display captured 1:1; a 10x4 pt secret at AppKit (10, 12) is top-left y 4, padded by 2.
        let drawn = ScreenSecretGuard.drawn([.init(kind: "jwt", appKitRect: CGRect(x: 10, y: 12, width: 10, height: 4), source: "range")],
                                            displayFrame: CGRect(x: 0, y: 0, width: 40, height: 20), imageSize: CGSize(width: 40, height: 20))
        #expect(drawn.map(\.rect) == [CGRect(x: 8, y: 2, width: 14, height: 8)])
        let redacted = try #require(ScreenSecretGuard.blackedOut(image, pixelRects: drawn.map(\.rect)))
        // Read back top-left pixels in a known layout.
        let reader = try #require(CGContext(data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 160, space: colorSpace,
                                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
        reader.draw(redacted, in: CGRect(x: 0, y: 0, width: 40, height: 20))
        let bytes = try #require(reader.data).assumingMemoryBound(to: UInt8.self)
        func isBlack(x: Int, topY: Int) -> Bool { bytes[topY * 160 + x * 4] < 10 }   // blue channel, top row first
        #expect(isBlack(x: 8, topY: 2) && isBlack(x: 21, topY: 9) && isBlack(x: 15, topY: 5))
        #expect(!isBlack(x: 7, topY: 5) && !isBlack(x: 22, topY: 5) && !isBlack(x: 15, topY: 1) && !isBlack(x: 15, topY: 10))
        // Nothing to draw: the same image, not a redraw that could fail.
        #expect(ScreenSecretGuard.blackedOut(image, pixelRects: []) === image)
    }
}
