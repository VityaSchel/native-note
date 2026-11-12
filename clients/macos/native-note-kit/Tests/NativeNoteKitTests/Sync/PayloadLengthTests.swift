import Foundation
import Testing

@testable import NativeNoteKit

struct PayloadLengthTests {
	private let cipher = NoteCipher(contentKey: sharedContentKey)
	private let fields = 1 + 1 + 16 + 8 + 8 + 4

	private func length(_ content: Content) throws -> Int {
		try cipher.seal(content, v: 1).payload.count
	}

	private func note(_ body: String) -> Content {
		.note(id: UUID(), createdAt: 1, updatedAt: 2, body: body)
	}

	@Test func aDeletionLooksLikeAShortNote() throws {
		let short = try length(note("1234"))

		#expect(try length(.tombstone(id: UUID(), deletedAt: 3)) == short)
		#expect(try length(note("")) == short)
		#expect(try length(note(String(repeating: "a", count: Content.block - fields))) == short)
	}

	@Test func aLongerNoteGrowsOnlyByWholeBlocks() throws {
		let one = try length(note(String(repeating: "a", count: Content.block - fields)))
		let two = try length(note(String(repeating: "a", count: Content.block - fields + 1)))

		#expect(two - one == Content.block)
		#expect(try length(note(String(repeating: "a", count: 2 * Content.block - fields))) == two)
	}
}
