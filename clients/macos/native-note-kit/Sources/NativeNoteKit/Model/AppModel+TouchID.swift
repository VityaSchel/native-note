import LocalAuthentication

extension AppModel {
	public enum TouchID: Equatable {
		public enum Pause: Equatable {
			case inBackground
			case checkingPassword
			case shaking
		}

		public enum Stop: Equatable {
			case miss
			case cancel
			case failure
		}

		case hidden
		case listening(LAContext)
		case paused(Pause)
		case needsClick(after: Stop)
		case lockedOut
		case working
	}
}
