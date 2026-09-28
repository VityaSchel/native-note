import AppKit
import LocalAuthentication
import NativeNoteKit
import SwiftUI

struct UnlockView: View {
	let isSetup: Bool
	let failure: AppModel.Failure?
	let submit: (String) async -> AppModel.Failure?
	let dismissFailure: () -> Void
	var touchID = TouchIDControls()
	var shake = AppModel.Shake()
	var eraseLibrary: (() -> Void)?
	var hasSecureEnclave = true
	var announce: (String) -> Void = { AccessibilityNotification.Announcement($0).post() }

	@State private var form = UnlockForm()
	@State private var confirmingErase = false
	@State private var anchor = WindowAnchor()
	@FocusState private var typingPassword: Bool

	var body: some View {
		VStack(spacing: 18) {
			Image(systemName: isSetup ? "key.shield.fill" : "lock.shield.fill")
				.font(.system(size: 56))
				.foregroundStyle(.tint)

			VStack(spacing: 6) {
				Text(isSetup ? "Set an Unlock Password" : "Native Note")
					.font(.largeTitle.bold())
				if isSetup {
					Text("Notes are encrypted with this password. It cannot be recovered.")
						.font(.callout)
						.foregroundStyle(.secondary)
						.multilineTextAlignment(.center)
						.fixedSize(horizontal: false, vertical: true)
				}
			}

			if isSetup {
				setupForm
			} else {
				lockForm
			}
		}
		.confirmationDialog(Self.eraseTitle, isPresented: $confirmingErase) {
			Button(Self.eraseAction, role: .destructive) { eraseLibrary?() }
		} message: {
			Text(Self.eraseMessage)
		}
		.frame(width: 300)
		.padding(32)
		.failureAlert(failure, dismiss: dismissFailure)
	}

	@ViewBuilder private var setupForm: some View {
		if let setupWarning {
			Label(setupWarning, systemImage: "exclamationmark.triangle")
				.font(.callout)
				.foregroundStyle(.orange)
				.fixedSize(horizontal: false, vertical: true)
		}

		VStack(spacing: 10) {
			SecureField("Password", text: $form.password)
				.onSubmit(send)
			SecureField("Confirm Password", text: $form.confirmation)
				.onSubmit(send)
		}
		.textFieldStyle(.roundedBorder)
		.controlSize(.extraLarge)

		Text(form.inlineMessage ?? " ")
			.font(.callout)
			.foregroundStyle(.red)
			.frame(minHeight: 18)

		Button(action: send) {
			working("Create", spinning: form.working)
		}
		.buttonStyle(.glassProminent)
		.keyboardShortcut(.defaultAction)
		.controlSize(.extraLarge)
		.disabled(!form.canSubmit)
	}

	private var lockForm: some View {
		VStack(spacing: 0) {
			passwordField

			if touchID.isBiometricUnlockEnabled || line != nil {
				Text(line ?? " ")
					.font(.callout)
					.foregroundStyle(.secondary)
					.multilineTextAlignment(.center)
					.fixedSize(horizontal: false, vertical: true)
					.padding(.top, 8)
					.opacity(line == nil ? 0 : 1)
					.accessibilityHidden(line == nil)
			}

			if eraseLibrary != nil {
				Button("Forgot Password?") { confirmingErase = true }
					.buttonStyle(.link)
					.disabled(form.working || opensWithTouchID)
					.padding(.top, 12)
			}
		}
		.onAppear(perform: focusPassword)
		.onChange(of: opensWithTouchID) { _, opening in
			if !opening { focusPassword() }
		}
		.onChange(of: line) { _, line in
			if line == Self.touchIDStoppedLine { announce(Self.touchIDStoppedLine) }
		}
		.onChange(of: shake.isRunning) { _, running in
			if !running { selectRejectedPassword() }
		}
		.onChange(of: form.rejected) { _, rejected in
			if rejected, !shake.isRunning { selectRejectedPassword() }
		}
		.background(WindowAnchorView(anchor: anchor).allowsHitTesting(false))
	}

	private var passwordField: some View {
		ZStack {
			if case let .listening(context) = touchID.state {
				TouchIDGlyph(mode: .listening(context), label: nil, size: .mini, listen: touchID.listen)
					.frame(width: Self.coveredGlyphSide, height: Self.coveredGlyphSide)
					.allowsHitTesting(false)
					.accessibilityHidden(true)
			}

			HStack(spacing: 6) {
				SecureField("Password", text: $form.password)
					.textFieldStyle(.plain)
					.font(.system(size: 15))
					.focused($typingPassword)
					.onSubmit(send)
					.disabled(opensWithTouchID)

				ZStack {
					if form.working || opensWithTouchID {
						ProgressView().controlSize(.small)
					} else if !form.password.isEmpty {
						Button(action: send) {
							Image(systemName: "arrow.forward.circle.fill")
								.resizable()
								.frame(width: Self.arrowSide, height: Self.arrowSide)
						}
						.buttonStyle(.plain)
						.foregroundStyle(.tint)
						.accessibilityLabel(Self.arrowLabel)
					}
				}
				.frame(width: Self.arrowSide, height: Self.arrowSide)
			}
			.padding(.leading, 14)
			.padding(.trailing, 7)
			.frame(height: Self.fieldHeight)
			.background(Color(nsColor: .textBackgroundColor), in: Capsule())
			.overlay(Capsule().strokeBorder(.separator))
		}
		.animation(.linear(duration: ShakeEffect.duration)) { $0.modifier(ShakeEffect(animatableData: CGFloat(shake.count))) }
	}

