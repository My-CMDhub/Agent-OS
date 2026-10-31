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
        #expect(AccessibilityElementNode.thumbPercent(slider: slider, thumb: CGRect(x: 1100.5, y: 530.5, width: 20, height: 16), vertical: false) == 44)
        #expect(AccessibilityElementNode.thumbPercent(slider: slider, thumb: CGRect(x: 1022, y: 530.5, width: 20, height: 16), vertical: false) == 0)
        #expect(AccessibilityElementNode.thumbPercent(slider: slider, thumb: CGRect(x: 1200, y: 530.5, width: 20, height: 16), vertical: false) == 100)
        // Not a thumb on this track: outside it, or no travel.
        #expect(AccessibilityElementNode.thumbPercent(slider: slider, thumb: CGRect(x: 758, y: 261, width: 6, height: 268.5), vertical: false) == nil)
        #expect(AccessibilityElementNode.thumbPercent(slider: slider, thumb: CGRect(x: 1022, y: 530.5, width: 198, height: 16), vertical: false) == nil)
        // Vertical grows upwards: thumb at the top is 100.
        let column = CGRect(x: 0, y: 0, width: 16, height: 120)
        #expect(AccessibilityElementNode.thumbPercent(slider: column, thumb: CGRect(x: 0, y: 0, width: 16, height: 20), vertical: true) == 100)
    }
}
