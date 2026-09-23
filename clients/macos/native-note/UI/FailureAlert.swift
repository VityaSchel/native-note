import SwiftUI

extension View {
	func failureAlert(_ failure: AppModel.Failure?, dismiss: @escaping () -> Void) -> some View {
		modifier(FailureAlert(failure: failure, dismiss: dismiss))
	}
}

private struct FailureAlert: ViewModifier {
	let failure: AppModel.Failure?
	let dismiss: () -> Void

	private var presented: (title: String, message: String)? {
		switch failure {
		case let .unsaved(reason):
			("Your latest edits couldn't be saved", "\(reason)\n\nNative Note keeps trying while it's open.")
		case let .unexpected(message):
			("Native Note could not continue", message)
		case .wrongPassword, nil:
			nil
		}
	}

	func body(content: Content) -> some View {
		content.alert(
			presented?.title ?? "",
			isPresented: Binding(get: { presented != nil }, set: { if !$0 { dismiss() } })
		) {
			Button("OK", role: .cancel) {}
		} message: {
			Text(presented?.message ?? "")
		}
	}
}
