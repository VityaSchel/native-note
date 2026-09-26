import CryptoKit
import Foundation

nonisolated enum ExportEnvelope {
	enum Failure: Error, Equatable {
		case notAnExport
		case parametersOutOfBounds
		case wrongPassphraseOrDamaged
	}

	static let magic = Data("NNEXPORT1".utf8)
	static let saltLength = 16
	static let maximumMemory: UInt32 = 2 * 1024 * 1024
	static let maximumPasses: UInt32 = 10
	static let maximumLanes: UInt32 = 16

	private static let parametersLength = 12
	private static let nonceLength = 12
	private static let tagLength = 16
	private static let headerLength = magic.count + parametersLength + saltLength
	private static let minimumLength = headerLength + nonceLength + tagLength

	static func isEncrypted(_ file: Data) -> Bool {
		file.starts(with: magic)
	}

	static func isWithinBounds(_ parameters: Argon2.Parameters) -> Bool {
		(1 ... maximumLanes).contains(parameters.p)
			&& (1 ... maximumPasses).contains(parameters.t)
			&& (8 * parameters.p ... maximumMemory).contains(parameters.m)
	}

	static func seal(
		_ zip: Data,
		passphrase: String,
		parameters: Argon2.Parameters = Argon2.floor,
		salt: Data = SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) },
		nonce: AES.GCM.Nonce = AES.GCM.Nonce()
	) throws -> Data {
		precondition(salt.count == saltLength)
		guard isWithinBounds(parameters) else { throw Failure.parametersOutOfBounds }
		let header = header(parameters: parameters, salt: salt)
		let key = try key(passphrase: passphrase, salt: salt, parameters: parameters)
		let sealed = try AES.GCM.seal(zip, using: key, nonce: nonce, authenticating: header)
		return header + Data(sealed.nonce) + sealed.ciphertext + sealed.tag
	}

	static func open(_ file: Data, passphrase: String) throws -> Data {
		guard file.count >= minimumLength, isEncrypted(file) else { throw Failure.notAnExport }
		let header = file.prefix(headerLength)
		let fields = header.dropFirst(magic.count)
		let parameters = Argon2.Parameters(m: word(fields, at: 0), t: word(fields, at: 4), p: word(fields, at: 8))
		guard isWithinBounds(parameters) else { throw Failure.parametersOutOfBounds }
		let key = try key(passphrase: passphrase, salt: Data(header.suffix(saltLength)), parameters: parameters)
		do {
			let sealed = try AES.GCM.SealedBox(combined: file.dropFirst(headerLength))
			return try AES.GCM.open(sealed, using: key, authenticating: header)
		} catch {
			throw Failure.wrongPassphraseOrDamaged
		}
	}

	static func header(parameters: Argon2.Parameters, salt: Data) -> Data {
		var header = magic
		for word in [parameters.m, parameters.t, parameters.p] {
			withUnsafeBytes(of: word.bigEndian) { header.append(contentsOf: $0) }
		}
		return header + salt
	}

	static func key(passphrase: String, salt: Data, parameters: Argon2.Parameters) throws -> SymmetricKey {
		try Argon2.hash(password: passphrase, salt: salt, parameters: parameters)
	}

	private static func word(_ bytes: Data, at offset: Int) -> UInt32 {
		bytes.dropFirst(offset).prefix(4).reduce(0) { $0 << 8 | UInt32($1) }
	}
}
