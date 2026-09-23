import SwiftUI

extension View {
	func failureAlert(_ failure: AppModel.Failure?, dismiss: @escaping () -> Void) -> some View {
		modifier(FailureAlert(failure: failure, dismiss: dismiss))
	}
}

extension AppModel.Failure {
	var alert: (title: String, message: String)? {
		switch self {
		case let .unsaved(reason):
			("Your latest edits could not be saved.", "Native Note will keep trying to save them until you quit.\n\n\(reason)")
		case let .unexpected(message):
			("Native Note could not continue.", message)
		case .wrongPassword:
			nil
		}
	}
}

private struct FailureAlert: ViewModifier {
	let failure: AppModel.Failure?
	let dismiss: () -> Void

	func body(content: Content) -> some View {
		let alert = failure?.alert
		content.alert(
			alert?.title ?? "",
			isPresented: Binding(get: { alert != nil }, set: { if !$0 { dismiss() } })
		) {
			Button("OK", role: .cancel) {}
		} message: {
			Text(alert?.message ?? "")
		}
	}
}