	private func working(_ title: String, spinning: Bool) -> some View {
		ZStack {
			Text(title).opacity(spinning ? 0 : 1)
			if spinning {
				ProgressView().controlSize(.small)
			}
		}
		.frame(maxWidth: .infinity)
	}

	var setupWarning: String? {
		isSetup && !hasSecureEnclave ? Self.noSecureEnclaveWarning : nil
	}

	private var opensWithTouchID: Bool {
		touchID.state == .working
	}

	private var line: String? {
		Self.line(for: touchID.state)
	}

	static func line(for state: AppModel.TouchID) -> String? {
		switch state {
		case .hidden: nil
		case .listening, .paused, .working: touchIDLine
		case .needsClick, .lockedOut: touchIDStoppedLine
		}
	}

	static let noSecureEnclaveWarning = "This Mac has no Secure Enclave, so only this password protects your notes."
	static let eraseTitle = "Erase all notes and start over?"
	static let eraseAction = "Erase Notes"
	static let eraseMessage = "Without the password these notes cannot be recovered. Erasing deletes every note on this Mac and returns to setup."
	static let touchIDLine = "Touch ID or enter password"
	static let touchIDStoppedLine = "Enter password to enable Touch ID"
	static let wrongPasswordAnnouncement = "Wrong password"
	static let arrowLabel = "Unlock"
	static let fieldHeight: CGFloat = 36
	static let arrowSide: CGFloat = 22
	static let coveredGlyphSide: CGFloat = 16

	private func send() {
		guard let password = form.submit(confirming: isSetup) else { return }
		Task {
			let failure = await submit(password)
			form.finish(failure)
			if failure == .wrongPassword { announce(Self.wrongPasswordAnnouncement) }
		}
	}

	private func focusPassword() {
		Task { typingPassword = true }
	}

	private func selectRejectedPassword() {
		guard form.takeRejection() else { return }
		if typingPassword, let editor = anchor.view?.window?.firstResponder as? NSText {
			editor.selectAll(nil)
		} else {
			typingPassword = true
		}
	}
}

struct ShakeEffect: GeometryEffect {
	static let amplitude: CGFloat = 14
	static let duration = AppModel.Shake.duration / .seconds(1)

	var animatableData: CGFloat

	static func offset(at elapsed: TimeInterval) -> CGFloat {
		guard elapsed > 0, elapsed < duration else { return 0 }
		let progress = elapsed / duration
		let decay = progress < 0.5 ? 1 : exp(-0.8 * progress)
		return -amplitude * sin(6 * .pi * progress) * decay
	}

	func effectValue(size: CGSize) -> ProjectionTransform {
		let progress = animatableData - animatableData.rounded(.down)
		return ProjectionTransform(CGAffineTransform(translationX: Self.offset(at: progress * Self.duration), y: 0))
	}
}

private final class WindowAnchor {
	weak var view: NSView?
}

private struct WindowAnchorView: NSViewRepresentable {
	let anchor: WindowAnchor

	func makeNSView(context: Context) -> NSView {
		NSView()
	}

	func updateNSView(_ view: NSView, context: Context) {
		anchor.view = view
	}
}

#Preview("Unlock") {
	UnlockView(isSetup: false, failure: nil, submit: { _ in nil }, dismissFailure: {})
}

#Preview("Unlock, listening for Touch ID") {
	UnlockView(isSetup: false, failure: nil, submit: { _ in nil }, dismissFailure: {}, touchID: TouchIDControls(state: .listening(LAContext())), eraseLibrary: {})
}

#Preview("Unlock, Touch ID locked") {
	UnlockView(isSetup: false, failure: nil, submit: { _ in nil }, dismissFailure: {}, touchID: TouchIDControls(state: .lockedOut), eraseLibrary: {})
}

#Preview("Unlock, opening with Touch ID") {
	UnlockView(isSetup: false, failure: nil, submit: { _ in nil }, dismissFailure: {}, touchID: TouchIDControls(state: .working), eraseLibrary: {})
}

#Preview("Unlock, forgotten password") {
	UnlockView(isSetup: false, failure: .wrongPassword, submit: { _ in .wrongPassword }, dismissFailure: {}, eraseLibrary: {})
}

#Preview("Unlock, internal failure") {
	UnlockView(
		isSetup: false,
		failure: .unexpected("The notes database could not be opened. unable to open database file"),
		submit: { _ in nil },
		dismissFailure: {}
	)
}

#Preview("Locked, edits not saved") {
	UnlockView(
		isSetup: false,
		failure: .unsaved("disk I/O error"),
		submit: { _ in nil },
		dismissFailure: {}
	)
}

#Preview("First run") {
	UnlockView(isSetup: true, failure: nil, submit: { _ in nil }, dismissFailure: {})
}

#Preview("First run, no Secure Enclave") {
	UnlockView(isSetup: true, failure: nil, submit: { _ in nil }, dismissFailure: {}, hasSecureEnclave: false)
}
