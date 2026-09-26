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
					}
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

	var body: some View {
		Form {
			if touchIDAvailable {
				Toggle("Unlock with Touch ID", isOn: Binding(get: { touchIDEnabled }, set: { on in Task { await setTouchID(on) } }))
			}
		}
		.formStyle(.grouped)
	}
}

#Preview("Settings") {
	SecuritySettings(touchIDAvailable: true, touchIDEnabled: true, setTouchID: { _ in })
		.frame(width: 440)
}

#Preview("Settings, no Touch ID") {
	SecuritySettings(touchIDAvailable: false, touchIDEnabled: false, setTouchID: { _ in })
		.frame(width: 440)
}
