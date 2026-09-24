import Foundation
import Testing

@testable import NativeNoteKit

struct Argon2Tests {
	@Test func calibrationKeepsTheFloorWhenItAlreadyCostsTheTarget() throws {
		var readings = [0.0, 2.0].makeIterator()

		#expect(try Argon2.calibrateMemory(target: 1.0) { readings.next() ?? 0 } == Argon2.floor)
	}

	@Test func calibrationRaisesMemoryOnlyAndStaysAMultipleOfEightLanes() throws {
		var readings = [0.0, 0.25].makeIterator()

		let parameters = try Argon2.calibrateMemory(target: 1.0) { readings.next() ?? 0 }

		#expect(parameters.m == 4 * Argon2.floor.m)
		#expect(parameters.t == Argon2.floor.t)
		#expect(parameters.p == Argon2.floor.p)
		#expect(parameters.m.isMultiple(of: 8 * parameters.p))
	}

	@Test func calibrationNeverExceedsTheMemoryLimit() throws {
		var readings = [0.0, 0.001].makeIterator()

		let parameters = try Argon2.calibrateMemory(target: 1.0, limit: 512 * 1024) { readings.next() ?? 0 }

		#expect(parameters.m == 512 * 1024)
	}

	@Test func rejectsParametersBelowTheAlgorithmMinimum() {
		#expect(throws: Argon2.Failure.self) {
			try Argon2.hash(
				password: Data("x".utf8),
				salt: Data(repeating: 0, count: 16),
				parameters: Argon2.Parameters(m: 1, t: 0, p: 1)
			)
		}
	}

	@Test func calibrationKeepsTheFloorWhenTheClockDidNotAdvance() throws {
		var readings = [1.0, 1.0].makeIterator()

		#expect(try Argon2.calibrateMemory(target: 1.0) { readings.next() ?? 0 } == Argon2.floor)
	}
}
