import Darwin
import Foundation
import PowerLossKit

func fail(_ message: String) -> Never {
	FileHandle.standardError.write(Data(AgentLog.line(message).utf8))
	exit(1)
}

func listen(on port: UInt32) -> Int32 {
	let listener = socket(AF_VSOCK, SOCK_STREAM, 0)
	guard listener >= 0 else { fail("vsock socket failed with errno \(errno)") }
	var address = sockaddr_vm()
	address.svm_len = UInt8(MemoryLayout<sockaddr_vm>.size)
	address.svm_family = sa_family_t(AF_VSOCK)
	address.svm_port = port
	address.svm_cid = UInt32(bitPattern: -1)
	let bound = withUnsafePointer(to: &address) { pointer in
		pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_vm>.size)) }
	}
	guard bound == 0, Darwin.listen(listener, 4) == 0 else { fail("vsock port \(port) failed with errno \(errno)") }
	return listener
}

func shutDownTheGuest() {
	let shutdown = Process()
	shutdown.executableURL = URL(fileURLWithPath: "/sbin/shutdown")
	shutdown.arguments = ["-h", "now"]
	try? shutdown.run()
}

signal(SIGPIPE, SIG_IGN)
let service = AgentService(typist: LocalKit.typist, libraryDirectory: LibraryVolume.libraryDirectory, shutDown: shutDownTheGuest)
let listener = listen(on: AgentRequest.port)
FileHandle.standardError.write(Data(AgentLog.listening(on: AgentRequest.port).utf8))
while true {
	let connection = accept(listener, nil, nil)
	guard connection >= 0 else {
		if errno != EINTR, errno != ECONNABORTED { fail("accept failed with errno \(errno)") }
		continue
	}
	Thread {
		service.serve(connection)
		close(connection)
	}.start()
}
