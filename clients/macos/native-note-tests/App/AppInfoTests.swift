import Foundation
import Testing

/// The built app's declarations per docs/EXPORT_COMPLIANCE.md.
struct AppInfoTests {
	@Test func theAppDeclaresItsEncryptionAndAllowsPlainHTTPForASelfHostedServer() throws {
		let info = try #require(Bundle.main.infoDictionary)

		#expect(info["ITSAppUsesNonExemptEncryption"] as? Bool == true)
		let transport = try #require(info["NSAppTransportSecurity"] as? [String: Any])
		#expect(transport["NSAllowsArbitraryLoads"] as? Bool == true)
		#expect(Set(transport.keys) == ["NSAllowsArbitraryLoads"])
	}
}
