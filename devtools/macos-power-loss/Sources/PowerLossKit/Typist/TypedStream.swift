import CryptoKit
import Foundation

public enum TypedStream {
	static let alphabet = Array("abcdefghijklmnopqrstuvwxyz")

	public static func text(length: Int) -> String {
		String((0 ..< length).map { alphabet[$0 % alphabet.count] })
	}

	public static func holds(_ text: String) -> Bool {
		text == self.text(length: text.count)
	}

	public static func digest(length: Int) -> String {
		SHA256.hash(data: Data(text(length: length).utf8)).map { String(format: "%02x", $0) }.joined()
	}
}
