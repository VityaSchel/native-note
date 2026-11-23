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
	var announce: (String) -> Void = VoiceOver.announce

	@State private var spokenLine: String?

	var body: some View {
		let line = Self.line(for: controls.state, listening: listeningLine)
		let inBackground = controls.state == .paused(.inBackground)
		VStack(spacing: 10) {
			switch controls.state {
			case .hidden, .lockedOut, .working:
				EmptyView()
			case let .listening(context):
				TouchIDGlyph(mode: .listening(context, label: glyphLabel), listen: controls.listen)
					.frame(width: TouchIDGlyphView.side, height: TouchIDGlyphView.side)
			case .paused:
				TouchIDGlyph(mode: .dimmed)
					.frame(width: TouchIDGlyphView.side, height: TouchIDGlyphView.side)
			case .needsClick:
				Button(Self.tryAgainTitle, systemImage: "touchid", action: controls.tryAgain)
					.labelStyle(.titleAndIcon)
			}

			ReservedLine(text: line)
				.font(.callout)
				.foregroundStyle(.secondary)
				.multilineTextAlignment(.center)
		}
		.onChange(of: inBackground ? nil : line, initial: true) { _, line in
			guard !inBackground, line != spokenLine else { return }
			spokenLine = line
			if let line { announce(line) }
		}
	}

	static let tryAgainTitle = "Try Touch ID Again"

	static func line(for state: AppModel.TouchID, listening: String) -> String? {
		switch state {
		case .hidden, .lockedOut, .working: nil
		case .listening, .paused: listening
		case .needsClick(after: .miss): "Touch ID didn't match."
		case .needsClick: "Touch ID stopped."
		}
	}
}
