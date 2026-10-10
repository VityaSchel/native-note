import Foundation

public enum AgentTransport: String, Sendable {
	case vsock
	case ssh
}

public enum NBDTransport: String, Sendable {
	case unix
	case tcp
}

public enum LibraryDevice: String, Sendable {
	case virtio
	case usb
	case image
}

public struct OptionError: Error, Equatable, CustomStringConvertible {
	public let description: String

	init(_ description: String) {
		self.description = description
	}
}

public struct RunOptions: Equatable, Sendable {
	public var count: Int
	public var seed: UInt64
	public var tearing = true
	public var control: TypistControl?
	public var transport: AgentTransport?
	public var nbd = NBDTransport.unix
	public var library = LibraryDevice.virtio

	public init(_ arguments: some Sequence<String>, defaultSeed: UInt64) throws {
		var count: Int?
		seed = defaultSeed
		var remaining = arguments.makeIterator()
		while let flag = remaining.next() {
			guard let value = remaining.next() else { throw OptionError("\(flag) needs a value") }
			switch flag {
			case "--count":
				guard let number = Int(value), number > 0 else { throw OptionError("--count must be a positive number") }
				count = number
			case "--seed":
				guard let number = UInt64(value) else { throw OptionError("--seed must be a number from 0 to \(UInt64.max)") }
				seed = number
			case "--tear":
				guard let tearing = ["on": true, "off": false][value] else { throw OptionError("--tear must be on or off") }
				self.tearing = tearing
			case "--control":
				guard let control = TypistControl(rawValue: value) else {
					throw OptionError("--control must be \(TypistControl.allCases.map(\.rawValue).joined(separator: " or "))")
				}
				self.control = control
			case "--transport":
				transport = try AgentTransport(option: value)
			case "--nbd":
				nbd = try NBDTransport(option: value)
			case "--library":
				library = try LibraryDevice(option: value)
			default:
				throw OptionError("unknown option \(flag)")
			}
		}
		guard let count else { throw OptionError("--count is required") }
		self.count = count
	}
}

public struct DiagnoseOptions: Equatable, Sendable {
	public var transport: AgentTransport?
	public var nbd = NBDTransport.unix
	public var library = LibraryDevice.virtio
	public var source: URL?

	public init(_ arguments: some Sequence<String>, currentDirectory: URL = URL.currentDirectory()) throws {
		var remaining = arguments.makeIterator()
		while let flag = remaining.next() {
			guard let value = remaining.next() else { throw OptionError("\(flag) needs a value") }
			switch flag {
			case "--transport":
				transport = try AgentTransport(option: value)
			case "--nbd":
				nbd = try NBDTransport(option: value)
			case "--library":
				library = try LibraryDevice(option: value)
			case "--source":
				source = URL(filePath: value, relativeTo: currentDirectory).absoluteURL.standardized
			default:
				throw OptionError("unknown option \(flag)")
			}
		}
	}
}

extension AgentTransport {
	init(option value: String) throws {
		guard let transport = Self(rawValue: value) else { throw OptionError("--transport must be vsock or ssh") }
		self = transport
	}
}

extension NBDTransport {
	init(option value: String) throws {
		guard let transport = Self(rawValue: value) else { throw OptionError("--nbd must be unix or tcp") }
		self = transport
	}
}

extension LibraryDevice {
	init(option value: String) throws {
		guard let device = Self(rawValue: value) else { throw OptionError("--library must be virtio, usb or image") }
		self = device
	}
}
