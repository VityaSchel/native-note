import Foundation
import Testing

@testable import NativeNote

private final class BundleMarker {}

enum Hex {
	static func decode(_ string: String) -> Data? {
		guard string.count.isMultiple(of: 2) else { return nil }
		var bytes = Data(capacity: string.count / 2)
		var index = string.startIndex
		while index < string.endIndex {
			let next = string.index(index, offsetBy: 2)
			guard let byte = UInt8(string[index ..< next], radix: 16) else { return nil }
			bytes.append(byte)
			index = next
		}
		return bytes
	}
}

enum Vectors {
	struct Case {
		let name: String
		private let fields: [String: Any]

		init(name: String, fields: [String: Any]) {
			self.name = name
			self.fields = fields
		}

		func string(_ key: String) -> String? { fields[key] as? String }
		func int(_ key: String) -> Int? { fields[key] as? Int }
		func bytes(_ key: String) -> Data? { string(key).flatMap(Hex.decode) }

		func require(_ key: String) throws -> Data {
			try #require(bytes(key), "case \(name) is missing hex field \(key)")
		}
	}

	static var bundledVectorsDirectory: URL {
		get throws {
			let resources = try #require(Bundle(for: BundleMarker.self).resourceURL)
			return resources.appending(path: "vectors")
		}
	}

	static func load(_ file: String) throws -> [Case] {
		let url = try bundledVectorsDirectory.appending(path: file)
		let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
		let cases = try #require((object as? [String: Any])?["cases"] as? [[String: Any]], "\(file) has no cases")
		return cases.map { Case(name: $0["name"] as? String ?? "unnamed", fields: $0) }
	}
}
