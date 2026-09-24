import Foundation

@testable import NativeNoteKit

extension UnlockParameters {
	static let fast = UnlockParameters(
		localSalt: Data(repeating: 0x80, count: 16),
		argon: Argon2.Parameters(m: 1024, t: 1, p: 1),
		enclaveKey: nil
	)

	static let sample = UnlockParameters(
		localSalt: Data(repeating: 0x80, count: 16),
		argon: Argon2.floor,
		enclaveKey: Data(repeating: 0x11, count: 8)
	)

	static func fastBoundToThisMac() throws -> UnlockParameters {
		var parameters = fast
		parameters.enclaveKey = MachineKey.isAvailable ? try MachineKey().representation : nil
		return parameters
	}
}
