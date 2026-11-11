import AppKit

/// The user guides in the repository, which Help and onboarding link to.
enum Guide {
	static let gettingStarted = page("getting-started.md")
	static let syncServer = page("setup-sync-server.md")

	/// Swapped by tests, which must not open a browser.
	@MainActor static var open: (URL) -> Void = { NSWorkspace.shared.open($0) }

	private static func page(_ name: String) -> URL {
		URL(string: "https://git.hloth.dev/hloth/native-note/src/branch/main/docs/guides")!.appending(path: name)
	}
}
