import Foundation
import Virtualization

final class Machine: NSObject, VZVirtualMachineDelegate {
	let virtualMachine: VZVirtualMachine
	private(set) var stopReason: String?

	init(_ configuration: VZVirtualMachineConfiguration) {
		virtualMachine = VZVirtualMachine(configuration: configuration)
		super.init()
		virtualMachine.delegate = self
	}

	static func running<T>(_ configuration: VZVirtualMachineConfiguration, _ body: (Machine) async throws -> T) async throws -> T {
		try configuration.validate()
		let machine = Machine(configuration)
		try await machine.virtualMachine.start()
		do {
			let result = try await body(machine)
			await machine.powerOff()
			return result
		} catch {
			await machine.powerOff()
			throw error
		}
	}

	var hasStopped: Bool {
		stopReason != nil || virtualMachine.state == .stopped || virtualMachine.state == .error
	}

	func powerOff() async {
		guard !hasStopped, virtualMachine.canStop else { return }
		do {
			try await virtualMachine.stop()
			stopReason = stopReason ?? "powered off"
		} catch {
			say("vm: power off failed: \(error)")
		}
	}

	func waitUntilStopped(within timeout: Duration) async -> Bool {
		let deadline = ContinuousClock.now + timeout
		while !hasStopped, ContinuousClock.now < deadline {
			try? await Task.sleep(for: .milliseconds(250))
		}
		return hasStopped
	}

	func connect(toPort port: UInt32) async throws -> VZVirtioSocketConnection {
		guard let device = virtualMachine.socketDevices.first as? VZVirtioSocketDevice else { throw HarnessError("the VM has no socket device") }
		return try await device.connect(toPort: port)
	}

	func guestDidStop(_ virtualMachine: VZVirtualMachine) {
		stopReason = "the guest shut down"
	}

	func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: any Error) {
		stopReason = "the VM stopped with \(error)"
		say("vm: \(stopReason ?? "")")
	}
}
