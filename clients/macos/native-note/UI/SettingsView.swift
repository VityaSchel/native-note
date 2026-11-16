import NativeNoteKit
import SwiftUI

struct SettingsView: View {
	let model: AppModel

	var isAvailable: Bool {
		model.screen == .library
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
				ContentUnavailableView(model.screen == .onboarding ? Self.setupMessage : Self.lockedMessage, systemImage: "lock")
					.frame(height: Self.lockedHeight)
			}
		}
		.frame(width: Self.width)
	}

	static let lockedMessage = "Unlock Native Note to change settings."
	static let setupMessage = "Finish setting up Native Note to change settings."
	static let width: CGFloat = 440
	static let lockedHeight: CGFloat = 240
}

struct SecuritySettings: View {
	enum Sheet: Identifiable {
		case turnOnTouchID
		case changePassword
		case setUpSync
		case changeRecoveryPhrase
		case changeServer

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
		Form {
			Section("Unlock") {
				LabeledContent {
					Button("Change Password…") { sheet = .changePassword }
				} label: {
					Text("Password")
					Text("The app is encrypted with this password. It cannot be recovered.")
				}
				if touchIDAvailable {
					Toggle(isOn: Binding(get: { touchIDEnabled }, set: { on in if on { sheet = .turnOnTouchID } else { turnOffTouchID() } })) {
						Text("Touch ID")
						Text("Unlock the app with your fingerprint.")
					}
				}
			}
			SyncSection(controls: sync) { sheet = $0 }
		}
		.formStyle(.grouped)
		.sheet(item: $sheet) { content(for: $0) { sheet = nil } }
	}

	@ViewBuilder
	func content(for sheet: Sheet, done: @escaping () -> Void) -> some View {
		switch sheet {
		case .turnOnTouchID:
			TurnOnTouchIDView(turnOn: turnOnTouchID, done: done, touchID: touchID)
		case .changePassword:
			ChangePasswordView(
				turnsTouchIDOff: touchIDEnabled,
				change: changePassword,
				offerTouchID: touchIDAvailable ? turnOnTouchID : nil,
				touchID: touchID,
				done: done
			)
		case .setUpSync:
			SyncSetupView(mode: .setUp, controls: sync, done: done)
		case .changeServer:
			SyncSetupView(form: SyncSetupForm(mode: .changeServer, server: sync.status.server ?? ""), controls: sync, done: done)
		case .changeRecoveryPhrase:
			SyncSetupView(mode: .rotate, controls: sync, done: done)
		}
	}
}

struct SyncSection: View {
	let controls: SyncControls
	let present: (SecuritySettings.Sheet) -> Void

	@State private var confirmingTurnOff = false
	@State private var lastFailure: String?

	var body: some View {
		Section("Sync") {
			if let server = controls.status.server {
				LabeledContent {
					Button("Change Server…") { present(.changeServer) }
				} label: {
					Text("Server")
					Text(server)
				}
				TimelineView(.everyMinute) { timeline in
					LabeledContent {
						Button("Sync Now") { Task { await controls.syncNow() } }
							.disabled(controls.status.phase == .syncing)
					} label: {
						HStack(spacing: 6) {
							if controls.status.phase == .syncing {
								ProgressView().controlSize(.small)
							}
							Text(Self.statusLine(controls.status, now: timeline.date))
						}
						if case let .failed(reason) = controls.status.phase {
							Text(reason)
						} else if controls.status.phase == .syncing, let lastFailure {
							Text(lastFailure)
								.hidden()
								.accessibilityHidden(true)
						}
						ForEach(controls.status.problems, id: \.self) { Text($0) }
					}
				}
				.onChange(of: controls.status.phase, initial: true) { _, phase in
					switch phase {
					case let .failed(reason): lastFailure = reason
					case .off, .idle: lastFailure = nil
					case .syncing: break
					}
				}
				LabeledContent {
					Button("Change Recovery Phrase…") { present(.changeRecoveryPhrase) }
				} label: {
					Text("Recovery phrase")
					Text("Restores your notes on another Mac. Native Note never keeps it.")
				}
				LabeledContent {
					Button("Turn Off Sync…") { confirmingTurnOff = true }
				} label: {
					Text("Turn off sync")
					Text("This Mac keeps its notes. Set Up Sync… finds this library again later.")
				}
				.confirmationDialog("Turn Off Sync?", isPresented: $confirmingTurnOff) {
					Button("Turn Off Sync") { Task { _ = await controls.turnOffSync() } }
				} message: {
					Text("This Mac keeps its notes and stops syncing them. The server keeps its copy.")
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

	static func statusLine(_ status: AppModel.SyncStatus, now: Date = .now) -> String {
		switch status.phase {
		case .syncing: return "Syncing…"
		case .failed: return "Sync failed"
		case .off, .idle:
			guard let synced = status.lastSynced else { return "Not synced yet" }
			guard now.timeIntervalSince(synced) >= 60 else { return "Last synced just now" }
			return "Last synced \(synced.formatted(.relative(presentation: .named, unitsStyle: .wide)))"
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
