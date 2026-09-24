import Foundation
import argon2

nonisolated enum Argon2 {
	struct Parameters: Equatable, Codable, Sendable {
		var m: UInt32
		var t: UInt32
		var p: UInt32
	}

	enum Failure: Error, Equatable {
		case rejected(code: Int32, message: String)
	}

	static let floor = Parameters(m: 256 * 1024, t: 3, p: 4)

	static func hash(password: Data, salt: Data, parameters: Parameters, length: Int = 32) throws -> Data {
		#if DEBUG
			dispatchPrecondition(condition: .notOnQueue(.main))
		#endif
		var out = [UInt8](repeating: 0, count: length)
		let code = password.withUnsafeBytes { password in
			salt.withUnsafeBytes { salt in
				argon2id_hash_raw(
					parameters.t, parameters.m, parameters.p,
					password.baseAddress, password.count,
					salt.baseAddress, salt.count,
					&out, length
				)
			}
		}
		guard code == ARGON2_OK.rawValue else {
			throw Failure.rejected(code: code, message: String(cString: argon2_error_message(code)))
		}
		return Data(out)
	}

	static func calibrateMemory(
		target: TimeInterval = 1.0,
		limit: UInt32 = 2 * 1024 * 1024,
		clock: () -> TimeInterval = defaultClock
	) throws -> Parameters {
		var calibrated = floor

		let started = clock()
		_ = try hash(password: Data("native-note calibration".utf8), salt: Data(repeating: 0, count: 16), parameters: calibrated)
		let elapsedAtFloor = clock() - started
		guard elapsedAtFloor > 0, elapsedAtFloor < target else { return floor }

		let memoryForTarget = (Double(floor.m) * target / elapsedAtFloor).rounded()
		let withinLimit = UInt32(min(Double(limit), max(Double(floor.m), memoryForTarget)))
		calibrated.m = withinLimit - withinLimit % (8 * floor.p)
		return calibrated
	}

	private static func defaultClock() -> TimeInterval {
		Double(DispatchTime.now().uptimeNanoseconds) / 1e9
	}
}
