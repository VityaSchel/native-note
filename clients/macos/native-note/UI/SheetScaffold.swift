import SwiftUI

struct SheetScaffold<Fields: View, Leading: View, Buttons: View>: View {
	let title: String
	var explanation: String?
	var error: String?
	var working = false
	var width: CGFloat = 400
	var reservesError = true
	@ViewBuilder var fields: Fields
	@ViewBuilder var leadingButtons: Leading
	@ViewBuilder var buttons: Buttons
	var announce: (AttributedString) -> Void = VoiceOver.post

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
			if reservesError || error != nil {
				ReservedLine(text: error, lines: 2)
					.font(.callout)
					.foregroundStyle(.red)
			}
			HStack {
				leadingButtons
				if working {
					ProgressView().controlSize(.small)
						.accessibilityHidden(true)
				}
				Spacer()
				buttons
			}
		}
		.textFieldStyle(.roundedBorder)
		.padding(20)
		.frame(width: width)
		.onChange(of: error) { _, error in
			if let error { announce(VoiceOver.aboveFocusChanges(error)) }
		}
	}
}

extension SheetScaffold where Leading == EmptyView {
	init(
		title: String,
		explanation: String? = nil,
		error: String? = nil,
		working: Bool = false,
		width: CGFloat = 400,
		reservesError: Bool = true,
		@ViewBuilder fields: () -> Fields,
		@ViewBuilder buttons: () -> Buttons,
		announce: @escaping (AttributedString) -> Void = VoiceOver.post
	) {
		self.init(
			title: title, explanation: explanation, error: error, working: working, width: width, reservesError: reservesError,
			fields: fields, leadingButtons: { EmptyView() }, buttons: buttons, announce: announce
		)
	}
}
