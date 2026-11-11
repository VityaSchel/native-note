import NativeNoteKit
import SwiftUI

struct PhraseFields: View {
	@Binding var entry: PhraseEntry
	let submit: () -> Void

	@FocusState private var editing: Int?
	@State private var leaving: Int?

	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
				ForEach(0 ..< PhraseEntry.count / RecoveryWords.columns, id: \.self) { row in
					GridRow {
						ForEach(row * RecoveryWords.columns ..< (row + 1) * RecoveryWords.columns, id: \.self, content: field)
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
		}
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

	private var problem: String? {
		switch entry.problem(editing: editing) {
		case let .unknownWord(index): "Word \(index + 1) is not in the recovery word list."
		case .checksum: "These words are not a recovery phrase. Check for a mistyped or swapped word."
		case nil: nil
		}
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
