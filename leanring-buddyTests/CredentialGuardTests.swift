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
}
