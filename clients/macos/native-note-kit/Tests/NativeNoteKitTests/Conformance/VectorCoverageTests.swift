import Foundation
import Testing

struct VectorCoverageTests {
	@Test func everyBundledFileIsListed() throws {
		let bundled = try FileManager.default.contentsOfDirectory(atPath: Vectors.bundledVectorsDirectory.path)
			.filter { !$0.hasPrefix(".") }
		#expect(Set(bundled) == Set(VectorFile.allCases.map(\.fileName)))
	}
}
