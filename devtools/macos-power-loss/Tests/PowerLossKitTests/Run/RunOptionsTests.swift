import Foundation
import Testing

@testable import PowerLossKit

struct RunOptionsTests {
	@Test func onlyTheCountIsRequired() throws {
		let options = try RunOptions(["--count", "3"], defaultSeed: 77)

		#expect(options.count == 3)
		#expect(options.seed == 77)
		#expect(options.tearing)
		#expect(options.control == nil)
		#expect(options.transport == nil)
		#expect(options.nbd == .unix)
		#expect(options.library == .virtio)
	}

	@Test func everyOptionIsRead() throws {
		let options = try RunOptions(["--nbd", "tcp", "--tear", "off", "--seed", "18446744073709551615", "--transport", "ssh", "--count", "40", "--library", "usb", "--control", "early-ack"], defaultSeed: 0)

		#expect(options.count == 40)
		#expect(options.seed == .max)
		#expect(!options.tearing)
		#expect(options.control == .earlyAck)
		#expect(options.transport == .ssh)
		#expect(options.nbd == .tcp)
		#expect(options.library == .usb)
	}

	@Test(arguments: [
		([], "--count is required"),
		(["--count"], "--count needs a value"),
		(["--count", "0"], "--count must be a positive number"),
		(["--count", "2", "--seed", "-1"], "--seed must be a number from 0 to 18446744073709551615"),
		(["--count", "2", "--tear", "yes"], "--tear must be on or off"),
		(["--count", "2", "--control", "late-ack"], "--control must be early-ack"),
		(["--count", "2", "--mode", "drop"], "unknown option --mode"),
		(["--count", "2", "--transport", "serial"], "--transport must be vsock or ssh"),
		(["--count", "2", "--nbd", "udp"], "--nbd must be unix or tcp"),
		(["--count", "2", "--library", "nvme"], "--library must be virtio, usb or image"),
		(["--count", "2", "--verbose", "yes"], "unknown option --verbose"),
	])
	func badOptionsAreExplained(_ arguments: [String], _ message: String) {
		#expect(throws: OptionError(message)) { try RunOptions(arguments, defaultSeed: 0) }
	}
}

struct DiagnoseOptionsTests {
	@Test func noOptionIsRequired() throws {
		let options = try DiagnoseOptions([])

		#expect(options.transport == nil)
		#expect(options.nbd == .unix)
		#expect(options.library == .virtio)
		#expect(options.source == nil)
	}

	@Test func everyOptionIsRead() throws {
		let options = try DiagnoseOptions(["--library", "usb", "--nbd", "tcp", "--transport", "ssh", "--source", "images/plain.img"], currentDirectory: URL(filePath: "/tmp/work/", directoryHint: .isDirectory))

		#expect(options.transport == .ssh)
		#expect(options.nbd == .tcp)
		#expect(options.library == .usb)
		#expect(options.source?.path == "/tmp/work/images/plain.img")
	}

	@Test(arguments: [
		(["--library"], "--library needs a value"),
		(["--library", "nvme"], "--library must be virtio, usb or image"),
		(["--transport", "serial"], "--transport must be vsock or ssh"),
		(["--nbd", "udp"], "--nbd must be unix or tcp"),
		(["--source"], "--source needs a value"),
		(["--count", "2"], "unknown option --count"),
	])
	func badOptionsAreExplained(_ arguments: [String], _ message: String) {
		#expect(throws: OptionError(message)) { try DiagnoseOptions(arguments) }
	}
}
