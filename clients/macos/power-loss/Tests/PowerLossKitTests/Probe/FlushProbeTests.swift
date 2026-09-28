import Foundation
import Testing

@testable import PowerLossKit

struct FlushProbeTests {
	@Test func everyCallIsBracketedByMarkersAndPacedAndTheFileIsRemoved() throws {
		let folder = try temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: folder) }
		var lines: [String] = []
		var paces: [Int] = []

		let status = FlushProbe.run(in: folder, emit: { lines.append($0) }, pace: { paces.append(lines.count) })

		let markers = lines.compactMap(ProbeMarker.init(line:))
		#expect(status == 0)
		#expect(lines.first?.hasPrefix("probe: file \(folder.path)/.power-loss-flush-probe-") == true)
		#expect(lines.first?.hasSuffix("(apfs)") == true)
		#expect(lines.last == "probe: done")
		#expect(markers.count == 12)
		#expect(paces == Array(2 ... 13))
		let calls = markers.compactMap { marker -> String? in
			if case .before(_, let call) = marker { call } else { nil }
		}
		#expect(calls == ["write 65536 bytes at 0", "fsync", "fcntl F_FULLFSYNC", "fcntl F_BARRIERFSYNC", "write 65536 bytes at 65536", "fcntl F_FULLFSYNC"])
		let results = markers.compactMap { marker -> (Int, Int32)? in
			if case .after(_, _, let result, let errno, _) = marker { (result, errno) } else { nil }
		}
		#expect(results.map(\.0) == [65_536, 0, 0, 0, 65_536, 0])
		#expect(results.allSatisfy { $0.1 == 0 })
		#expect(markers.map(\.step) == [1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6])
		#expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
	}

	@Test func aFolderItCannotWriteInFailsWithTheReason() {
		var lines: [String] = []

		let status = FlushProbe.run(in: URL(filePath: "/nonexistent-power-loss-folder"), emit: { lines.append($0) }, pace: {})

		#expect(status == 1)
		#expect(lines.count == 1)
		#expect(lines.first?.hasPrefix("probe: cannot create /nonexistent-power-loss-folder/.power-loss-flush-probe-") == true)
		#expect(lines.first?.hasSuffix("errno \(ENOENT)") == true)
	}
}

struct ProbeGoTests {
	@Test func emptyNudgesAreSkippedUntilTheGo() {
		var input = ["", "", "go", "next"]

		FlushProbe.awaitGo { input.isEmpty ? nil : input.removeFirst() }

		#expect(input == ["next"])
	}

	@Test func theEndOfInputStopsWaiting() {
		var reads = 0

		FlushProbe.awaitGo {
			reads += 1
			return reads < 3 ? "" : nil
		}

		#expect(reads == 3)
	}
}

struct ProbeMarkerTests {
	@Test(arguments: [
		ProbeMarker.before(step: 3, call: "fcntl F_FULLFSYNC"),
		.after(step: 3, call: "fcntl F_FULLFSYNC", result: -1, errno: 45, microseconds: 12),
		.after(step: 12, call: "write 65536 bytes at 0", result: 65_536, errno: 0, microseconds: 1_234_567),
	])
	func aMarkerSurvivesItsOwnLine(_ marker: ProbeMarker) {
		#expect(ProbeMarker(line: marker.line) == marker)
	}

	@Test(arguments: ["", "probe: done", "probe: step x before: fsync", "probe: step 1 after: fsync", " probe: step 1 before: fsync", "probe: file /Volumes/x"])
	func otherLinesAreNotMarkers(_ line: String) {
		#expect(ProbeMarker(line: line) == nil)
	}

	@Test func theLinesReadAsSentences() {
		#expect(ProbeMarker.before(step: 2, call: "fsync").line == "probe: step 2 before: fsync")
		#expect(ProbeMarker.after(step: 2, call: "fsync", result: 0, errno: 0, microseconds: 80).line == "probe: step 2 after: fsync -> result 0, errno 0, 80 us")
	}
}

struct ProbeTimelineTests {
	@Test func eachStepShowsWhatTheServerSawDuringItAndBetweenSteps() {
		var timeline = ProbeTimeline()

		timeline.mark(.before(step: 1, call: "fsync"), activity: DiskActivity(writes: 10))
		timeline.mark(.after(step: 1, call: "fsync", result: 0, errno: 0, microseconds: 900), activity: DiskActivity(writes: 13))
		timeline.mark(.before(step: 2, call: "fcntl F_FULLFSYNC"), activity: DiskActivity(reads: 1, writes: 13))
		timeline.mark(.after(step: 2, call: "fcntl F_FULLFSYNC", result: 0, errno: 0, microseconds: 4_000), activity: DiskActivity(reads: 1, writes: 15, flushes: 1))

		#expect(timeline.steps.map(\.effect) == [DiskActivity(writes: 3), DiskActivity(writes: 2, flushes: 1)])
		#expect(timeline.report == [
			"step 1 fsync: result 0, errno 0, 900 us; the server saw writes 3",
			"  between steps: reads 1",
			"step 2 fcntl F_FULLFSYNC: result 0, errno 0, 4000 us; the server saw writes 2, flushes 1",
		])
	}

	@Test func anUnfinishedStepAndAStrayMarkerAreReported() {
		var timeline = ProbeTimeline()

		timeline.mark(.after(step: 1, call: "fsync", result: 0, errno: 0, microseconds: 1), activity: DiskActivity())
		timeline.mark(.before(step: 2, call: "fcntl F_BARRIERFSYNC"), activity: DiskActivity())

		#expect(timeline.report == [
			"step 2 fcntl F_BARRIERFSYNC: never finished",
			"unmatched marker: probe: step 1 after: fsync -> result 0, errno 0, 1 us",
		])
	}
}
