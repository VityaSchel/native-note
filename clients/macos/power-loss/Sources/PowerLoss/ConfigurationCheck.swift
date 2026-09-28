import Foundation
import PowerLossKit
import Virtualization

enum ConfigurationCheck {
	static func run(in directory: URL) async throws {
		let layout = Layout(home: directory)
		let image = try Layout.standard.restoreImage()
		let restoreImage = try await VZMacOSRestoreImage.image(from: image)
		guard let requirements = restoreImage.mostFeaturefulSupportedConfiguration else {
			throw HarnessError("macOS \(restoreImage.buildVersion) has no configuration this Mac supports")
		}
		try FileManager.default.createDirectory(at: layout.kit, withIntermediateDirectories: true)
		if !layout.exists(layout.hardwareModel) {
			try requirements.hardwareModel.dataRepresentation.write(to: layout.hardwareModel)
			try VZMacMachineIdentifier().dataRepresentation.write(to: layout.machineIdentifier)
			_ = try VZMacAuxiliaryStorage(creatingStorageAt: layout.auxiliaryStorage, hardwareModel: requirements.hardwareModel, options: [])
			try BackingFile.create(at: layout.bootDisk, size: 1 << 30)
			try BackingFile.create(at: layout.library, size: Layout.librarySize)
		}
		let unix = NBDServer.url(for: NBDTransport.unix.endpoint)
		let tcp = NBDServer.url(for: .loopback(port: 10809))
		let roles: [(String, MachineConfiguration.Role)] = [
			("install", .install),
			("setup with \(unix.absoluteString)", .setup(nbd: unix, kit: layout.kit)),
			("run with \(unix.absoluteString)", .run(library: .nbd(unix, .virtio), kit: layout.kit)),
			("run with \(tcp.absoluteString)", .run(library: .nbd(tcp, .virtio), kit: layout.kit)),
			("run with \(unix.absoluteString) on USB mass storage", .run(library: .nbd(unix, .usb), kit: layout.kit)),
			("run with \(layout.library.lastPathComponent) as a plain disk image", .run(library: .image(layout.library), kit: layout.kit)),
		]
		for (name, role) in roles {
			try MachineConfiguration.make(layout, role: role).validate()
			say("check-configuration: \(name) is valid")
		}
	}
}
