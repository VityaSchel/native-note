import AppKit
import Foundation
import PowerLossKit

let usage = """
	usage: power-loss install
	       power-loss setup
	       power-loss run --count N [--seed S] [--tear on|off] [--control early-ack] [--transport vsock|ssh] [--nbd unix|tcp] [--library virtio|usb]
	       power-loss diagnose [--library virtio|usb|image] [--source <library image>] [--transport vsock|ssh] [--nbd unix|tcp]
	       power-loss check-configuration <scratch directory>
	"""

func finish(_ status: Int32, _ message: String? = nil) -> Never {
	if let message {
		FileHandle.standardError.write(Data("power-loss: \(message)\n".utf8))
	}
	exit(status)
}

signal(SIGPIPE, SIG_IGN)
let arguments = Array(CommandLine.arguments.dropFirst())
let command = arguments.first ?? ""
guard ["install", "setup", "run", "diagnose", "check-configuration"].contains(command) else { finish(2, usage) }

Task {
	do {
		switch command {
		case "install":
			try await Install.run(.standard)
		case "setup":
			try await Setup.run(.standard)
		case "run":
			let options = try RunOptions(arguments.dropFirst(), defaultSeed: UInt64.random(in: 0 ..< 1 << 53))
			finish(try await PowerLossRun(layout: .standard, options: options).run() ? 0 : 1)
		case "diagnose":
			try await Diagnose(layout: .standard, options: try DiagnoseOptions(arguments.dropFirst())).run()
		default:
			guard arguments.count == 2 else { finish(2, usage) }
			try await ConfigurationCheck.run(in: URL(fileURLWithPath: arguments[1]))
		}
		finish(0)
	} catch let error as OptionError {
		finish(2, "\(error)\n\(usage)")
	} catch {
		finish(1, "\(error)")
	}
}

if command == "setup" {
	NSApplication.shared.run()
} else {
	dispatchMain()
}
