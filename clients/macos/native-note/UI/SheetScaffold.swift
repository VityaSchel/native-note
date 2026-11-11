import SwiftUI

/// Every sheet's frame, as Apple's own sheets are laid out: a title, one line saying what the sheet does, labeled fields, the error under them, and the buttons at the bottom trailing edge.
struct SheetScaffold<Fields: View, Buttons: View>: View {
	let title: String
	var explanation: String?
	var error: String?
	var working = false
	var width: CGFloat = 400
	@ViewBuilder var fields: Fields
	@ViewBuilder var buttons: Buttons
	/// A new error is read out, since VoiceOver stays on the field it came from.
	var announce: (String) -> Void = { AccessibilityNotification.Announcement($0).post() }

	var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			Text(title)
				.font(.headline)
				.accessibilityAddTraits(.isHeader)
			if let explanation {
				Text(explanation)
					.font(.callout)
					.foregroundStyle(.secondary)
					.fixedSize(horizontal: false, vertical: true)
			}
			fields
			if let error {
				Text(error)
					.font(.callout)
					.foregroundStyle(.red)
					.fixedSize(horizontal: false, vertical: true)
			}
			HStack {
				if working {
					ProgressView().controlSize(.small)
				}
				Spacer()
				buttons
			}
		}
		.textFieldStyle(.roundedBorder)
		.padding(20)
		.frame(width: width)
		.onChange(of: error) { _, error in
			if let error { announce(error) }
		}
	}
}
