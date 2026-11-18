import Foundation
import Testing

struct AppInfoTests {
	@Test func theAppLeavesItsEncryptionToAppStoreConnectAndAllowsPlainHTTPForASelfHostedServer() throws {
		let info = try #require(Bundle.main.infoDictionary)

		#expect(info["ITSAppUsesNonExemptEncryption"] == nil)
		#expect(info["ITSEncryptionExportComplianceCode"] == nil)
		let transport = try #require(info["NSAppTransportSecurity"] as? [String: Any])
		#expect(transport["NSAllowsArbitraryLoads"] as? Bool == true)
		#expect(Set(transport.keys) == ["NSAllowsArbitraryLoads"])
	}
}
