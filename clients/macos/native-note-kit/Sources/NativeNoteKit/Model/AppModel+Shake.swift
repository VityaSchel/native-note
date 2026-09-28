extension AppModel {
	public struct Shake: Equatable {
		public static let duration = Duration.milliseconds(400)

		public var count: Int
		public var isRunning: Bool

		public init(count: Int = 0, isRunning: Bool = false) {
			self.count = count
			self.isRunning = isRunning
		}
	}
}
