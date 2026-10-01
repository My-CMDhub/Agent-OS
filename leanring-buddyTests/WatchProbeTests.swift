import Testing
@testable import Clicky

@Suite struct WatchProbeTests {
    @Test func percentilesAreNearestRankAndNilWhenEmpty() {
        #expect(WatchProbe.percentile([], 0.5) == nil)
        #expect(WatchProbe.percentile([10, 20, 30, 40], 0.5) == 20)
        #expect(WatchProbe.percentile([10, 20, 30, 40], 0.95) == 40)
    }
}
