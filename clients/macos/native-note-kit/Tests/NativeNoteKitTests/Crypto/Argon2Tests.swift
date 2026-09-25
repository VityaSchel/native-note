import Foundation
import Testing

@testable import NativeNoteKit

struct Argon2Tests {
	private struct Curve {
		private(set) var measured: [UInt32] = []
		let seconds: (UInt32) -> TimeInterval

		mutating func measure(_ parameters: Argon2.Parameters) -> TimeInterval {
			measured.append(parameters.m)
			return seconds(parameters.m)
		}
	}

	private static func nonlinear(_ memory: UInt32) -> TimeInterval {
		0.14 * pow(Double(memory) / Double(Argon2.floor.m), 1.35)
	}

	@Test func calibrationKeepsTheFloorWhenItAlreadyCostsTheTarget() throws {
		var curve = Curve { _ in 2.0 }

		#expect(try Argon2.calibrateMemory(target: 1.0) { curve.measure($0) } == Argon2.floor)
		#expect(curve.measured == [Argon2.floor.m])
	}

	@Test func calibrationLandsJustUnderTheTargetOnACurveThatIsNotLinear() throws {
		var curve = Curve(seconds: Self.nonlinear)

		let parameters = try Argon2.calibrateMemory(target: 1.0) { curve.measure($0) }

		#expect(Self.nonlinear(parameters.m) <= 1.0)
		#expect(Self.nonlinear(parameters.m) > 0.9)
		#expect(curve.measured.count <= 5)
		#expect(parameters.t == Argon2.floor.t)
		#expect(parameters.p == Argon2.floor.p)
		#expect(parameters.m.isMultiple(of: 8 * parameters.p))
	}

	@Test func calibrationAimsAnInProcessRunAtFourTenthsOfASecond() throws {
		var curve = Curve(seconds: Self.nonlinear)

		let parameters = try Argon2.calibrateMemory { curve.measure($0) }

		#expect(Self.nonlinear(parameters.m) <= 0.4)
		#expect(Self.nonlinear(parameters.m) > 0.35)
	}

	@Test func calibrationNeverKeepsMemoryThatMeasuredOverTheTarget() throws {
		var curve = Curve { $0 > 700 * 1024 ? 1.4 : 0.2 }

		let parameters = try Argon2.calibrateMemory(target: 1.0) { curve.measure($0) }

		#expect(parameters.m <= 700 * 1024)
		#expect(parameters.m > Argon2.floor.m)
	}

	@Test func calibrationNeverMeasuresPastTheMemoryLimit() throws {
		var curve = Curve { _ in 0.001 }

		let parameters = try Argon2.calibrateMemory(target: 1.0, limit: 512 * 1024) { curve.measure($0) }

		#expect(parameters.m == 512 * 1024)
		#expect(curve.measured.allSatisfy { $0 <= 512 * 1024 })
	}

	@Test func calibrationStopsAtTwoGibibytesByDefault() throws {
		var curve = Curve { _ in 0.001 }

		let parameters = try Argon2.calibrateMemory { curve.measure($0) }

		#expect(parameters.m == 2 * 1024 * 1024)
		#expect(curve.measured.allSatisfy { $0 <= 2 * 1024 * 1024 })
	}

	@Test func calibrationScalesALinearCurveStraightToFourTenthsOfASecond() throws {
		var curve = Curve { 0.2 * Double($0) / Double(Argon2.floor.m) }

		let parameters = try Argon2.calibrateMemory { curve.measure($0) }

		#expect(parameters.m == 2 * Argon2.floor.m)
		#expect(curve.measured == [Argon2.floor.m, 2 * Argon2.floor.m])
	}

	@Test func calibrationDistrustsACandidateThatTookNoTime() throws {
		var curve = Curve { $0 == Argon2.floor.m ? 0.2 : 0 }

		#expect(try Argon2.calibrateMemory { curve.measure($0) } == Argon2.floor)
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

	@Test(arguments: [0.0, -1.0])
	func calibrationKeepsTheFloorWhenTheClockDidNotAdvance(reading: TimeInterval) throws {
		var curve = Curve { _ in reading }

		#expect(try Argon2.calibrateMemory { curve.measure($0) } == Argon2.floor)
		#expect(curve.measured == [Argon2.floor.m])
	}
}
