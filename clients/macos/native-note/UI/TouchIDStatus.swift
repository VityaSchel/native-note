import LocalAuthentication
import LocalAuthenticationEmbeddedUI
import NativeNoteKit
import SwiftUI

struct TouchIDControls {
	var state = AppModel.TouchID.hidden
	var isBiometricUnlockEnabled = false
	var listen: (LAAuthenticationView) async -> Void = { _ in }
	var tryAgain: () -> Void = {}
	var cancel: () -> Void = {}
}

extension TouchIDControls {
	init(_ model: AppModel) {
		self.init(state: model.touchID, isBiometricUnlockEnabled: model.isBiometricUnlockEnabled, listen: model.listen(through:), tryAgain: model.tryTouchIDAgain, cancel: model.cancelTurningOnTouchID)
	}
}

struct TouchIDStatus: View {
	let controls: TouchIDControls
	let listeningLine: String
	let glyphLabel: String

	var body: some View {
		VStack(spacing: 10) {
			switch controls.state {
			case .hidden, .lockedOut, .working:
				EmptyView()
			case let .listening(context):
				TouchIDGlyph(mode: .listening(context), label: glyphLabel, listen: controls.listen)
					.frame(width: TouchIDGlyphView.side, height: TouchIDGlyphView.side)
			case .paused:
				TouchIDGlyph(mode: .dimmed, label: glyphLabel)
					.frame(width: TouchIDGlyphView.side, height: TouchIDGlyphView.side)
			case .needsClick:
				TryTouchIDAgainButton(action: controls.tryAgain)
			}

			let line = Self.line(for: controls.state, listening: listeningLine)
			Text(line ?? " ")
				.font(.callout)
				.foregroundStyle(.secondary)
				.multilineTextAlignment(.center)
				.fixedSize(horizontal: false, vertical: true)
				.accessibilityHidden(line == nil)
		}
	}

	static func line(for state: AppModel.TouchID, listening: String) -> String? {
		switch state {
		case .hidden, .lockedOut, .working: nil
		case .listening, .paused: listening
		case .needsClick(after: .miss): "Touch ID didn't match."
		case .needsClick: "Touch ID stopped."
		}
	}
}
