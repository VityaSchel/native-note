import CryptoKit
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

	static func hash(password: String, salt: Data, parameters: Parameters, length: Int = 32) throws -> SymmetricKey {
		#if DEBUG
			dispatchPrecondition(condition: .notOnQueue(.main))
		#endif
		return try SecretBytes.withUTF8(of: password) { password in
			try SecretBytes.withScratch(byteCount: length) { out in
				let code = salt.withUnsafeBytes { salt in
					argon2id_hash_raw(
						parameters.t, parameters.m, parameters.p,
						password.baseAddress, password.count,
						salt.baseAddress, salt.count,
						out.baseAddress, length
					)
				}
				guard code == ARGON2_OK.rawValue else {
					throw Failure.rejected(code: code, message: String(cString: argon2_error_message(code)))
				}
				return SymmetricKey(data: UnsafeRawBufferPointer(out))
			}
		}
	}

	static func calibrateMemory(
		target: TimeInterval = 0.4,
		limit: UInt32 = 2 * 1024 * 1024,
		refinements: Int = 4,
		measure: (Parameters) throws -> TimeInterval = timedHash
	) throws -> Parameters {
		let atFloor = try measure(floor)
		guard atFloor > 0, atFloor < target else { return floor }

		var fits = (m: floor.m, time: atFloor)
		var tooSlow: UInt32?
		for _ in 0 ..< refinements {
			let estimate = tooSlow.map { Double(fits.m) / 2 + Double($0) / 2 } ?? Double(fits.m) * target / fits.time
			let candidate = aligned(min(Double(limit), estimate))
			guard candidate > fits.m, candidate != tooSlow else { break }
			let time = try measure(Parameters(m: candidate, t: floor.t, p: floor.p))
			if time > 0, time <= target {
				fits = (candidate, time)
			} else {
				tooSlow = candidate
			}
		}
		return Parameters(m: fits.m, t: floor.t, p: floor.p)
	}

	private static func aligned(_ memory: Double) -> UInt32 {
		let whole = UInt32(memory.rounded(.down))
		return whole - whole % (8 * floor.p)
	}

	private static func timedHash(_ parameters: Parameters) throws -> TimeInterval {
		let started = DispatchTime.now().uptimeNanoseconds
		_ = try hash(password: "native-note calibration", salt: Data(repeating: 0, count: 16), parameters: parameters)
		return Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9
	}
}
