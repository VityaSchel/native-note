import NativeNoteKit
import SwiftUI

struct PhraseFields: View {
	@Binding var entry: PhraseEntry
	let submit: () -> Void

	@FocusState private var editing: Int?
	@State private var leaving: Int?

	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			HStack(alignment: .top, spacing: 10) {
				ForEach(0 ..< RecoveryWords.columns, id: \.self) { column in
					VStack(alignment: .leading, spacing: 6) {
						ForEach(column * RecoveryWords.rows ..< (column + 1) * RecoveryWords.rows, id: \.self, content: field)
					}
				}
			}
			Text(problem ?? " ")
				.font(.callout)
				.foregroundStyle(.red)
				.fixedSize(horizontal: false, vertical: true)
				.accessibilityHidden(problem == nil)
		}
		.onChange(of: editing) { left, _ in
			for index in Set([left, leaving].compactMap(\.self)) {
				entry.complete(at: index)
			}
			leaving = nil
		}
		.onAppear {
			Task { if editing == nil { editing = 0 } }
		}
	}

	private func field(_ index: Int) -> some View {
		HStack(spacing: 4) {
			WordNumber(index: index)
			TextField("Word \(index + 1)", text: word(index), prompt: Text(verbatim: ""))
				.focused($editing, equals: index)
				.foregroundStyle(entry.isInvalid(at: index, editing: editing) ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
				.autocorrectionDisabled()
				.onSubmit { submitted(index) }
				.onKeyPress(keys: [.tab, Self.backTab], phases: .down) { press in moveByTab(from: index, back: press.key == Self.backTab) }
		}
	}

	/// Shift-Tab arrives as the back-tab character.
	private static let backTab = KeyEquivalent("\u{19}")

	/// Tab follows the words down each column, as Return and Space do, not the fields' order across the rows.
	private func moveByTab(from index: Int, back: Bool) -> KeyPress.Result {
		let next = back ? index - 1 : index + 1
		guard (0 ..< PhraseEntry.count).contains(next) else { return .ignored }
		editing = next
		return .handled
	}

	private func word(_ index: Int) -> Binding<String> {
		Binding {
			entry.texts[index]
		} set: { text in
			guard let next = entry.set(text, at: index) else { return }
			if next != index { leaving = index }
			editing = next
		}
	}

	private func submitted(_ index: Int) {
		entry.complete(at: index)
		if entry.opens {
			submit()
		} else if index + 1 < PhraseEntry.count {
			editing = index + 1
		}
	}

	/// A word off the list shows in red; only a checksum failure, which no single field shows, gets a line.
	private var problem: String? {
		entry.problem(editing: editing) == .checksum ? "These words are not a recovery phrase. Check for a mistyped or swapped word." : nil
	}
}

/// The secondary, right-aligned number every view of the recovery words puts before a word, so columns line up past 9.
struct WordNumber: View {
	let index: Int

	var body: some View {
		Text(verbatim: "\(index + 1).")
			.monospacedDigit()
			.foregroundStyle(.secondary)
			.frame(width: 22, alignment: .trailing)
			.accessibilityHidden(true)
	}
}

#if DEBUG
	#Preview("Phrase fields") {
		@Previewable @State var entry = PhraseEntry()
		PhraseFields(entry: $entry, submit: {})
			.textFieldStyle(.roundedBorder)
			.padding(20)
			.frame(width: 440)
	}
#endif
