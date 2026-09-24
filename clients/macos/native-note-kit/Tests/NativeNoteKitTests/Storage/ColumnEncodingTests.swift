import Foundation
import Testing

@testable import NativeNoteKit

struct ColumnEncodingTests {
	@Test func uuidsRoundTripThroughSixteenBytes() {
		let id = UUID()

		#expect(id.bytes.count == 16)
		#expect(UUID(bytes: id.bytes) == id)
	}

	@Test func uuidBytesRejectWrongLengths() {
		#expect(UUID(bytes: Data(count: 15)) == nil)
		#expect(UUID(bytes: Data(count: 17)) == nil)
	}

	@Test func datesRoundTripThroughWholeMilliseconds() {
		let moment = Date(epochMilliseconds: 1_760_000_000_123)

		#expect(moment.epochMilliseconds == 1_760_000_000_123)
		#expect(Date(timeIntervalSince1970: 1.0004).epochMilliseconds == 1_000)
	}
}
