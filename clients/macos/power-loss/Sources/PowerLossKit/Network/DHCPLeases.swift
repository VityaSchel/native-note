import Foundation

public struct DHCPLease: Equatable, Sendable {
	public let ipAddress: String
	public let hardwareAddress: String
	public let lease: UInt64
}

public enum DHCPLeases {
	public static func parse(_ text: String) -> [DHCPLease] {
		var leases: [DHCPLease] = []
		var fields: [String: String] = [:]
		for rawLine in text.split(whereSeparator: \.isNewline) {
			let line = rawLine.trimmingCharacters(in: .whitespaces)
			if line == "{" {
				fields = [:]
			} else if line == "}" {
				if let ip = fields["ip_address"], let hardware = fields["hw_address"], let lease = fields["lease"].flatMap(hexadecimal) {
					leases.append(DHCPLease(ipAddress: ip, hardwareAddress: normalized(hardware), lease: lease))
				}
				fields = [:]
			} else if let separator = line.firstIndex(of: "=") {
				fields[String(line[..<separator])] = String(line[line.index(after: separator)...])
			}
		}
		return leases
	}

	public static func address(of hardwareAddress: String, in text: String) -> String? {
		let wanted = normalized(hardwareAddress)
		return parse(text).filter { $0.hardwareAddress == wanted }.max { $0.lease < $1.lease }?.ipAddress
	}

	static func normalized(_ hardwareAddress: String) -> String {
		let address = hardwareAddress.split(separator: ",", maxSplits: 1).last.map(String.init) ?? hardwareAddress
		return address.lowercased().split(separator: ":", omittingEmptySubsequences: false).map { octet in
			let trimmed = octet.drop { $0 == "0" }
			return trimmed.isEmpty ? "0" : String(trimmed)
		}.joined(separator: ":")
	}

	private static func hexadecimal(_ text: String) -> UInt64? {
		UInt64(text.hasPrefix("0x") ? String(text.dropFirst(2)) : text, radix: 16)
	}
}
