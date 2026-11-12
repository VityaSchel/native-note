import AppKit
import NativeNoteKit
import SwiftUI

struct OnboardingView: View {
	enum Step: Equatable {
		case welcome, password, touchID, sync
	}

	let libraryExists: Bool
	let createLibrary: (String) async -> AppModel.Failure?
	var failure: AppModel.Failure?
	var dismissFailure: () -> Void = {}
	var hasSecureEnclave = true
	var touchIDAvailable = false
	var turnOnTouchID: (String) async -> AppModel.Failure? = { _ in nil }
	var touchID = TouchIDControls()
	var sync = SyncControls()
	var clipboard = RecoveryClipboard.shared
	let finish: () -> Void

	@State private var chosen: Step?
	@State private var form = UnlockForm()
	@State private var passwordForTouchID: String?
	@State private var touchIDForm = TurnOnTouchIDForm()
	@State private var touchIDAttempt = 0
	@State private var settingUpSync = false
	@FocusState private var focus: Field?

	private enum Field {
		case password, confirmation
	}

	var step: Step {
		chosen ?? (libraryExists ? .sync : .welcome)
	}

	var body: some View {
		page
			.frame(width: 320)
			.padding(32)
			.failureAlert(failure, dismiss: dismissFailure)
			.sheet(isPresented: $settingUpSync) {
				SyncSetupView(mode: .setUp, controls: sync, clipboard: clipboard, syncTurnedOn: finish) { settingUpSync = false }
			}
	}

	@ViewBuilder
	private var page: some View {
		switch step {
		case .welcome:
			OnboardingPage(title: "Welcome to Native Note", subtitle: Text("A personal encrypted self-hosted note-taking app")) {
				Image(nsImage: NSApp.applicationIconImage)
					.resizable()
					.frame(width: 96, height: 96)
			} content: {
				EmptyView()
			} buttons: {
				Button { chosen = .password } label: { OnboardingLabel(title: "Next") }
					.buttonStyle(.borderedProminent)
					.keyboardShortcut(.defaultAction)
			}
		case .password:
			OnboardingPage(
				title: "Set an Unlock Password",
				subtitle: Text("The app is encrypted with this password. It cannot be recovered."),
				symbol: "key.shield.fill"
			) {
				passwordFields
			} buttons: {
				Button(action: createWithPassword) { OnboardingLabel(title: "Next", busy: form.working) }
					.buttonStyle(.borderedProminent)
					.keyboardShortcut(.defaultAction)
					.disabled(!form.canSubmit)
			}
		case .touchID:
			OnboardingPage(title: "Unlock with Touch ID?", subtitle: Text("Unlock the app with your fingerprint"), symbol: "touchid") {
				touchIDStatus
			} buttons: {
				Button(action: setUpTouchID) { OnboardingLabel(title: "Set Up Touch ID", busy: touchIDForm.working) }
					.buttonStyle(.borderedProminent)
					.keyboardShortcut(.defaultAction)
					.disabled(touchIDForm.working)
				Button(action: skipTouchID) { OnboardingLabel(title: "Skip") }
					.keyboardShortcut(.cancelAction)
			}
		case .sync:
			OnboardingPage(title: "Sync Your Notes", subtitle: Text(Self.syncSubtitle), symbol: "arrow.triangle.2.circlepath") {
				EmptyView()
			} buttons: {
				Button { settingUpSync = true } label: { OnboardingLabel(title: "Set Up") }
					.buttonStyle(.borderedProminent)
					.keyboardShortcut(.defaultAction)
				Button(action: finish) { OnboardingLabel(title: "Not Now") }
					.keyboardShortcut(.cancelAction)
			}
		}
	}

	static var syncSubtitle: AttributedString {
		var server = AttributedString("Native Note server")
		server.link = Guide.syncServer
		return AttributedString("Set up a self-hosted ") + server + AttributedString(" to sync your encrypted notes across devices.")
	}

	static let noSecureEnclaveWarning = "This Mac has no Secure Enclave, so only this password protects your notes."
	static let touchIDLine = "Touch ID to finish turning on Touch ID unlock."
	static let touchIDLabel = "Touch ID to turn on Touch ID unlock"

	@ViewBuilder
	private var passwordFields: some View {
		if !hasSecureEnclave {
			Label(Self.noSecureEnclaveWarning, systemImage: "exclamationmark.triangle")
				.font(.callout)
				.foregroundStyle(.orange)
				.fixedSize(horizontal: false, vertical: true)
		}
		VStack(spacing: 10) {
			TallSecureField(title: "Password", text: $form.password)
				.focused($focus, equals: .password)
				.onSubmit { if form.confirmation.isEmpty { focus = .confirmation } else { createWithPassword() } }
			TallSecureField(title: "Confirm Password", text: $form.confirmation)
				.focused($focus, equals: .confirmation)
				.onSubmit(createWithPassword)
		}
		.disabled(form.working)
		.onAppear { Task { focus = .password } }
		ReservedMessage(text: form.inlineMessage)
	}

