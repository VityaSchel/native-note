import CryptoKit
import Foundation

nonisolated extension Data {
	static func random(_ size: SymmetricKeySize) -> Data {
		SymmetricKey(size: size).withUnsafeBytes { Data($0) }
	}
}
