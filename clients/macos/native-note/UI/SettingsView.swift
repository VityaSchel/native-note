import NativeNoteKit
import SwiftUI

struct SettingsView: View {
	let model: AppModel

	var isAvailable: Bool {
		model.phase == .unlocked
	}

	var body: some View {
		Group {
			if isAvailable {
				SecuritySettings(
					touchIDAvailable: model.isBiometricUnlockAvailable,
					touchIDEnabled: model.isBiometricUnlockEnabled,
					turnOnTouchID: model.enableBiometricUnlock(password:),
					turnOffTouchID: model.disableBiometricUnlock,
					changePassword: model.changePassword(from:to:),
					touchID: TouchIDControls(model),
					sync: SyncControls(model)
				)
				.fixedSize(horizontal: false, vertical: true)
			} else {
				ContentUnavailableView(Self.lockedMessage, systemImage: "lock")
					.frame(height: Self.lockedHeight)
			}
		}
		.frame(width: Self.width)
	}

	static let lockedMessage = "Unlock Native Note to change settings."
	static let width: CGFloat = 440
	static let lockedHeight: CGFloat = 240
}

struct SecuritySettings: View {
	enum Sheet: Identifiable {
		case turnOnTouchID
		case changePassword
		case setUpSync
		case changeRecoveryPhrase

		var id: Self { self }
	}

	let touchIDAvailable: Bool
	let touchIDEnabled: Bool
	let turnOnTouchID: (String) async -> AppModel.Failure?
	let turnOffTouchID: () -> Void
	let changePassword: (String, String) async -> AppModel.Failure?
	var touchID = TouchIDControls()
	var sync = SyncControls()

	@State private var sheet: Sheet?

	var body: some View {
		SecurityForm(touchIDAvailable: touchIDAvailable, touchIDEnabled: touchIDEnabled, turnOffTouchID: turnOffTouchID, sync: sync) { sheet = $0 }
			.sheet(item: $sheet) { content(for: $0) { sheet = nil } }
	}

	@ViewBuilder
	func content(for sheet: Sheet, done: @escaping () -> Void) -> some View {
		switch sheet {
		case .turnOnTouchID:
			TurnOnTouchIDView(turnOn: turnOnTouchID, done: done, touchID: touchID)
		case .changePassword:
			ChangePasswordView(turnsTouchIDOff: touchIDEnabled, change: changePassword, done: done)
		case .setUpSync:
			SyncSetupView(mode: .setUp, controls: sync, done: done)
		case .changeRecoveryPhrase:
			SyncSetupView(mode: .rotate, controls: sync, done: done)
		}
	}
}

struct SecurityForm: View {
	let touchIDAvailable: Bool
	let touchIDEnabled: Bool
	let turnOffTouchID: () -> Void
	var sync = SyncControls()
	let present: (SecuritySettings.Sheet) -> Void

	var body: some View {
		Form {
			if touchIDAvailable {
				Section {
					Toggle(isOn: Binding(get: { touchIDEnabled }, set: { on in if on { present(.turnOnTouchID) } else { turnOffTouchID() } })) {
						Text("Unlock with Touch ID")
						Text("Use your fingerprint instead of typing the password.")
					}
				} header: {
					Text("Unlock")
				} footer: {
					Text("Changing the password turns Touch ID unlock off.")
						.font(.caption)
						.foregroundStyle(.secondary)
				}
			}
			Section("Password") {
				LabeledContent {
					Button("Change Password…") { present(.changePassword) }
				} label: {
					Text("Unlock password")
					Text("Opens your notes on this Mac. It cannot be recovered.")
				}
			}
			SyncSection(controls: sync, present: present)
		}
		.formStyle(.grouped)
	}
}

struct SyncSection: View {
	let controls: SyncControls
	let present: (SecuritySettings.Sheet) -> Void

	var body: some View {
		Section("Sync") {
			if let server = controls.status.server {
				LabeledContent("Server", value: server)
				LabeledContent {
					Button("Sync Now") { Task { await controls.syncNow() } }
						.disabled(controls.status.phase == .syncing)
				} label: {
					Text(Self.statusLine(controls.status))
					ForEach(controls.status.problems, id: \.self) { Text($0) }
				}
				LabeledContent {
					Button("Change Recovery Phrase…") { present(.changeRecoveryPhrase) }
				} label: {
					Text("Recovery phrase")
					Text("Restores your notes on another Mac. Native Note never keeps it.")
				}
			} else {
				LabeledContent {
					Button("Set Up Sync…") { present(.setUpSync) }
				} label: {
					Text("Sync with a server")
					Text("Keep your notes on your own Native Note server, end-to-end encrypted.")
				}
			}
		}
	}

	static func statusLine(_ status: AppModel.SyncStatus) -> String {
		switch status.phase {
		case .syncing: "Syncing…"
		case let .failed(reason): reason
		case .off, .idle: status.lastSynced.map { "Last synced \($0.formatted(.relative(presentation: .named)))" } ?? "Not synced yet"
		}
	}
}

#Preview("Settings") {
	SecuritySettings(touchIDAvailable: true, touchIDEnabled: true, turnOnTouchID: { _ in nil }, turnOffTouchID: {}, changePassword: { _, _ in nil })
		.frame(width: 440)
}

#Preview("Settings, no Touch ID") {
	SecuritySettings(touchIDAvailable: false, touchIDEnabled: false, turnOnTouchID: { _ in nil }, turnOffTouchID: {}, changePassword: { _, _ in nil })
		.frame(width: 440)
}
