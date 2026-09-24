import Foundation
import Testing

@testable import NativeNoteKit

@Suite(.serialized)
struct MachineBindingTests {
	@Test(.enabled(if: MachineKey.isAvailable))
	func isStableForOneDeviceKey() throws {
		let key = try MachineKey()

		#expect(try MachineBinding.machineId(key: key) == MachineBinding.machineId(key: key))
	}

	@Test(.enabled(if: MachineKey.isAvailable))
	func survivesReloadingTheKeyFromItsStoredRepresentation() throws {
		let key = try MachineKey()
		let before = try MachineBinding.machineId(key: key)
		let reloaded = try MachineKey(representation: key.representation)

		#expect(try MachineBinding.machineId(key: reloaded) == before)
	}

	@Test(.enabled(if: MachineKey.isAvailable))
	func differsPerDeviceKey() throws {
		#expect(try MachineBinding.machineId(key: MachineKey()) != MachineBinding.machineId(key: MachineKey()))
	}

	@Test(.enabled(if: MachineKey.isAvailable))
	func doesNotDependOnThePassword() throws {
		let key = try MachineKey()
		let localSalt = Data(repeating: 0x80, count: 16)
		let machineId = try MachineBinding.machineId(key: key)

		let mine = KeyDerivation.localDbKey(argonOut: Data(repeating: 0xa5, count: 32), machineId: machineId, localSalt: localSalt)
		let theirs = KeyDerivation.localDbKey(argonOut: Data(repeating: 0x5a, count: 32), machineId: machineId, localSalt: localSalt)

		#expect(mine != theirs)
	}
}
