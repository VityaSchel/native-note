import AppKit
import Foundation
import PowerLossKit
import Virtualization

enum Setup {
	static let steps = """
		In the VM window:
		1. On a fresh install, finish Setup Assistant with a local account, skip the Apple Account and leave FileVault off. Otherwise log in.
		2. Open Terminal and run this. Every setup start needs a new run, even if it ran before:
		   sudo sh "/Volumes/My Shared Files/\(MachineConfiguration.setupShareName)/setup.sh"
		3. Enter your password. If macOS asks whether Terminal may access files on a network volume, allow it.
		When the script is done, the harness checks the guest agent and shuts the VM down.
		"""

	static let agentTimeout = Duration.seconds(90)

	static func run(_ layout: Layout) async throws {
		try layout.requireInstalled()
		try GuestKit.stage(layout)
		if layout.exists(layout.setupFinished) {
			try FileManager.default.removeItem(at: layout.setupFinished)
		}
		try DiskBudget.check(layout.home)
		let (server, nbd) = try layout.serveLibrary()
		defer { server.stop() }
		let machine = try Machine(try MachineConfiguration.make(layout, role: .setup(library: nbd)))
		let window = SetupWindow(machine: machine)
		defer { window.close() }
		try await machine.virtualMachine.start()
		window.show()
		say(steps)
		while !machine.hasStopped, !layout.exists(layout.setupFinished) {
			try? await Task.sleep(for: .seconds(1))
		}
		guard layout.exists(layout.setupFinished) else {
			throw HarnessError("the VM stopped before the setup script finished; run power-loss setup again")
		}

		say("setup: the script is done, checking the guest agent")
		do {
			try await machine.waitForAgent(within: agentTimeout)
		} catch {
			say("setup: \(error). Its log in the VM is \(AgentLog.path). Close the VM window when you are done looking.")
			while !machine.hasStopped {
				try? await Task.sleep(for: .seconds(1))
			}
			throw HarnessError("the guest agent did not answer; run power-loss setup again once it does")
		}
		say("setup: the agent answers, shutting the VM down")
		await machine.shutDownGuest()
		server.stop()
		try BackingFile.restore(layout.formattedLibrary, from: layout.library)
		say("setup: done. Next: power-loss run --count 20")
	}
}

private final class SetupWindow: NSObject, NSWindowDelegate {
	private let window: NSWindow
	private let machine: Machine

	init(machine: Machine) {
		self.machine = machine
		let view = VZVirtualMachineView()
		view.virtualMachine = machine.virtualMachine
		view.capturesSystemKeys = true
		view.automaticallyReconfiguresDisplay = true
		window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
		window.title = "Native Note power-loss test VM (development only)"
		window.contentView = view
		window.isReleasedWhenClosed = false
		super.init()
		window.delegate = self
	}

	func show() {
		NSApplication.shared.setActivationPolicy(.regular)
		window.center()
		window.makeKeyAndOrderFront(nil)
		NSApplication.shared.activate()
	}

	func close() {
		window.delegate = nil
		window.close()
	}

	func windowWillClose(_ notification: Notification) {
		Task { await machine.powerOff() }
	}
}
