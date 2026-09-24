import Foundation
import Testing

@testable import NativeNoteKit

struct ZipArchiveTests {
	private static let moment = Date(timeIntervalSince1970: 1_760_000_000)

	private static let sample = [
		ZipEntry(name: "Groceries.md", data: Data("---\ncreated: 2025-10-09\n---\nmilk, eggs\n".utf8), modified: moment),
		ZipEntry(name: "Empty.md", data: Data(), modified: moment.addingTimeInterval(2)),
		ZipEntry(name: "Journal/Заметки ✓ 日本.md", data: Data("naïve café".utf8), modified: moment.addingTimeInterval(86_400)),
	]

	private static let note = ZipEntry(name: "note.md", data: Data("body text".utf8), modified: moment)
	private static let noteCentralDirectory = 30 + 7 + 9

	private static let unsafeNames = [
		"", "/etc/passwd", "..", "../escape.md", "notes/../../escape.md", "notes/..", "./note.md",
		"notes//note.md", "notes/", "notes\\note.md", "note\0.md", "notes/../\u{301}escape.md", "/\u{301}etc",
	]

	@Test func roundTripsNamesBytesAndModificationTimes() throws {
		#expect(try ZipArchive.read(ZipArchive.write(Self.sample)) == Self.sample)
	}

	@Test func roundTripsAnArchiveWithNoEntries() throws {
		let archive = try ZipArchive.write([])

		#expect(archive.count == 22)
		#expect(try ZipArchive.read(archive).isEmpty)
	}

	@Test func roundTripsThousandsOfEntries() throws {
		var generator = SplitMix64(seed: 1)
		let entries = (0 ..< 3_000).map { index in
			ZipEntry(
				name: "notes/\(index).md",
				data: randomBytes(count: Int.random(in: 0 ... 64, using: &generator), using: &generator),
				modified: Self.moment.addingTimeInterval(Double(2 * index))
			)
		}

		#expect(try ZipArchive.read(ZipArchive.write(entries)) == entries)
	}

	@Test func writesIdenticalBytesForIdenticalEntries() throws {
		#expect(try ZipArchive.write(Self.sample) == ZipArchive.write(Self.sample))
	}

	@Test func writesStoredUTF8EntriesWithUTCTimesAndNoExtraFields() throws {
		#expect(try ZipArchive.write([Self.note]) == handBuiltArchive(name: Data(Self.note.name.utf8), data: Self.note.data))
	}

	@Test func readsAnArchiveHeldInASliceOfLargerData() throws {
		let padded = try Data(repeating: 0xAA, count: 7) + ZipArchive.write(Self.sample)

		#expect(try ZipArchive.read(padded[7...]) == Self.sample)
	}

	@Test func readsPastAnArchiveComment() throws {
		let archive = try ZipArchive.write(Self.sample)
		let decoy = Data("exported PK\u{5}\u{6} by hand, a signature followed by more than a record's worth of text".utf8)
		for comment in [Data(), decoy, Data(repeating: 0x50, count: 0xFFFF)] {
			let commented = archive.patching(UInt16(comment.count), at: archive.count - 2) + comment

			#expect(try ZipArchive.read(commented) == Self.sample)
		}
	}

	@Test func readsPastEntryComments() throws {
		let archive = try ZipArchive.write(Self.sample)
		let central = Self.sample.reduce(0) { $0 + 30 + $1.name.utf8.count + $1.data.count }
		let firstRecordEnd = central + 46 + Self.sample[0].name.utf8.count
		let comment = Data("an entry comment".utf8)
		let end = archive.count - 22
		let commented = archive.patching(UInt16(comment.count), at: central + 32).prefix(firstRecordEnd) + comment
			+ archive[firstRecordEnd ..< end]
			+ archive.suffix(22).patching(UInt32(end - central + comment.count), at: 12)

		#expect(try ZipArchive.read(commented) == Self.sample)
	}

	@Test func roundsModificationTimesDownToEvenSeconds() throws {
		#expect(try modifiedAfterRoundTrip(Self.moment.addingTimeInterval(1.9)) == Self.moment)
		#expect(try modifiedAfterRoundTrip(Self.moment.addingTimeInterval(2.5)) == Self.moment.addingTimeInterval(2))
	}

