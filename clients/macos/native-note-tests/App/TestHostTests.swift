import AppKit
import Testing

@MainActor
struct TestHostTests {
	@Test func theTestHostStaysOutOfTheDockAndInTheBackground() {
		#expect(NSApp.activationPolicy() == .prohibited)
		#expect(!NSApp.isActive)
	}
}
