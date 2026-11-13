import SwiftUI

extension View {
	func capsuleField(trailingInset: CGFloat = 14) -> some View {
		textFieldStyle(.plain)
			.font(.system(size: 15))
			.padding(.leading, 14)
			.padding(.trailing, trailingInset)
			.frame(height: UnlockView.fieldHeight)
			.background(Color(nsColor: .textBackgroundColor), in: Capsule())
			.overlay(Capsule().strokeBorder(.separator))
	}
}
