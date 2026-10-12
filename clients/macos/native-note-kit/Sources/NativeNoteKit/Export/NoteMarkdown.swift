import Foundation

nonisolated enum NoteMarkdown {
	enum Failure: Error, Equatable {
		case noFrontMatter
		case missingField(String)
		case invalidField(String)
		case duplicateField(String)
		case unknownField(String)
		case misplacedField(String)
	}

	private enum Field: String, CaseIterable {
		case id, created, updated, v
	}

	private static let delimiter = "---"
	private static let untitled = "Untitled"
	private static let fileExtension = ".md"
	private static let fileNameByteLimit = 254
	private static let nameByteLimit = fileNameByteLimit - " 99".utf8.count - fileExtension.utf8.count
	private static let separators: Set<Unicode.Scalar> = ["/", "\\", ":", "|"]
	private static let removed: Set<Unicode.Scalar> = ["*", "?", "\"", "<", ">"]
	private static let trimmable = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "."))
	private static let reservedOnWindows = Set(
		["CON", "PRN", "AUX", "NUL"] + ["COM", "LPT"].flatMap { device in "0123456789¹²³".map { "\(device)\($0)" } }
	)

	static func render(_ note: Note) -> String {
		let fields = Field.allCases.map { "\($0.rawValue): \(value(of: $0, in: note))\n" }
		return "\(delimiter)\n\(fields.joined())\(delimiter)\n\(note.body)"
	}

	static func parse(_ text: String) throws -> Note {
		let (lines, body) = try frontMatter(of: text)
		let values = try fieldValues(in: lines)
		return try Note(
			id: decode(.id, from: values, { UUID(uuidString: $0) }, canonical: { $0.uuidString.lowercased() }),
			body: body,
			createdAt: moment(.created, from: values),
			updatedAt: moment(.updated, from: values),
			dirty: true,
			v: decode(.v, from: values, { UInt32($0) }, canonical: { String($0) })
		)
	}

	static func fileNames(for notes: [Note]) -> [String] {
		let names = notes.map { name(forTitle: $0.title) }
		let claimOrder = notes.indices.sorted {
			(notes[$0].createdAt, notes[$0].id.uuidString, $0) < (notes[$1].createdAt, notes[$1].id.uuidString, $1)
		}
		var claimed = Set<String>()
		var clashing: [Int] = []
		for index in claimOrder where !claimed.insert(collisionKey(names[index])).inserted {
			clashing.append(index)
		}
		var unique = names
		var nextNumber: [String: Int] = [:]
		for index in clashing {
			let key = collisionKey(names[index])
			var number = nextNumber[key, default: 2]
			var candidate = numbered(names[index], number)
			while !claimed.insert(collisionKey(candidate)).inserted {
				number += 1
				candidate = numbered(names[index], number)
			}
			nextNumber[key] = number + 1
			unique[index] = candidate
		}
		return unique.map { $0 + fileExtension }
	}

	private static func value(of field: Field, in note: Note) -> String {
		switch field {
		case .id: note.id.uuidString.lowercased()
		case .created: Timestamp.string(from: note.createdAt)
		case .updated: Timestamp.string(from: note.updatedAt)
		case .v: String(note.v)
		}
	}

	private static func frontMatter(of text: String) throws -> (lines: [String], body: String) {
		let bytes = text.utf8
		guard bytes.starts(with: "\(delimiter)\n".utf8) else { throw Failure.noFrontMatter }
		var lines: [String] = []
		var lineStart = bytes.index(bytes.startIndex, offsetBy: delimiter.utf8.count + 1)
		while let lineEnd = bytes[lineStart...].firstIndex(of: UInt8(ascii: "\n")) {
			let line = bytes[lineStart..<lineEnd]
			lineStart = bytes.index(after: lineEnd)
			if line.elementsEqual(delimiter.utf8) {
				return (lines, String(decoding: bytes[lineStart...], as: UTF8.self))
			}
			lines.append(String(decoding: line, as: UTF8.self))
		}
		throw Failure.noFrontMatter
	}

	private static func fieldValues(in lines: [String]) throws -> [Field: String] {
		var values: [Field: String] = [:]
		var expected = Field.allCases[...]
		for line in lines {
			let name = String(line.prefix { $0 != ":" })
			guard let field = Field(rawValue: name) else { throw Failure.unknownField(name) }
			guard values[field] == nil else { throw Failure.duplicateField(field.rawValue) }
			guard let position = expected.firstIndex(of: field) else { throw Failure.misplacedField(field.rawValue) }
			let prefix = "\(field.rawValue): ".utf8
			guard line.utf8.starts(with: prefix) else { throw Failure.invalidField(field.rawValue) }
			expected = expected[expected.index(after: position)...]
			values[field] = String(decoding: line.utf8.dropFirst(prefix.count), as: UTF8.self)
		}
		return values
	}

	private static func moment(_ field: Field, from values: [Field: String]) throws -> Int64 {
		try decode(field, from: values, Timestamp.milliseconds(from:), canonical: Timestamp.string(from:))
	}

	private static func decode<Value>(
		_ field: Field,
		from values: [Field: String],
		_ parse: (String) -> Value?,
		canonical render: (Value) -> String
	) throws -> Value {
		guard let text = values[field] else { throw Failure.missingField(field.rawValue) }
		guard let value = parse(text), render(value).utf8.elementsEqual(text.utf8) else { throw Failure.invalidField(field.rawValue) }
		return value
	}

	private static func name(forTitle title: String) -> String {
		var scalars = String.UnicodeScalarView()
		for scalar in title.unicodeScalars where !removed.contains(scalar) {
			if separators.contains(scalar) {
				scalars.append("-")
			} else if scalar.properties.generalCategory == .control {
				scalars.append(" ")
			} else {
				scalars.append(scalar)
			}
		}
		let name = fitted(String(scalars).precomposedStringWithCanonicalMapping.trimmingCharacters(in: trimmable), within: nameByteLimit)
		return isReservedOnWindows(name) ? fitted("_" + name, within: nameByteLimit) : name
	}

	private static func isReservedOnWindows(_ name: String) -> Bool {
		let stem = String(name.unicodeScalars.prefix { $0 != "." }).trimmingCharacters(in: .whitespaces)
		return reservedOnWindows.contains(stem.uppercased())
	}

	private static func numbered(_ name: String, _ number: Int) -> String {
		let suffix = " \(number)"
		return fitted(name, within: fileNameByteLimit - fileExtension.utf8.count - suffix.utf8.count) + suffix
	}

	private static func fitted(_ name: String, within byteLimit: Int) -> String {
		var bytes = 0
		let kept = name.prefix { character in
			bytes += character.utf8.count
			return bytes <= byteLimit
		}
		let trimmed = kept.trimmingCharacters(in: trimmable)
		return trimmed.isEmpty ? untitled : trimmed
	}

	private static func collisionKey(_ name: String) -> String {
		name.decomposedStringWithCanonicalMapping
			.folding(options: .caseInsensitive, locale: nil)
			.decomposedStringWithCanonicalMapping
	}

	private enum Timestamp {
		private static let millisecondsPerDay: Int64 = 86_400_000
		private static let daysPerEra: Int64 = 146_097
		private static let daysFromEraStartToEpoch: Int64 = 719_468
		private static let layoutAfterYear = "-MM-DDTHH:mm:ss.sssZ"
		private static let signedYearLengths = 7 ... 10

		static func string(from milliseconds: Int64) -> String {
			var (days, time) = milliseconds.quotientAndRemainder(dividingBy: millisecondsPerDay)
			if time < 0 {
				days -= 1
				time += millisecondsPerDay
			}
			let (year, month, day) = civilDate(fromDays: days)
			let yearText = (0...9999).contains(year) ? padded(year, 4) : (year < 0 ? "-" : "+") + padded(year.magnitude, 6)
			let clock = "\(padded(time / 3_600_000, 2)):\(padded(time / 60_000 % 60, 2)):\(padded(time / 1000 % 60, 2))"
			return "\(yearText)-\(padded(month, 2))-\(padded(day, 2))T\(clock).\(padded(time % 1000, 3))Z"
		}

		static func milliseconds(from text: String) -> Int64? {
			let bytes = Array(text.utf8)
			let yearEnd = bytes.count - layoutAfterYear.utf8.count
			let signed = signedYearLengths.contains(yearEnd)
			guard yearEnd == 4 || signed,
				let magnitude = decimal(bytes[(signed ? 1 : 0)..<yearEnd]),
				let month = decimal(bytes[yearEnd + 1..<yearEnd + 3]),
				let day = decimal(bytes[yearEnd + 4..<yearEnd + 6]),
				let hour = decimal(bytes[yearEnd + 7..<yearEnd + 9]),
				let minute = decimal(bytes[yearEnd + 10..<yearEnd + 12]),
				let second = decimal(bytes[yearEnd + 13..<yearEnd + 15]),
				let millisecond = decimal(bytes[yearEnd + 16..<yearEnd + 19])
			else { return nil }
			let year = bytes.first == UInt8(ascii: "-") ? -magnitude : magnitude
			let days = days(fromYear: year, month: month, day: day)
			let time = ((hour * 60 + minute) * 60 + second) * 1000 + millisecond
			return Int64(exactly: Int128(days) * Int128(millisecondsPerDay) + Int128(time))
		}

		private static func decimal(_ digits: ArraySlice<UInt8>) -> Int64? {
			var value: Int64 = 0
			for digit in digits {
				guard (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(digit) else { return nil }
				value = value * 10 + Int64(digit - UInt8(ascii: "0"))
			}
			return value
		}

		private static func padded(_ number: some BinaryInteger, _ width: Int) -> String {
			let digits = String(number)
			return String(repeating: "0", count: max(0, width - digits.count)) + digits
		}

		private static func days(fromYear year: Int64, month: Int64, day: Int64) -> Int64 {
			let marchYear = month <= 2 ? year - 1 : year
			let era = (marchYear >= 0 ? marchYear : marchYear - 399) / 400
			let yearOfEra = marchYear - era * 400
			let dayOfYear = (153 * (month > 2 ? month - 3 : month + 9) + 2) / 5 + day - 1
			let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
			return era * daysPerEra + dayOfEra - daysFromEraStartToEpoch
		}

		private static func civilDate(fromDays days: Int64) -> (year: Int64, month: Int64, day: Int64) {
			let shifted = days + daysFromEraStartToEpoch
			let era = (shifted >= 0 ? shifted : shifted - 146_096) / daysPerEra
			let dayOfEra = shifted - era * daysPerEra
			let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
			let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
			let marchMonth = (5 * dayOfYear + 2) / 153
			let month = marchMonth < 10 ? marchMonth + 3 : marchMonth - 9
			let day = dayOfYear - (153 * marchMonth + 2) / 5 + 1
			return (yearOfEra + era * 400 + (month <= 2 ? 1 : 0), month, day)
		}
	}
}
