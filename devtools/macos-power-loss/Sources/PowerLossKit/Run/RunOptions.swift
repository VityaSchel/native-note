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
			default:
				throw OptionError("unknown option \(flag)")
			}
		}
		guard let count else { throw OptionError("--count is required") }
		self.count = count
	}
}
