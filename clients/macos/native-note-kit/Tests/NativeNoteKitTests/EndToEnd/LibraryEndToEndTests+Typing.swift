import Foundation
import Testing

@testable import NativeNoteKit

@MainActor
private final class Typing {
	let model: AppModel
	let id: UUID
	private var body: String

	init(_ model: AppModel) throws {
		self.model = model
		id = try #require(model.groups.first?.notes.first?.id)
		model.selection = id
		body = try #require(model.selectedNote?.body)
	}

	func keystroke(_ index: Int) {
		body += String(index % 10)
		model.edit(id, body)
		_ = model.groups
	}
}

extension LibraryEndToEndTests {
	private func typing(onLibraryOf count: Int) async throws -> Typing {
		let (model, _) = try await realLibrary(password: "correct horse battery", filled: false)
		try await fill(model, with: RealisticCorpus.bodies(count: count))
		return try Typing(model)
	}

	@Test func savingAndRegroupingStayFastOnAThousandNotes() async throws {
		let thousand = try await typing(onLibraryOf: 1_000)
		let ten = try await typing(onLibraryOf: 10)
		var keystrokesOnAThousand = Timings()
		var keystrokesOnTen = Timings()
		var saves = Timings()

		for index in 0 ..< 200 {
			keystrokesOnAThousand.measureProcessorTime { thousand.keystroke(index) }
			keystrokesOnTen.measureProcessorTime { ten.keystroke(index) }
			if index.isMultiple(of: 4) {
				await saves.measure { #expect(await thousand.model.flushPendingSaves()) }
			}
		}

		#expect(thousand.model.noteCount == 1_000 && ten.model.noteCount == 10)
		let growthOfTheLibrary = Double(thousand.model.noteCount / ten.model.noteCount)
		for fraction in [0.5, 0.95] {
			let costs = "at the \(fraction) quantile a keystroke takes \(keystrokesOnAThousand.percentile(fraction)) ms of processor time on 1,000 notes and \(keystrokesOnTen.percentile(fraction)) ms on 10"
			#expect(keystrokesOnAThousand.percentile(fraction) <= growthOfTheLibrary * keystrokesOnTen.percentile(fraction), "\(costs)")
		}
		#expect(saves.percentile(0.95) < 100, "save p95 \(saves.percentile(0.95)) ms")
		#expect(await ten.model.flushPendingSaves())
	}
}
