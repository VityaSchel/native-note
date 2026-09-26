import Foundation
import NativeNoteKit

func report(_ line: String) {
	FileHandle.standardOutput.write(Data((line + "\n").utf8))
}

let alphabet = Array("abcdefghijklmnopqrstuvwxyz")
let arguments = CommandLine.arguments
guard arguments.count == 3 else {
	report("usage: NativeNoteTypist <library directory> <password>")
	exit(2)
}

let model = AppModel(libraryAt: URL(fileURLWithPath: arguments[1]))
model.start()
await model.submit(password: arguments[2])
guard model.phase == .unlocked else {
	report("locked: \(String(describing: model.failure))")
	exit(1)
}
if let note = model.groups.first?.notes.first {
	model.selection = note.id
} else {
	await model.createNote()
}
guard let id = model.selection else { exit(1) }

var body = model.selectedNote?.body ?? ""
report("start \(body.count)")
while true {
	body.append(alphabet[body.count % alphabet.count])
	model.edit(id, body)
	report("\(body.count) \(DispatchTime.now().uptimeNanoseconds)")
	try await Task.sleep(for: .milliseconds(10))
}
