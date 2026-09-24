import NativeNoteKit
import SwiftUI

struct ExportSheet: View {
	let export: (String?) -> Void
	let cancel: () -> Void

	@State private var form = ExportForm()

	var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			Text("Export notes")
				.font(.title3.weight(.semibold))
			Text("The export holds every note as a markdown file. Without a passphrase, anyone with the file can read them.")
				.foregroundStyle(.secondary)
				.fixedSize(horizontal: false, vertical: true)
			Toggle("Encrypt with a passphrase", isOn: $form.encrypts)
			if form.encrypts {
				SecureField("Passphrase", text: $form.passphrase)
				SecureField("Confirm passphrase", text: $form.confirmation)
				if form.mismatched {
					Text("The passphrases do not match.")
						.font(.callout)
						.foregroundStyle(.red)
				}
			}
			HStack {
				Spacer()
				Button("Cancel", role: .cancel, action: cancel)
				Button("Export…") { export(form.passphraseToUse) }
					.keyboardShortcut(.defaultAction)
					.disabled(!form.canExport)
			}
		}
		.textFieldStyle(.roundedBorder)
		.padding(24)
		.frame(width: 380)
	}
}

struct ImportPassphraseSheet: View {
	let refused: Bool
	let working: Bool
	let submit: (String) -> Void
	let cancel: () -> Void

	@State private var passphrase = ""

	var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			Text("Encrypted export")
				.font(.title3.weight(.semibold))
			Text("Enter the passphrase the export was made with.")
				.foregroundStyle(.secondary)
			SecureField("Passphrase", text: $passphrase)
				.textFieldStyle(.roundedBorder)
				.onSubmit { if !passphrase.isEmpty, !working { submit(passphrase) } }
			if refused {
				Text("Wrong passphrase, or the export is damaged.")
					.font(.callout)
					.foregroundStyle(.red)
			}
			HStack {
				if working {
					ProgressView().controlSize(.small)
				}
				Spacer()
				Button("Cancel", role: .cancel, action: cancel)
					.disabled(working)
				Button("Import") { submit(passphrase) }
					.keyboardShortcut(.defaultAction)
					.disabled(passphrase.isEmpty || working)
			}
		}
		.padding(24)
		.frame(width: 380)
	}
}

struct ConflictSheet: View {
	let conflicts: [NoteConflict]
	let resolve: (NoteConflict, NoteConflict.Choice) -> Void

	var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			Text(conflicts.count == 1 ? "1 note differs from the export" : "\(conflicts.count) notes differ from the export")
				.font(.title3.weight(.semibold))
			ScrollView {
				VStack(alignment: .leading, spacing: 16) {
					ForEach(conflicts) { conflict in
						ConflictRow(conflict: conflict, resolve: resolve)
					}
				}
			}
		}
		.padding(24)
		.frame(width: 560, height: 420)
	}
}

struct ConflictRow: View {
	let conflict: NoteConflict
	let resolve: (NoteConflict, NoteConflict.Choice) -> Void

	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			Text(conflict.mine.title.isEmpty ? "New note" : conflict.mine.title)
				.font(.headline)
			HStack(alignment: .top, spacing: 12) {
				version("On this Mac", conflict.mine, keep: .keepMine)
				version("In the export", conflict.theirs, keep: .keepTheirs)
			}
		}
	}

	private func version(_ label: String, _ note: Note, keep choice: NoteConflict.Choice) -> some View {
		VStack(alignment: .leading, spacing: 4) {
			Text(label)
				.font(.caption)
				.foregroundStyle(.secondary)
			Text(note.body)
				.lineLimit(4)
				.frame(maxWidth: .infinity, alignment: .leading)
			Text(note.updatedAt, format: .dateTime)
				.font(.caption)
				.foregroundStyle(.secondary)
			Button(choice == .keepMine ? "Keep mine" : "Keep theirs") { resolve(conflict, choice) }
		}
		.frame(maxWidth: .infinity, alignment: .leading)
	}
}

extension ImportSummary {
	var message: String {
		let imported = added == 1 ? "Imported 1 note." : "Imported \(added) notes."
		let details = [
			unchanged > 0 ? "\(unchanged) already here" : nil,
			conflicting > 0 ? "\(conflicting) differ" : nil,
			deletedHere > 0 ? "\(deletedHere) deleted here" : nil,
			notImported > 0 ? "\(notImported) not imported because Native Note locked" : nil,
		].compactMap(\.self)
		return details.isEmpty ? imported : "\(imported) \(details.joined(separator: ", "))."
	}
}
