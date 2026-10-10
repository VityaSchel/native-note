public struct VerifierReport: Codable, Equatable, Sendable {
	public let phase: String
	public let failure: String?
	public let integrity: String?
	public let notes: Int
	public let body: String?
	public let walCheckpoints: Int?

	public init(phase: String, failure: String? = nil, integrity: String? = nil, notes: Int, body: String? = nil, walCheckpoints: Int? = nil) {
		self.phase = phase
		self.failure = failure
		self.integrity = integrity
		self.notes = notes
		self.body = body
		self.walCheckpoints = walCheckpoints
	}
}
