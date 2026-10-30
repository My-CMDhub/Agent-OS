//
//  DeepStackWalkTests.swift
//  leanring-buddyTests
//
//  Live 2026-10-30 (macOS 27, Swift 6.4): the tree walk crashed "Thread stack size exceeded" 43 levels down on a
//  Swift async pool thread. The recursion runs on its own big-stack thread now, whoever calls it.
//

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
