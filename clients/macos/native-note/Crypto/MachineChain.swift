import CryptoKit
import Foundation

nonisolated enum MachineChain {
	private static let secp256r1GroupOrder: [UInt8] = [
		0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x00,
		0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
		0xbc, 0xe6, 0xfa, 0xad, 0xa7, 0x17, 0x9e, 0x84,
		0xf3, 0xb9, 0xca, 0xc2, 0xfc, 0x63, 0x25, 0x51,
	]

	static func isValidScalar(_ candidate: Data) -> Bool {
		guard candidate.count == secp256r1GroupOrder.count, candidate.contains(where: { $0 != 0 }) else {
			return false
		}
		for (byte, bound) in zip(candidate, secp256r1GroupOrder) where byte != bound {
			return byte < bound
		}
		return false
	}

	static func scalar(x: Data, index: UInt32) -> (scalar: Data, attempt: UInt32) {
		var attempt: UInt32 = 0
		while true {
			let redrawn = KeyDerivation.derive(ikm: x, info: KeyDerivation.chainRound(index: index, attempt: attempt))
			if isValidScalar(redrawn) { return (redrawn, attempt) }
			attempt += 1
		}
	}

	static func machineId(argonOut: Data, rounds: UInt32, key: MachineKey) throws -> Data {
		var x = KeyDerivation.derive(ikm: argonOut, info: KeyDerivation.chainSeed)
		for index in 0 ..< rounds {
			x = try key.agree(with: scalar(x: x, index: index).scalar)
		}
		return KeyDerivation.derive(ikm: x, info: KeyDerivation.chainOut)
	}

	static func calibrateRounds(target: TimeInterval = 1.0, probe: UInt32 = 16, key: MachineKey) throws -> UInt32 {
		let sample = Data(repeating: 0, count: 32)
		let started = DispatchTime.now().uptimeNanoseconds
		_ = try machineId(argonOut: sample, rounds: probe, key: key)
		let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9
		guard elapsed > 0 else { return probe }
		let scaled = (Double(probe) * target / elapsed).rounded()
		return UInt32(min(100_000, max(1, scaled)))
	}
}

nonisolated struct MachineKey {
	static var isAvailable: Bool { SecureEnclave.isAvailable }

	private let key: SecureEnclave.P256.KeyAgreement.PrivateKey

	init() throws {
		key = try SecureEnclave.P256.KeyAgreement.PrivateKey()
	}

	init(representation: Data) throws {
		key = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: representation)
	}

	var representation: Data { key.dataRepresentation }

	func agree(with scalar: Data) throws -> Data {
		let peer = try P256.KeyAgreement.PrivateKey(rawRepresentation: scalar).publicKey
		return try key.sharedSecretFromKeyAgreement(with: peer).withUnsafeBytes { Data($0) }
	}
}
