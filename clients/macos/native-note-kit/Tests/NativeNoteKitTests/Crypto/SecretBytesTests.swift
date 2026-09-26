import Foundation
import Testing

@testable import NativeNoteKit

private struct Planted: Error {}

struct SecretBytesTests {
	private func withSecret<T>(_ body: (UnsafeMutableRawBufferPointer) throws -> T) rethrows -> T {
		let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 64, alignment: 16)
		defer { buffer.deallocate() }
		buffer.initializeMemory(as: UInt8.self, repeating: 0xA5)
		return try body(buffer)
	}

	@Test func wipingZeroesEveryByte() {
		withSecret { buffer in
			SecretBytes.wipe(buffer)

			#expect(buffer.allSatisfy { $0 == 0 })
		}
	}

	@Test func wipingAnEmptyBufferDoesNothing() {
		SecretBytes.wipe(UnsafeMutableRawBufferPointer(start: nil, count: 0))
	}

	@Test func aBufferIsWipedOnceTheWorkUsingItReturns() {
		withSecret { buffer in
			let seen = SecretBytes.wiping(buffer) { $0.first }

			#expect(seen == 0xA5)
			#expect(buffer.allSatisfy { $0 == 0 })
		}
	}

	@Test func aBufferIsWipedWhenTheWorkUsingItThrows() {
		withSecret { buffer in
			#expect(throws: Planted.self) {
				try SecretBytes.wiping(buffer) { _ in throw Planted() }
			}

			#expect(buffer.allSatisfy { $0 == 0 })
		}
	}

	@Test(arguments: ["correct horse", "пароль ✓", ""])
	func thePasswordReachesTheWorkAsItsUTF8Bytes(password: String) {
		#expect(SecretBytes.withUTF8(of: password) { Data($0) } == Data(password.utf8))
	}

	@Test func aScratchBufferHasTheSizeAskedFor() {
		#expect(SecretBytes.withScratch(byteCount: 67) { $0.count } == 67)
	}
}
