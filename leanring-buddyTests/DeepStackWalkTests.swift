//
//  DeepStackWalkTests.swift
//  leanring-buddyTests
//
//  Live 2026-10-30 (macOS 27, Swift 6.4): the tree walk crashed "Thread stack size exceeded" 43 levels down on a
//  Swift async pool thread. The recursion runs on its own big-stack thread now, whoever calls it.
//

import CoreGraphics
import Foundation
import Testing
@testable import Clicky

struct DeepStackWalkTests {
    @Test func theWalkBodyRunsOnItsOwnBigStackThreadAndReturnsItsValue() {
        var ranOn: Thread?
        var stack = 0
        let value = AccessibilityTreeWalker.onDeepStack { () -> Int in
            ranOn = Thread.current
            stack = Thread.current.stackSize
            return 42
        }
        #expect(value == 42)
        #expect(stack >= AccessibilityTreeWalker.walkStackBytes)
        #expect(ranOn != Thread.current)
    }
}

/// macOS 27 (2026-10-31): the Brightness slider publishes no AXValue; its thumb's frame along the track is the level.
struct SliderThumbLevelTests {
    @Test func theMeasuredBrightnessThumbReadsFortyFourPercent() {
        let slider = CGRect(x: 1022, y: 530.5, width: 198, height: 16)
        func level(_ thumb: CGRect, vertical: Bool? = false) -> Int? { AccessibilityElementNode.thumbPercent(slider: slider, thumbs: [thumb], vertical: vertical) }
        #expect(level(CGRect(x: 1100.5, y: 530.5, width: 20, height: 16)) == 44)
        #expect(level(CGRect(x: 1022, y: 530.5, width: 20, height: 16)) == 0)
        #expect(level(CGRect(x: 1200, y: 530.5, width: 20, height: 16)) == 100)
        // Orientation unread: wider than tall is horizontal.
        #expect(level(CGRect(x: 1100.5, y: 530.5, width: 20, height: 16), vertical: nil) == 44)
        // Not a thumb on this track: outside it, or no travel.
        #expect(level(CGRect(x: 758, y: 261, width: 6, height: 268.5)) == nil)
        #expect(level(CGRect(x: 1022, y: 530.5, width: 198, height: 16)) == nil)
        // A fill bar, not a thumb: a third of the track or longer.
        #expect(level(CGRect(x: 1022, y: 530.5, width: 70, height: 16)) == nil)
        // Vertical grows upwards: thumb at the top is 100.
        let column = CGRect(x: 0, y: 0, width: 16, height: 120)
        #expect(AccessibilityElementNode.thumbPercent(slider: column, thumbs: [CGRect(x: 0, y: 0, width: 16, height: 20)], vertical: true) == 100)
        // Orientation unread: taller than wide is vertical (as horizontal, this thumb would be a fill bar).
        #expect(AccessibilityElementNode.thumbPercent(slider: column, thumbs: [CGRect(x: 0, y: 100, width: 16, height: 20)], vertical: nil) == 0)
    }

    @Test func onlyExactlyOneReadableThumbGivesALevel() {
        let slider = CGRect(x: 0, y: 0, width: 200, height: 16)
        let thumb = CGRect(x: 90, y: 0, width: 20, height: 16)
        #expect(AccessibilityElementNode.thumbPercent(slider: slider, thumbs: [thumb], vertical: false) == 50)
        #expect(AccessibilityElementNode.thumbPercent(slider: slider, thumbs: [], vertical: false) == nil)
        #expect(AccessibilityElementNode.thumbPercent(slider: slider, thumbs: [thumb, thumb], vertical: false) == nil)
        #expect(AccessibilityElementNode.thumbPercent(slider: slider, thumbs: [nil], vertical: false) == nil)
        #expect(AccessibilityElementNode.thumbPercent(slider: slider, thumbs: [thumb, nil], vertical: false) == nil)
    }
}

/// The attributes probe's dump never carries typed or document text: only its type and length.
struct AttributesProbeMaskingTests {
    @Test func textAttributesPrintTypeAndLengthOnly() {
        #expect(AccessibilityAttributesProbe.shown(attribute: "AXValue", value: "hunter2 secret" as NSString) == "String <14 chars>")
        #expect(AccessibilityAttributesProbe.shown(attribute: "AXSelectedText", value: "draft" as NSString) == "String <5 chars>")
        let attributed = AccessibilityAttributesProbe.shown(attribute: "AXAttributedValueForRange", value: NSAttributedString(string: "Dear Sam"))
        #expect(attributed == "NSAttributedString <8 chars>")
        #expect(!AccessibilityAttributesProbe.shown(attribute: "AXValue", value: "hunter2" as NSString).contains("hunter2"))
        // A slider's number is the reading the probe exists for.
        #expect(AccessibilityAttributesProbe.shown(attribute: "AXValue", value: NSNumber(value: 0.44)).hasSuffix("0.44"))
        #expect(AccessibilityAttributesProbe.shown(attribute: "AXTitle", value: "Brightness" as NSString).contains("Brightness"))
        #expect(AccessibilityAttributesProbe.masksValue(of: "AXAttributedStringForRange"))
        #expect(!AccessibilityAttributesProbe.masksValue(of: "AXDescription"))
    }
}
