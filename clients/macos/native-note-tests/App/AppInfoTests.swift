import AppKit
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

	@Test func theAboutPanelCreditsSQLCipherSQLiteAndArgon2() throws {
		let url = try #require(Bundle.main.url(forResource: "Credits", withExtension: "rtf"))
		let credits = try NSAttributedString(url: url, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil).string

		for library in ["SQLCipher", "SQLite", "Argon2"] {
			#expect(credits.contains(library), "\(library)")
		}
	}
}
