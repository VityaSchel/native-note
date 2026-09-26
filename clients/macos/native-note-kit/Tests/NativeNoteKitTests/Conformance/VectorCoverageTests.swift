import Foundation
import Testing

struct VectorCoverageTests {
	@Test func everyBundledFileIsReplayedOrDeferred() throws {
		let bundled = try FileManager.default.contentsOfDirectory(atPath: Vectors.bundledVectorsDirectory.path)
			.filter { !$0.hasPrefix(".") }
		#expect(Set(bundled) == Set(VectorFile.allCases.map(\.fileName)))
	}

	@Test func aDeferredFileIsNotReplayed() {
		withKnownIssue {
			_ = try Vectors.load(.blinding)
		}
	}
}