	@Test func clampsModificationTimesToTheRangeMSDOSCanHold() throws {
		let earliest = try Date("1980-01-01T00:00:00Z", strategy: .iso8601)
		let latest = try Date("2107-12-31T23:59:58Z", strategy: .iso8601)

		#expect(try modifiedAfterRoundTrip(earliest) == earliest)
		#expect(try modifiedAfterRoundTrip(latest) == latest)
		#expect(try modifiedAfterRoundTrip(Date(timeIntervalSince1970: 0)) == earliest)
		#expect(try modifiedAfterRoundTrip(.distantPast) == earliest)
		#expect(try modifiedAfterRoundTrip(.distantFuture) == latest)
		#expect(try modifiedAfterRoundTrip(Date(timeIntervalSince1970: .nan)) == earliest)
	}

	@Test(arguments: [
		("", 0x0000_0000),
		("a", 0xE8B7_BE43),
		("123456789", 0xCBF4_3926),
		("The quick brown fox jumps over the lazy dog", 0x414F_A339),
	] as [(String, UInt32)])
	func computesTheIEEECRC32(text: String, checksum: UInt32) {
		#expect(ZipArchive.crc32(Data(text.utf8)) == checksum)
	}

	@Test func unzipFindsNoErrorsAndExtractsIdenticalBytes() throws {
		let directory = try scratchDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let archive = directory.appending(path: "export.zip")
		let extracted = directory.appending(path: "extracted")
		try ZipArchive.write(Self.sample).write(to: archive)

		let test = try run("/usr/bin/unzip", ["-t", archive.path])
		#expect(test.status == 0)
		#expect(test.output.contains("No errors detected in compressed data"))
		#expect(try run("/usr/bin/unzip", ["-q", archive.path, "-d", extracted.path]).status == 0)
		for entry in Self.sample {
			#expect(try Data(contentsOf: extracted.appending(path: entry.name)) == entry.data)
		}
		#expect(try regularFiles(in: extracted).count == Self.sample.count)
	}

	@Test func zipinfoListsEveryEntryAsStoredWithItsUTCTime() throws {
		let directory = try scratchDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let archive = directory.appending(path: "export.zip")
		try ZipArchive.write(Self.sample).write(to: archive)
		let total = Self.sample.reduce(0) { $0 + $1.data.count }

		let listing = try run("/usr/bin/zipinfo", ["-T", archive.path])
		#expect(listing.status == 0)
		#expect(listing.output.contains("number of entries: 3"))
		#expect(listing.output.contains("stor 20251009.085320 Groceries.md"))
		#expect(listing.output.contains("stor 20251009.085322 Empty.md"))
		#expect(listing.output.contains("stor 20251010.085320 Journal/"))
		#expect(listing.output.contains("3 files, \(total) bytes uncompressed, \(total) bytes compressed"))
	}

	@Test func readsStoredArchivesMadeByZip() throws {
		let directory = try scratchDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let files = [
			("a.md", Data("hello".utf8)),
			("empty.md", Data()),
			("sub/Заметки ✓.md", Data("x".utf8)),
			("sub/binary.bin", Data((0 ... 255).map(UInt8.init))),
		]
		for (name, data) in files {
			try makeDirectory(for: directory.appending(path: name))
			try data.write(to: directory.appending(path: name))
		}

		let zip = try run("/usr/bin/zip", ["-0", "-D", "-z", "archive.zip"] + files.map(\.0), in: directory, input: "made by Info-ZIP\n")
		let entries = try ZipArchive.read(Data(contentsOf: directory.appending(path: "archive.zip")))

		#expect(zip.status == 0)
		#expect(entries.map(\.name) == files.map(\.0))
		#expect(entries.map(\.data) == files.map(\.1))
	}

