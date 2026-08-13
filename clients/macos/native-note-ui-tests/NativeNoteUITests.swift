import XCTest

final class NativeNoteUITests: XCTestCase {
	override func setUpWithError() throws {
		continueAfterFailure = false
	}

	@MainActor
	func testLaunchPerformance() throws {
		measure(metrics: [XCTApplicationLaunchMetric()]) {
			XCUIApplication().launch()
		}
	}
}
