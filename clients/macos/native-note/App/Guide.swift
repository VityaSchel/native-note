import AppKit

enum Guide {
	static let gettingStarted = page("getting-started.md")
	static let syncServer = page("setup-sync-server.md")

	@MainActor static var open: (URL) -> Void = { NSWorkspace.shared.open($0) }

	private static func page(_ name: String) -> URL {
		URL(string: "https://git.hloth.dev/hloth/native-note/src/branch/main/docs/guides")!.appending(path: name)
	}
}