	@Test func rejectsDeflatedEntriesMadeByZip() throws {
		let directory = try scratchDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		try Data(String(repeating: "compressible ", count: 1_000).utf8).write(to: directory.appending(path: "long.md"))

		#expect(try run("/usr/bin/zip", ["-6", "archive.zip", "long.md"], in: directory).status == 0)
		#expect(throws: ZipArchive.Failure.unsupported(.compression(method: 8))) {
			try ZipArchive.read(Data(contentsOf: directory.appending(path: "archive.zip")))
		}
	}

	@Test(arguments: ZipArchiveTests.unsafeNames)
	func refusesToWriteUnsafeNames(name: String) {
		#expect(throws: ZipArchive.Failure.unsafeName) {
			try ZipArchive.write([ZipEntry(name: name, data: Data(), modified: Self.moment)])
		}
	}

	@Test(arguments: ZipArchiveTests.unsafeNames)
	func refusesToReadUnsafeNames(name: String) {
		#expect(throws: ZipArchive.Failure.unsafeName) {
			try ZipArchive.read(handBuiltArchive(name: Data(name.utf8)))
		}
	}

	@Test func refusesToReadNamesThatAreNotUTF8() {
		#expect(throws: ZipArchive.Failure.unsafeName) {
			try ZipArchive.read(handBuiltArchive(name: Data([0x6E, 0xFF, 0x2E, 0x6D, 0x64])))
		}
	}

	@Test func rejectsDataThatIsNotAZip() {
		var generator = SplitMix64(seed: 2)
		for data in [Data(), Data("hello".utf8), Data(repeating: 0, count: 100), randomBytes(count: 4_096, using: &generator)] {
			#expect(throws: ZipArchive.Failure.notAZip) { try ZipArchive.read(data) }
		}
	}

	@Test func rejectsATruncatedArchive() throws {
		let archive = try ZipArchive.write(Self.sample)
		for length in [4, 30, archive.count / 2, archive.count - 22, archive.count - 1] {
			#expect(throws: ZipArchive.Failure.damaged(.truncated)) { try ZipArchive.read(archive.prefix(length)) }
		}
	}

	@Test func rejectsAFlippedDataByte() throws {
		var archive = try ZipArchive.write([Self.note])
		archive[30 + 7 + 4] ^= 0x01

		#expect(throws: ZipArchive.Failure.damaged(.checksum)) { try ZipArchive.read(archive) }
	}

	@Test func rejectsACentralDirectoryOffsetOrSizePastTheEnd() throws {
		let archive = try ZipArchive.write([Self.note])
		let end = archive.count - 22

		for field in [end + 12, end + 16] {
			#expect(throws: ZipArchive.Failure.damaged(.outOfBounds)) {
				try ZipArchive.read(archive.patching(UInt32(0x7FFF_0000), at: field))
			}
		}
	}

	@Test func rejectsAnEntrySizeOrLocalOffsetPastTheEnd() throws {
		let archive = try ZipArchive.write([Self.note])
		let central = Self.noteCentralDirectory
		let huge = UInt32(0x7FFF_0000)
		let centralSizes = archive.patching(huge, at: central + 20).patching(huge, at: central + 24)
		let bothSizes = centralSizes.patching(huge, at: 18).patching(huge, at: 22)

		for damaged in [centralSizes, bothSizes, archive.patching(huge, at: central + 42)] {
			#expect(throws: ZipArchive.Failure.damaged(.outOfBounds)) { try ZipArchive.read(damaged) }
		}
	}

	@Test func rejectsEntryDataThatRunsIntoTheCentralDirectory() {
		let archive = handBuiltArchive(name: Data("a.md".utf8))
		let central = 38
		let reach = UInt32(4 + 16)
		let crc = ZipArchive.crc32(archive[34 ..< central + 16])
		let damaged = archive
			.patching(crc, at: 14).patching(reach, at: 18).patching(reach, at: 22)
			.patching(crc, at: central + 16).patching(reach, at: central + 20).patching(reach, at: central + 24)

		#expect(throws: ZipArchive.Failure.damaged(.outOfBounds)) { try ZipArchive.read(damaged) }
	}

	@Test func rejectsALocalHeaderThatDisagreesWithTheCentralDirectory() throws {
		let archive = try ZipArchive.write([Self.note])

		for damaged in [archive.patching(UInt16(0), at: 10), archive.patching(UInt32(0), at: 0), archive.patching(UInt8(0x4E), at: 30)] {
			#expect(throws: ZipArchive.Failure.damaged(.inconsistent)) { try ZipArchive.read(damaged) }
		}
	}

	@Test func rejectsAStoredEntryWhoseSizesDisagree() {
		let archive = handBuiltArchive(name: Data("a.md".utf8))

		#expect(throws: ZipArchive.Failure.damaged(.inconsistent)) {
			try ZipArchive.read(archive.patching(UInt32(5), at: 22).patching(UInt32(5), at: 38 + 24))
		}
	}

	@Test func rejectsACentralHeaderWithoutItsSignature() {
		#expect(throws: ZipArchive.Failure.damaged(.inconsistent)) {
			try ZipArchive.read(handBuiltArchive(name: Data("a.md".utf8)).patching(UInt8(0), at: 38))
		}
	}

	@Test func rejectsACentralDirectoryWithBytesPastItsEntries() {
		let archive = handBuiltArchive(name: Data("a.md".utf8))
		let end = archive.count - 22
		let padded = archive.prefix(end) + Data(count: 4) + archive.suffix(22).patching(UInt32(end - 38 + 4), at: 12)

		#expect(throws: ZipArchive.Failure.damaged(.inconsistent)) { try ZipArchive.read(padded) }
	}

	@Test func rejectsTwoEntriesSharingTheSameBytes() throws {
		let archive = try ZipArchive.write([Self.note])
		let central = Self.noteCentralDirectory
		let entry = archive[central ..< archive.count - 22]
		let end = archive.suffix(22)
			.patching(UInt16(2), at: 8)
			.patching(UInt16(2), at: 10)
			.patching(UInt32(2 * entry.count), at: 12)

		#expect(throws: ZipArchive.Failure.damaged(.overlapping)) {
			try ZipArchive.read(archive.prefix(central) + entry + entry + end)
		}
	}

	@Test func rejectsEncryptionDataDescriptorsCompressionAndUnknownFlags() {
		let name = Data("a.md".utf8)
		let cases: [(ZipArchive.Feature, Data)] = [
			(.encryption, handBuiltArchive(name: name, flags: 0x0801)),
			(.encryption, handBuiltArchive(name: name, flags: 0x0841, method: 99)),
			(.dataDescriptor, handBuiltArchive(name: name, flags: 0x0808)),
			(.unknownFlags(0x0020), handBuiltArchive(name: name, flags: 0x0820)),
			(.compression(method: 8), handBuiltArchive(name: name, method: 8)),
		]

		for (feature, archive) in cases {
			#expect(throws: ZipArchive.Failure.unsupported(feature)) { try ZipArchive.read(archive) }
		}
	}

	@Test(arguments: [0x0840, 0x2800] as [UInt16])
	func rejectsStrongAndCentralDirectoryEncryption(flags: UInt16) {
		#expect(throws: ZipArchive.Failure.unsupported(.encryption)) {
			try ZipArchive.read(handBuiltArchive(name: Data("a.md".utf8), flags: flags))
		}
	}

	@Test func rejectsZip64Archives() throws {
		let archive = try ZipArchive.write([Self.note])
		let end = archive.count - 22

		#expect(throws: ZipArchive.Failure.unsupported(.zip64)) {
			try ZipArchive.read(archive.patching(UInt16.max, at: end + 8).patching(UInt16.max, at: end + 10))
		}
		#expect(throws: ZipArchive.Failure.unsupported(.zip64)) {
			try ZipArchive.read(archive.patching(UInt32.max, at: Self.noteCentralDirectory + 42))
		}
		#expect(throws: ZipArchive.Failure.unsupported(.zip64)) {
			let locator = Data(littleEndian: UInt32(0x0706_4B50), UInt32(0), UInt64(0), UInt32(1))
			return try ZipArchive.read(archive.prefix(end) + locator + archive.suffix(22))
		}
		#expect(throws: ZipArchive.Failure.damaged(.inconsistent)) {
			try ZipArchive.read(archive.prefix(end) + Data(count: 20) + archive.suffix(22))
		}
	}

	@Test func rejectsEveryZip64Sentinel() {
		let archive = handBuiltArchive(name: Data("a.md".utf8))
		let end = archive.count - 22

		for field in [38 + 20, 38 + 24, end + 12, end + 16] {
			#expect(throws: ZipArchive.Failure.unsupported(.zip64)) { try ZipArchive.read(archive.patching(UInt32.max, at: field)) }
		}
	}

	@Test func rejectsEveryDiskFieldOfASpannedArchive() {
		let archive = handBuiltArchive(name: Data("a.md".utf8))
		let end = archive.count - 22
		let spanned = [
			archive.patching(UInt16(1), at: end + 4), archive.patching(UInt16(1), at: end + 6),
			archive.patching(UInt16(2), at: end + 8), archive.patching(UInt16(1), at: 38 + 34),
		]

		for damaged in spanned {
			#expect(throws: ZipArchive.Failure.unsupported(.multipleDisks)) { try ZipArchive.read(damaged) }
		}
	}

	@Test func refusesMoreEntriesThanAPlainZipCounts() throws {
		let empty = ZipEntry(name: "n", data: Data(), modified: Self.moment)

		#expect(try ZipArchive.read(ZipArchive.write(Array(repeating: empty, count: 65_534))).count == 65_534)
		#expect(throws: ZipArchive.Failure.tooLarge) { try ZipArchive.write(Array(repeating: empty, count: 65_535)) }
	}

	@Test func refusesSizesAndOffsetsThatNeedZip64() {
		for size in [0xFFFF_FFFF, 0xFFFF_FFFF - 31] {
			#expect(throws: ZipArchive.Failure.tooLarge) {
				try ZipArchive.write([ZipEntry(name: "a", data: Data(count: size), modified: Self.moment)])
			}
		}
	}

	@Test func keepsNamesUpToTheLengthFieldAndRefusesLonger() throws {
		let longest = ZipEntry(name: String(repeating: "n", count: 0xFFFF), data: Data(), modified: Self.moment)
		let tooLong = ZipEntry(name: String(repeating: "n", count: 0x1_0000), data: Data(), modified: Self.moment)

		#expect(try ZipArchive.read(ZipArchive.write([longest])) == [longest])
		#expect(throws: ZipArchive.Failure.tooLarge) { try ZipArchive.write([tooLong]) }
	}

	@Test func throwsOnlyZipFailuresForThousandsOfRandomMutations() throws {
		let original = try ZipArchive.write(Self.sample)
		var generator = SplitMix64(seed: 3)
		for _ in 0 ..< 5_000 {
			var mutated = original
			for _ in 0 ... Int.random(in: 0 ... 2, using: &generator) {
				mutate(&mutated, using: &generator)
			}
			expectOnlyZipFailures(reading: mutated)
		}
	}

	@Test func throwsOnlyZipFailuresWhenAnySingleByteChanges() throws {
		let original = try ZipArchive.write(Self.sample)
		for offset in original.indices {
			for value in [0x00, 0x01, 0x7F, 0x80, 0xFF, ~original[offset]] as [UInt8] {
				var mutated = original
				mutated[offset] = value
				expectOnlyZipFailures(reading: mutated)
			}
		}
	}
}

