import Foundation
import PowerLossKit

guard CommandLine.arguments.count == 2 else {
	FileHandle.standardError.write(Data((FlushProbe.usage + "\n").utf8))
	exit(2)
}
let status = FlushProbe.run(
	in: URL(filePath: CommandLine.arguments[1], directoryHint: .isDirectory),
	emit: { FileHandle.standardOutput.write(Data(($0 + "\n").utf8)) },
	pace: { FlushProbe.awaitGo(reading: { readLine() }) }
)
exit(status)
