import Foundation
import Testing

struct TimingsTests {
	@Test func processorTimeCountsWorkAndLeavesOutWaiting() {
		var working = Timings()
		var waiting = Timings()

		working.measureProcessorTime { _ = RealisticCorpus.bodies(count: 100).sorted() }
		waiting.measureProcessorTime { Thread.sleep(forTimeInterval: 0.05) }

		#expect(working.percentile(0.5) > waiting.percentile(0.5))
		#expect(waiting.percentile(0.5) < 25)
	}
}
