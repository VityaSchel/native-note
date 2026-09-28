import Foundation
import PowerLossKit
import Virtualization

enum Install {
	private final class Outcome {
		var result: Result<Void, Error>?
	}

	static func run(_ layout: Layout) async throws {
		guard !layout.exists(layout.bundle) else {
			throw HarnessError("\(layout.bundle.path) already exists; move it away to install again")
		}
		let image = try layout.restoreImage()
		let free = try DiskBudget.freeBytes(at: layout.home)
		guard DiskBudget.allows(allocating: DiskBudget.installGrowth, free: free) else {
			throw HarnessError("installing takes up to \(DiskBudget.installGrowth >> 30) GiB, which would leave less than \(DiskBudget.reserve >> 30) GiB of the \(free >> 30) GiB free")
		}

		say("install: loading \(image.lastPathComponent)")
		let restoreImage = try await VZMacOSRestoreImage.image(from: image)
		guard let requirements = restoreImage.mostFeaturefulSupportedConfiguration, requirements.hardwareModel.isSupported else {
			throw HarnessError("this Mac cannot run macOS \(restoreImage.buildVersion) in a VM")
		}
		guard MachineConfiguration.cpuCount >= requirements.minimumSupportedCPUCount, MachineConfiguration.memorySize >= requirements.minimumSupportedMemorySize else {
			throw HarnessError("macOS \(restoreImage.buildVersion) needs \(requirements.minimumSupportedCPUCount) CPUs and \(requirements.minimumSupportedMemorySize >> 30) GiB")
		}

		try FileManager.default.createDirectory(at: layout.bundle, withIntermediateDirectories: true)
		try requirements.hardwareModel.dataRepresentation.write(to: layout.hardwareModel)
		try VZMacMachineIdentifier().dataRepresentation.write(to: layout.machineIdentifier)
		_ = try VZMacAuxiliaryStorage(creatingStorageAt: layout.auxiliaryStorage, hardwareModel: requirements.hardwareModel, options: [])
		try BackingFile.create(at: layout.bootDisk, size: Layout.bootDiskSize)
		try BackingFile.create(at: layout.library, size: Layout.librarySize)
		let configuration = try MachineConfiguration.make(layout, role: .install)
		try configuration.validate()

		let machine = VZVirtualMachine(configuration: configuration)
		let installer = VZMacOSInstaller(virtualMachine: machine, restoringFromImageAt: image)
		say("install: installing macOS \(restoreImage.buildVersion) into \(layout.bundle.path)")
		let outcome = Outcome()
		Task {
			do {
				try await installer.install()
				outcome.result = .success(())
			} catch {
				outcome.result = .failure(error)
			}
		}
		var shown = -1
		var overBudget: Error?
		while outcome.result == nil {
			if overBudget == nil {
				do {
					try DiskBudget.check(layout.home)
				} catch {
					overBudget = error
					say("install: stopping, \(error)")
					installer.progress.cancel()
				}
			}
			let percent = Int(installer.progress.fractionCompleted * 100)
			if percent != shown {
				say("install: \(percent)%")
				shown = percent
			}
			try? await Task.sleep(for: .seconds(1))
		}
		if machine.canStop {
			try? await machine.stop()
		}
		if let overBudget { throw overBudget }
		try outcome.result?.get()
		try Data(restoreImage.buildVersion.utf8).write(to: layout.installed)
		say("install: done. Next: power-loss setup")
	}
}
