import Foundation
import PowerLossKit
import Virtualization

enum MachineConfiguration {
	enum Role {
		case install
		case setup(library: URL)
		case run(library: URL)
	}

	static let cpuCount = 4
	static let memorySize: UInt64 = 4 << 30
	static let stableMACAddress = "02:6e:6e:70:6c:01"
	static let kitTag = "power-loss-kit"
	static let setupShareName = "kit"
	static let nbdTimeout: TimeInterval = 10

	static func make(_ layout: Layout, role: Role) throws -> VZVirtualMachineConfiguration {
		let configuration = VZVirtualMachineConfiguration()
		configuration.platform = try platform(layout)
		configuration.bootLoader = VZMacOSBootLoader()
		configuration.cpuCount = cpuCount
		configuration.memorySize = memorySize
		configuration.graphicsDevices = [graphics()]
		configuration.keyboards = [VZMacKeyboardConfiguration()]
		configuration.pointingDevices = [VZMacTrackpadConfiguration(), VZUSBScreenCoordinatePointingDeviceConfiguration()]
		configuration.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
		configuration.networkDevices = [try network()]
		configuration.socketDevices = [VZVirtioSocketDeviceConfiguration()]
		let bootDisk = try VZDiskImageStorageDeviceAttachment(url: layout.bootDisk, readOnly: false, cachingMode: .automatic, synchronizationMode: .full)
		configuration.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: bootDisk)]
		switch role {
		case .install:
			break
		case .setup(let library):
			configuration.storageDevices.append(try networkBlockDevice(library))
			configuration.directorySharingDevices = [agentShare(layout.kit), setupShare(layout.kit)]
		case .run(let library):
			configuration.storageDevices.append(try networkBlockDevice(library))
			configuration.directorySharingDevices = [agentShare(layout.kit)]
		}
		return configuration
	}

	private static func platform(_ layout: Layout) throws -> VZMacPlatformConfiguration {
		guard let model = VZMacHardwareModel(dataRepresentation: try Data(contentsOf: layout.hardwareModel)), model.isSupported else {
			throw HarnessError("this Mac cannot run the VM's hardware model")
		}
		guard let identifier = VZMacMachineIdentifier(dataRepresentation: try Data(contentsOf: layout.machineIdentifier)) else {
			throw HarnessError("unreadable machine identifier at \(layout.machineIdentifier.path)")
		}
		let platform = VZMacPlatformConfiguration()
		platform.hardwareModel = model
		platform.machineIdentifier = identifier
		platform.auxiliaryStorage = VZMacAuxiliaryStorage(url: layout.auxiliaryStorage)
		return platform
	}

	private static func graphics() -> VZMacGraphicsDeviceConfiguration {
		let graphics = VZMacGraphicsDeviceConfiguration()
		graphics.displays = [VZMacGraphicsDisplayConfiguration(widthInPixels: 2560, heightInPixels: 1600, pixelsPerInch: 220)]
		return graphics
	}

	private static func network() throws -> VZVirtioNetworkDeviceConfiguration {
		guard let address = VZMACAddress(string: stableMACAddress) else { throw HarnessError("invalid MAC address \(stableMACAddress)") }
		let network = VZVirtioNetworkDeviceConfiguration()
		network.attachment = VZNATNetworkDeviceAttachment()
		network.macAddress = address
		return network
	}

	private static func networkBlockDevice(_ url: URL) throws -> VZVirtioBlockDeviceConfiguration {
		let attachment = try VZNetworkBlockDeviceStorageDeviceAttachment(url: url, timeout: nbdTimeout, isForcedReadOnly: false, synchronizationMode: .full)
		return VZVirtioBlockDeviceConfiguration(attachment: attachment)
	}

	private static func agentShare(_ kit: URL) -> VZVirtioFileSystemDeviceConfiguration {
		let device = VZVirtioFileSystemDeviceConfiguration(tag: kitTag)
		device.share = VZSingleDirectoryShare(directory: VZSharedDirectory(url: kit, readOnly: true))
		return device
	}

	private static func setupShare(_ kit: URL) -> VZVirtioFileSystemDeviceConfiguration {
		let device = VZVirtioFileSystemDeviceConfiguration(tag: VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag)
		device.share = VZMultipleDirectoryShare(directories: [setupShareName: VZSharedDirectory(url: kit, readOnly: false)])
		return device
	}
}
