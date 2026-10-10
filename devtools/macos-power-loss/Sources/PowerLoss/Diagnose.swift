import Foundation
import PowerLossKit

struct Diagnose {
	static let bootTimeout = Duration.seconds(600)
	static let diagnosisTimeout = Duration.seconds(900)
	static let probeTimeout = Duration.seconds(300)

	let layout: Layout
	let options: DiagnoseOptions

	func run() async throws {
		try layout.requireSetUp()
		try GuestKit.stage(layout)
		let link = try AgentLink(options.transport ?? layout.savedTransport() ?? .vsock, layout: layout)
		let source = options.source ?? (layout.exists(layout.preparedLibrary) ? layout.preparedLibrary : layout.formattedLibrary)
		try BackingFile.restore(layout.library, from: source)
		let disk = try OrderedDisk(backing: layout.library)
		let library = try Library(serving: disk, image: layout.library, as: options.library, over: options.nbd)
		defer { library.stop() }
		try DiskBudget.check(layout.home)
		say("diagnose: a copy of \(source.lastPathComponent) as \(library.name), agent over \(link)")

		let configuration = try MachineConfiguration.make(layout, role: .run(library: library.attachment, kit: layout.kit))
		try await Machine.running(configuration) { machine in
			try await link.waitUntilReady(on: machine, within: Self.bootTimeout)
			say("diagnose: the agent answers; while the guest booted the library saw \(library.activity.summary)")
			try await link.pushKit(layout, on: machine)
			let beforeDiagnosis = library.activity
			try await diagnose(link, on: machine)
			say("diagnose: while the guest ran the diagnosis the library saw \(library.activity.since(beforeDiagnosis).summary)")
			for target in ProbeTarget.allCases {
				try await probe(target, link: link, on: machine, library: library)
			}
			let beforeShutdown = library.activity
			await link.shutDown(machine)
			say("diagnose: while the guest shut down the library saw \(library.activity.since(beforeShutdown).summary)")
		}
		say("diagnose: in all the library saw \(library.activity.summary)")
		let rejections = library.rejections
		say(rejections.isEmpty ? "diagnose: the NBD server rejected no request" : "diagnose: the NBD server rejected these requests:")
		for rejection in rejections {
			say("  \(rejection)")
		}
	}

	private func diagnose(_ link: AgentLink, on machine: Machine) async throws {
		say("diagnose: running the guest diagnosis")
		let session = try await link.open(.diagnose, on: machine)
		defer { session.close() }
		let ending = await session.follow(within: Self.diagnosisTimeout) { say($0) }
		if session.keepAlives > 0 {
			say("diagnose: the guest went quiet \(session.keepAlives) times and was sent a keepalive line each time")
		}
		if ending != .done {
			say("diagnose: the guest diagnosis did not finish: \(ending.map(\.line) ?? "no answer within \(Self.diagnosisTimeout)"); probing anyway")
		}
	}

	private func probe(_ target: ProbeTarget, link: AgentLink, on machine: Machine, library: Library) async throws {
		say("diagnose: probing flushes on the \(target.rawValue) volume, snapshotting the library disk at every marker")
		let session = try await link.open(.probe(target), on: machine)
		defer { session.close() }
		var timeline = ProbeTimeline()
		let ending = try await session.follow(within: Self.probeTimeout) { line in
			say("  \(line)")
			guard let marker = ProbeMarker(line: line) else { return }
			timeline.mark(marker, activity: library.activity)
			try session.send(line: "go")
		}
		say("diagnose: \(target.rawValue) probe ended with \(ending.map(\.line) ?? "no answer within \(Self.probeTimeout)"), \(session.keepAlives) keepalives")
		for line in timeline.report {
			say("  \(line)")
		}
	}
}

private struct Library {
	let name: String
	let attachment: MachineConfiguration.LibraryAttachment
	let server: NBDServer?

	init(serving disk: OrderedDisk, image: URL, as device: LibraryDevice, over transport: NBDTransport) throws {
		switch device {
		case .image:
			server = nil
			attachment = .image(image)
			name = "a plain disk image \(image.lastPathComponent) the harness cannot watch"
		case .virtio, .usb:
			let server = NBDServer(disk: disk, log: say)
			let url = try server.start(transport.endpoint)
			self.server = server
			attachment = .nbd(url, device)
			name = "\(device.rawValue) storage at \(url.absoluteString)"
		}
	}

	var activity: DiskActivity {
		server?.activity ?? DiskActivity()
	}

	var rejections: [NBDRejection] {
		server?.rejections ?? []
	}

	func stop() {
		server?.stop()
	}
}
