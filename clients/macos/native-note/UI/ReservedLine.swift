import SwiftUI

struct ReservedLine: View {
	let text: String?
	var lines = 1

	var body: some View {
		ZStack(alignment: .top) {
			Text(verbatim: Array(repeating: " ", count: lines).joined(separator: "\n"))
				.hidden()
				.accessibilityHidden(true)
			if let text {
				Text(text)
					.fixedSize(horizontal: false, vertical: true)
			}
		}
	}
}