private extension ZipArchiveTests {
	struct SplitMix64: RandomNumberGenerator {
		var state: UInt64

		init(seed: UInt64) {
			state = seed
		}

		mutating func next() -> UInt64 {
			state &+= 0x9E37_79B9_7F4A_7C15
			var mixed = state
			mixed = (mixed ^ mixed >> 30) &* 0xBF58_476D_1CE4_E5B9
			mixed = (mixed ^ mixed >> 27) &* 0x94D0_49BB_1331_11EB
			return mixed ^ mixed >> 31
		}
	}

	struct ToolRun {
		let status: Int32
		let output: String
	}

	func run(_ tool: String, _ arguments: [String], in directory: URL? = nil, input: String? = nil) throws -> ToolRun {
		let process = Process()
		let output = Pipe()
		let stdin = Pipe()
		process.executableURL = URL(filePath: tool)
		process.arguments = arguments
		process.currentDirectoryURL = directory
		process.environment = ["LC_ALL": "en_US.UTF-8", "PATH": "/usr/bin:/bin", "TMPDIR": NSTemporaryDirectory()]
		process.standardOutput = output
		process.standardError = output
		process.standardInput = input == nil ? FileHandle.nullDevice : stdin
		try process.run()
		if let input {
			try stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8))
			try stdin.fileHandleForWriting.close()
		}
		let printed = try output.fileHandleForReading.readToEnd() ?? Data()
		process.waitUntilExit()
		return ToolRun(status: process.terminationStatus, output: String(decoding: printed, as: UTF8.self))
	}

	func scratchDirectory() throws -> URL {
		let directory = temporaryDirectory()
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		return directory
	}

	func regularFiles(in directory: URL) throws -> [URL] {
		try FileManager.default.subpathsOfDirectory(atPath: directory.path)
			.map { directory.appending(path: $0) }
			.filter { try $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true }
	}

	func modifiedAfterRoundTrip(_ modified: Date) throws -> Date? {
		try ZipArchive.read(ZipArchive.write([ZipEntry(name: "a.md", data: Data(), modified: modified)])).first?.modified
	}

	func expectOnlyZipFailures(reading archive: Data) {
		do {
			_ = try ZipArchive.read(archive)
		} catch is ZipArchive.Failure {
		} catch {
			Issue.record("unexpected error \(error)")
		}
	}

	func mutate(_ data: inout Data, using generator: inout SplitMix64) {
		guard !data.isEmpty else {
			data = randomBytes(count: 22, using: &generator)
			return
		}
		let offset = Int.random(in: 0 ..< data.count, using: &generator)
		let length = Int.random(in: 1 ... 16, using: &generator)
		switch Int.random(in: 0 ..< 6, using: &generator) {
		case 0:
			data[offset] ^= 1 << UInt8.random(in: 0 ..< 8, using: &generator)
		case 1:
			data[offset] = UInt8.random(in: 0 ... 255, using: &generator)
		case 2:
			let extreme = [0x00, 0x7F, 0x80, 0xFF][Int.random(in: 0 ..< 4, using: &generator)] as UInt8
			let span = offset ..< min(data.count, offset + 4)
			data.replaceSubrange(span, with: repeatElement(extreme, count: span.count))
		case 3:
			data = data.prefix(offset)
		case 4:
			data.removeSubrange(offset ..< min(data.count, offset + length))
		default:
			data.insert(contentsOf: randomBytes(count: length, using: &generator), at: offset)
		}
	}

	func randomBytes(count: Int, using generator: inout SplitMix64) -> Data {
		Data((0 ..< count).map { _ in UInt8.random(in: 0 ... 255, using: &generator) })
	}

	func handBuiltArchive(name: Data, data: Data = Data("body".utf8), flags: UInt16 = 0x0800, method: UInt16 = 0) -> Data {
		let time = UInt16(8 << 11 | 53 << 5 | 20 / 2)
		let date = UInt16((2025 - 1980) << 9 | 10 << 5 | 9)
		let size = UInt32(data.count)
		let unixRegularFile = UInt32(0o100644) << 16
		let fields = Data(littleEndian: UInt16(20), flags, method, time, date, ZipArchive.crc32(data), size, size, UInt16(name.count), UInt16(0))
		let local = Data(littleEndian: UInt32(0x0403_4B50)) + fields + name + data
		let central = Data(littleEndian: UInt32(0x0201_4B50), UInt16(0x0314)) + fields
			+ Data(littleEndian: UInt16(0), UInt16(0), UInt16(0), unixRegularFile, UInt32(0)) + name
		let end = Data(
			littleEndian: UInt32(0x0605_4B50), UInt16(0), UInt16(0), UInt16(1), UInt16(1),
			UInt32(central.count), UInt32(local.count), UInt16(0)
		)
		return local + central + end
	}
}

private extension Data {
	init(littleEndian values: any FixedWidthInteger...) {
		self = values.reduce(into: Data()) { data, value in data.append(Data(bytesOf: value)) }
	}

	init(bytesOf value: some FixedWidthInteger) {
		self = Swift.withUnsafeBytes(of: value.littleEndian) { Data($0) }
	}

	func patching(_ value: some FixedWidthInteger, at offset: Int) -> Data {
		var patched = Data(self)
		patched.replaceSubrange(offset ..< offset + MemoryLayout.size(ofValue: value), with: Data(bytesOf: value))
		return patched
	}
}
