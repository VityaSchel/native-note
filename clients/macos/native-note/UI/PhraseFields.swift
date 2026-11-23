import NativeNoteKit
import SwiftUI

struct PhraseFields: View {
	@Binding var entry: PhraseEntry
	let submit: () -> Void
	var announce: (String) -> Void = VoiceOver.announce
	var tookFocus: () -> Void = {}

	@FocusState private var editing: Int?
	@State private var leaving: Int?
	@State private var checksumSpokenFor: [String]?
	@State private var editingBeforeDisabled: Int?
	@Environment(\.isEnabled) private var isEnabled

	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			HStack(alignment: .top, spacing: 10) {
				ForEach(0 ..< RecoveryWords.columns, id: \.self) { column in
					VStack(alignment: .leading, spacing: 6) {
						ForEach(column * RecoveryWords.rows ..< (column + 1) * RecoveryWords.rows, id: \.self, content: field)
					}
				}
			}
			ReservedLine(text: checksumLine)
				.font(.callout)
				.foregroundStyle(.red)
		}
		.onChange(of: editing) { left, now in
			let spoken = left.map { entry.isInvalid(at: $0, editing: $0) } ?? true
			for index in Set([left, leaving].compactMap(\.self)) {
				entry.complete(at: index)
			}
			leaving = nil
			if let left, !spoken, entry.isInvalid(at: left, editing: now) { announce(Self.unknownWordMessage(left + 1)) }
			if left != nil, entry.texts != checksumSpokenFor, entry.problem(editing: now) == .checksum { announceChecksum() }
			if left == nil, now != nil { tookFocus() }
		}
		.onAppear {
			Task { if editing == nil { editing = 0 } }
		}
		.onChange(of: isEnabled) { _, enabled in
			if !enabled {
				editingBeforeDisabled = editing
			} else if let index = editingBeforeDisabled {
				Task { if editing == nil { editing = index } }
			}
		}
		.onChange(of: unknownWord) { _, index in
			if let index, index == editing { announce(Self.unknownWordMessage(index + 1)) }
		}
	}

	static func unknownWordMessage(_ number: Int) -> String {
		"\(wordName(number)) is not in the recovery word list."
	}

	static let unknownWordLabel = "Not in the recovery word list"

	static func wordName(_ number: Int) -> String {
		"Word \(number)"
	}

	private var unknownWord: Int? {
		guard case let .unknownWord(index) = entry.problem(editing: editing) else { return nil }
		return index
	}

	private func field(_ index: Int) -> some View {
		HStack(spacing: 4) {
			WordNumber(index: index)
			TextField(Self.wordName(index + 1), text: word(index), prompt: Text(verbatim: ""))
				.accessibilityLabel(Self.wordName(index + 1))
				.focused($editing, equals: index)
				.flagsUnknownWord(entry.isInvalid(at: index, editing: editing))
				.autocorrectionDisabled()
				.onSubmit { submitted(index) }
				.onKeyPress(keys: [.tab, Self.backTab], phases: .down) { press in moveByTab(from: index, back: press.key == Self.backTab) }
		}
	}

	private static let backTab = KeyEquivalent("\u{19}")

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
		if entry.opens { return submit() }
		if entry.problem(editing: editing) == .checksum { announceChecksum() }
		if index + 1 < PhraseEntry.count { editing = index + 1 }
	}

	static let checksumMessage = "These words are not a recovery phrase. Check for a mistyped or swapped word."

	private var checksumLine: String? {
		entry.problem(editing: editing) == .checksum ? Self.checksumMessage : nil
	}

	private func announceChecksum() {
		checksumSpokenFor = entry.texts
		announce(Self.checksumMessage)
	}
}

extension View {
	func flagsUnknownWord(_ unknown: Bool) -> some View {
		foregroundStyle(unknown ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
			.overlay(alignment: .trailing) {
				if unknown {
					Image(systemName: "exclamationmark.circle.fill")
						.foregroundStyle(.red)
						.padding(.trailing, 5)
						.allowsHitTesting(false)
						.accessibilityLabel(PhraseFields.unknownWordLabel)
				}
			}
	}
}

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