	@ViewBuilder
	private var touchIDStatus: some View {
		if touchIDForm.working && touchID.state != .hidden {
			TouchIDStatus(controls: touchID, listeningLine: Self.touchIDLine, glyphLabel: Self.touchIDLabel)
				.frame(maxWidth: .infinity)
		} else {
			ReservedMessage(text: touchIDForm.inlineMessage)
		}
	}

	private func createWithPassword() {
		guard let typed = form.submit(confirming: true) else { return }
		Task {
			let failure = await createLibrary(typed)
			form.finish(failure)
			guard failure == nil else { return }
			if touchIDAvailable {
				passwordForTouchID = typed
				chosen = .touchID
			} else {
				chosen = .sync
			}
		}
	}

	private func setUpTouchID() {
		guard let passwordForTouchID else { return skipTouchID() }
		touchIDForm.password = passwordForTouchID
		guard let sent = touchIDForm.submit() else { return }
		touchIDAttempt += 1
		let attempt = touchIDAttempt
		Task {
			let failure = await turnOnTouchID(sent)
			guard attempt == touchIDAttempt else { return }
			touchIDForm.finish(failure)
			if failure == nil { leaveTouchID() }
		}
	}

	private func skipTouchID() {
		if touchIDForm.working { touchID.cancel() }
		leaveTouchID()
	}

	private func leaveTouchID() {
		touchIDAttempt += 1
		passwordForTouchID = nil
		touchIDForm = TurnOnTouchIDForm()
		chosen = .sync
	}
}

private struct OnboardingPage<Picture: View, Content: View, Buttons: View>: View {
	let title: String
	let subtitle: Text
	@ViewBuilder var picture: Picture
	@ViewBuilder var content: Content
	@ViewBuilder var buttons: Buttons

	var body: some View {
		VStack(spacing: 18) {
			picture
				.accessibilityHidden(true)
			VStack(spacing: 6) {
				Text(title)
					.font(.largeTitle.bold())
					.multilineTextAlignment(.center)
					.accessibilityAddTraits(.isHeader)
				subtitle
					.font(.callout)
					.foregroundStyle(.secondary)
					.multilineTextAlignment(.center)
					.fixedSize(horizontal: false, vertical: true)
			}
			content
			VStack(spacing: 10) {
				buttons
			}
			.controlSize(.extraLarge)
		}
	}
}

extension OnboardingPage where Picture == SymbolPicture {
	init(title: String, subtitle: Text, symbol: String, @ViewBuilder content: () -> Content, @ViewBuilder buttons: () -> Buttons) {
		self.init(title: title, subtitle: subtitle, picture: { SymbolPicture(name: symbol) }, content: content, buttons: buttons)
	}
}

private struct SymbolPicture: View {
	let name: String

	var body: some View {
		Image(systemName: name)
			.font(.system(size: 56))
			.foregroundStyle(.tint)
	}
}

struct OnboardingLabel: View {
	let title: String
	var busy = false

	static let busyValue = "In progress"

	var body: some View {
		HStack(spacing: 8) {
			if busy {
				ProgressView()
					.controlSize(.small)
					.accessibilityHidden(true)
			}
			Text(title)
		}
		.frame(maxWidth: .infinity)
		.accessibilityValue(busy ? Text(Self.busyValue) : Text(verbatim: ""))
	}
}

private struct TallSecureField: View {
	let title: String
	@Binding var text: String

	var body: some View {
		SecureField(title, text: $text)
			.textFieldStyle(.plain)
			.font(.system(size: 15))
			.padding(.horizontal, 14)
			.frame(height: UnlockView.fieldHeight)
			.background(Color(nsColor: .textBackgroundColor), in: Capsule())
			.overlay(Capsule().strokeBorder(.separator))
	}
}

private struct ReservedMessage: View {
	let text: String?

	var body: some View {
		Text(text ?? " ")
			.font(.callout)
			.foregroundStyle(.red)
			.multilineTextAlignment(.center)
			.fixedSize(horizontal: false, vertical: true)
			.frame(minHeight: 18)
			.accessibilityHidden(text == nil)
	}
}

#Preview("Welcome") {
	OnboardingView(libraryExists: false, createLibrary: { _ in nil }, finish: {})
}

#Preview("Sync step") {
	OnboardingView(libraryExists: true, createLibrary: { _ in nil }, finish: {})
}
