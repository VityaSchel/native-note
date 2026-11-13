import NativeNoteKit
import SwiftUI

struct ExportSheet: View {
	let export: (String?) -> Void
	let cancel: () -> Void

	@State private var form = ExportForm()
	@FocusState private var focus: Field?

	private enum Field {
		case passphrase, confirmation
	}

	var body: some View {
		SheetScaffold(
			title: "Export Notes",
			explanation: "The export holds every note as a markdown file. Without a passphrase, anyone with the file can read them.",
			error: form.mismatched ? "The passphrases do not match." : nil
		) {
			Toggle("Encrypt with a passphrase", isOn: $form.encrypts)
			if form.encrypts {
				Form {
					SecureField("Passphrase:", text: $form.passphrase)
						.focused($focus, equals: .passphrase)
						.onSubmit { focus = .confirmation }
					SecureField("Verify:", text: $form.confirmation)
						.focused($focus, equals: .confirmation)
						.onSubmit { if form.canExport { export(form.passphraseToUse) } }
				}
				.formStyle(.columns)
			}
		} buttons: {
			Button("Cancel", role: .cancel, action: cancel)
				.keyboardShortcut(.cancelAction)
			Button("Export…") { export(form.passphraseToUse) }
				.keyboardShortcut(.defaultAction)
				.disabled(!form.canExport)
		}
		.onChange(of: form.encrypts) { _, encrypts in focus = encrypts ? .passphrase : nil }
	}
}

struct ImportPassphraseSheet: View {
	let refused: Bool
	let working: Bool
	let submit: (String) -> Void
	let cancel: () -> Void

	@State private var passphrase = ""
	@FocusState private var typing: Bool

	var body: some View {
		SheetScaffold(
			title: "Enter Export Passphrase",
			explanation: "Enter the passphrase the export was made with.",
			error: refused ? "Wrong passphrase, or the export is damaged." : nil,
			working: working
		) {
			Form {
				SecureField("Passphrase:", text: $passphrase)
					.focused($typing)
					.onSubmit { if !passphrase.isEmpty, !working { submit(passphrase) } }
			}
			.formStyle(.columns)
		} buttons: {
			Button("Cancel", role: .cancel, action: cancel)
				.keyboardShortcut(.cancelAction)
				.disabled(working)
			Button("Import") { submit(passphrase) }
				.keyboardShortcut(.defaultAction)
				.disabled(passphrase.isEmpty || working)
		}
		.defaultFocus($typing, true)
	}
}

extension ImportSummary {
	var message: String {
		let imported = String(AttributedString(localized: "Imported ^[\(added) note](inflect: true).").characters)
		let details = [
			skipped > 0 ? "\(skipped) already here or deleted here" : nil,
			notImported > 0 ? "\(notImported) not imported because Native Note locked" : nil,
		].compactMap(\.self)
		return details.isEmpty ? imported : "\(imported) \(details.joined(separator: ", "))."
	}
}
