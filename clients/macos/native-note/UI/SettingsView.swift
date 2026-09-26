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
					setTouchID: { on in
						if on { await model.enableBiometricUnlock() } else { model.disableBiometricUnlock() }
					},
					changePassword: model.changePassword(from:to:)
				)
			} else {
				ContentUnavailableView(Self.lockedMessage, systemImage: "lock")
					.frame(minHeight: 240)
			}
		}
		.frame(width: 440)
	}

	static let lockedMessage = "Unlock Native Note to change settings."
}

struct SecuritySettings: View {
	let touchIDAvailable: Bool
	let touchIDEnabled: Bool
	let setTouchID: (Bool) async -> Void
	let changePassword: (String, String) async -> AppModel.Failure?

	@State private var changingPassword = false

	var body: some View {
		Form {
			if touchIDAvailable {
				Section {
					Toggle(isOn: Binding(get: { touchIDEnabled }, set: { on in Task { await setTouchID(on) } })) {
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
					Button("Change Password…") { changingPassword = true }
				} label: {
					Text("Unlock password")
					Text("Opens your notes on this Mac. It cannot be recovered.")
				}
			}
		}
		.formStyle(.grouped)
		.sheet(isPresented: $changingPassword) {
			ChangePasswordView(turnsTouchIDOff: touchIDEnabled, change: changePassword) { changingPassword = false }
		}
	}
}

#Preview("Settings") {
	SecuritySettings(touchIDAvailable: true, touchIDEnabled: true, setTouchID: { _ in }, changePassword: { _, _ in nil })
		.frame(width: 440)
}

#Preview("Settings, no Touch ID") {
	SecuritySettings(touchIDAvailable: false, touchIDEnabled: false, setTouchID: { _ in }, changePassword: { _, _ in nil })
		.frame(width: 440)
}
