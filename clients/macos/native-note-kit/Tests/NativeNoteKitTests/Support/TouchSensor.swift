import AppKit
import LocalAuthentication
import LocalAuthenticationEmbeddedUI

@testable import NativeNoteKit

@MainActor
final class PairedGlyph {
	let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 128, height: 128), styleMask: [.borderless], backing: .buffered, defer: true)
	let view: LAAuthenticationView

	init(_ context: LAContext, inWindow: Bool = true) {
		view = LAAuthenticationView(context: context, controlSize: .large)
		if inWindow { window.contentView = view }
	}

	convenience init?(listeningFor model: AppModel) {
		guard case let .listening(context) = model.touchID else { return nil }
		self.init(context)
	}
}

@MainActor
@discardableResult
func touch(_ model: AppModel) async -> Bool {
	guard let glyph = PairedGlyph(listeningFor: model) else { return false }
	await model.listen(through: glyph.view)
	return true
}

@MainActor
final class Flag {
	private(set) var isRaised = false

	func raise() {
		isRaised = true
	}
}

@MainActor
func enableTouchID(_ model: AppModel, password: String = workspacePassword) async -> AppModel.Failure? {
	model.appBecameActive()
	let finished = Flag()
	let enabling = Task {
		defer { finished.raise() }
		return await model.enableBiometricUnlock(password: password)
	}
	while !finished.isRaised {
		if model.phase == .unlocked, await touch(model) { break }
		try? await Task.sleep(for: .milliseconds(1))
	}
	model.cancelTurningOnTouchID()
	return await enabling.value
}

extension AppModel.TouchID {
	var listeningContext: LAContext? {
		guard case let .listening(context) = self else { return nil }
		return context
	}
}

func isInvalidated(_ context: LAContext) -> Bool {
	var error: NSError?
	_ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
	return error?.code == LAError.Code.invalidContext.rawValue
}
