import SwiftUI

extension View {
	func capsuleField(trailingInset: CGFloat = 14) -> some View {
		modifier(CapsuleField(trailingInset: trailingInset))
	}
}

private struct CapsuleField: ViewModifier {
	let trailingInset: CGFloat

	@Environment(\.colorSchemeContrast) private var contrast

	func body(content: Content) -> some View {
		content
			.textFieldStyle(.plain)
			.font(.system(size: 15))
			.padding(.leading, 14)
			.padding(.trailing, trailingInset)
			.frame(height: UnlockView.fieldHeight)
			.background(Color(nsColor: .textBackgroundColor), in: Capsule())
			.overlay(Capsule().strokeBorder(contrast == .increased ? AnyShapeStyle(.secondary) : AnyShapeStyle(.separator)))
	}
}
