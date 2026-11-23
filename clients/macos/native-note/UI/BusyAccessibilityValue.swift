import SwiftUI

extension View {
	func busyAccessibilityValue(_ busy: Bool) -> some View {
		accessibilityValue(busy ? Text(OnboardingLabel.busyValue) : Text(verbatim: ""))
	}
}
