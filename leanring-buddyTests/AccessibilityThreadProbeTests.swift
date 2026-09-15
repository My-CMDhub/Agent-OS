import Testing
import CoreGraphics
@testable import Clicky

struct AccessibilityThreadProbeTests {
    @Test func orderIsABBAWithEqualCounts() {
        let order = AccessibilityThreadProbe.interleavedOrder(walksPerThread: 6)
        #expect(order.map(\.rawValue).prefix(8) == ["main", "background", "background", "main", "main", "background", "background", "main"])
        #expect(order.filter { $0 == .main }.count == 6)
        #expect(order.filter { $0 == .background }.count == 6)
    }

    @Test func fingerprintIgnoresOrderButNotFrames() {
        func node(_ name: String, x: CGFloat) -> AccessibilityElementNode {
            AccessibilityElementNode(role: "AXButton", subrole: nil, title: name, value: nil,
                                     frameInAppKitCoordinates: CGRect(x: x, y: 0, width: 10, height: 10),
                                     depth: 0, children: [])
        }
        let lines = AccessibilityThreadProbe.fingerprintLines(of: [node("A", x: 0), node("B", x: 20)])
        let reversed = AccessibilityThreadProbe.fingerprintLines(of: [node("B", x: 20), node("A", x: 0)])
        let moved = AccessibilityThreadProbe.fingerprintLines(of: [node("A", x: 1), node("B", x: 20)])
        #expect(AccessibilityThreadProbe.fingerprint(ofSortedLines: lines) == AccessibilityThreadProbe.fingerprint(ofSortedLines: reversed))
        #expect(AccessibilityThreadProbe.fingerprint(ofSortedLines: lines) != AccessibilityThreadProbe.fingerprint(ofSortedLines: moved))
        #expect(AccessibilityThreadProbe.median([3, 1, 2, 10]) == 2.5)
    }
}
