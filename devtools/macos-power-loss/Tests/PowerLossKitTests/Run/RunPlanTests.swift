import Testing

@testable import PowerLossKit

struct RunPlanTests {
	@Test func aSeedReplaysTheSamePlan() {
		#expect(RunPlan.make(seed: 42, count: 20) == RunPlan.make(seed: 42, count: 20))
		#expect(RunPlan.make(seed: 42, count: 20) != RunPlan.make(seed: 43, count: 20))
	}

	@Test func aLongerPlanStartsWithTheShorterOne() {
		#expect(Array(RunPlan.make(seed: 7, count: 12).prefix(5)) == RunPlan.make(seed: 7, count: 5))
	}

	@Test func turningTearsOffKeepsTheSameCutMoments() {
		let tearing = RunPlan.make(seed: 9, count: 6)
		let notTearing = RunPlan.make(seed: 9, count: 6, tearing: false)

		#expect(notTearing.map(\.cutAfterMilliseconds) == tearing.map(\.cutAfterMilliseconds))
		#expect(notTearing.allSatisfy { $0.tearSeed == nil })
		#expect(Set(tearing.compactMap(\.tearSeed)).count == 6)
	}

	@Test func everyCutFallsInsideItsWindow() {
		let plan = RunPlan.make(seed: 1, count: 500)

		#expect(plan.allSatisfy { RunPlan.cutWindow(forRun: $0.number).contains($0.cutAfterMilliseconds) })
		#expect(Set(plan.map(\.cutAfterMilliseconds)).count > 400)
	}

	@Test func runsAlternateBetweenEarlyCutsAndCutsLateEnoughToFollowACheckpoint() {
		let plan = RunPlan.make(seed: 1, count: 400)
		let late = plan.filter { $0.number.isMultiple(of: 2) }

		#expect(plan.map(\.number) == Array(1 ... 400))
		#expect(late.allSatisfy { (20_000 ... 60_000).contains($0.cutAfterMilliseconds) })
		#expect(plan.filter { !$0.number.isMultiple(of: 2) }.allSatisfy { (200 ... 6_000).contains($0.cutAfterMilliseconds) })
		#expect(late.contains { $0.cutAfterMilliseconds > 55_000 })
	}
}
