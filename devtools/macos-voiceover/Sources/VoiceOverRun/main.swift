import AppKit
import VoiceOverRunKit

let home = URL.homeDirectory.appending(path: "Library/Developer/native-note-devtools/voiceover")
let report = home.appending(path: "report.txt")
FileManager.default.createFile(atPath: report.path, contents: nil)
let out = try FileHandle(forWritingTo: report)

func say(_ line: String) {
	out.write(Data((line + "\n").utf8))
	FileHandle.standardError.write(Data((line + "\n").utf8))
}

guard Keyboard.isTrusted else {
	say("Allow \"Native Note VoiceOver Run\" in System Settings > Privacy & Security > Accessibility, then run again.")
	exit(2)
}

let mode = CommandLine.arguments.dropFirst().first ?? "run"
let app = try AppUnderTest(url: home.appending(path: "Native Note.app"))
let voiceOver = VoiceOver()
let run = Run(app: app, voiceOver: voiceOver, server: home.appending(path: "native-note-server"), data: home.appending(path: "server"), say: say)

do {
	switch mode {
	case "explore": try run.explore()
	default: try run.all()
	}
} catch {
	say("STOPPED: \(error)")
}
run.finish()
exit(run.failed ? 1 : 0)
