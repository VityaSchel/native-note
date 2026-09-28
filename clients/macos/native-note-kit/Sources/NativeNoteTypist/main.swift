import CryptoKit
import Foundation
import NativeNoteKit

enum Mode: String {
	case type
	case acknowledge
	case acknowledgeBeforeSaving = "acknowledge-before-saving"
	case prepare
	case verify
}

struct VerifierReport: Encodable {
	let phase: String
	let failure: String?
	let integrity: String?
	let notes: Int
	let body: String?
	let walCheckpoints: Int?
}

func report(_ line: String) {
	FileHandle.standardOutput.write(Data((line + "\n").utf8))
}

func reportUnsaved(_ model: AppModel) {
	report("unsaved: \(String(describing: model.failure))")
}

func digest(_ text: String) -> String {
	SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
}

func noteToType(in model: AppModel) async -> UUID {
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
	return id
}

func verify(_ model: AppModel, library: URL, password: String, walCheckpoints: Int?) async {
	guard model.phase == .locked else {
		return send(VerifierReport(phase: String(describing: model.phase), failure: nil, integrity: nil, notes: 0, body: nil, walCheckpoints: walCheckpoints))
	}
	await model.submit(password: password)
	guard model.phase == .unlocked else {
		return send(VerifierReport(phase: String(describing: model.phase), failure: model.failure.map(String.init(describing:)), integrity: nil, notes: 0, body: nil, walCheckpoints: walCheckpoints))
	}
	let notes = model.groups.flatMap(\.notes)
	await model.close()
	let integrity: String
	do {
		integrity = try await LibraryIntegrity.check(libraryAt: library, password: password)
	} catch {
		integrity = "failed: \(error)"
	}
	send(VerifierReport(phase: "unlocked", failure: nil, integrity: integrity, notes: notes.count, body: notes.first?.body, walCheckpoints: walCheckpoints))
}

func send(_ verdict: VerifierReport) {
	let encoder = JSONEncoder()
	encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
	report(String(decoding: (try? encoder.encode(verdict)) ?? Data(), as: UTF8.self))
}

let alphabet = Array("abcdefghijklmnopqrstuvwxyz")
let arguments = Array(CommandLine.arguments.dropFirst())
guard (3 ... 4).contains(arguments.count), let mode = Mode(rawValue: arguments[0]) else {
	report("usage: NativeNoteTypist type|acknowledge|acknowledge-before-saving|prepare|verify <library directory> <password> [acknowledgements]")
	exit(2)
}
let library = URL(fileURLWithPath: arguments[1])
let password = arguments[2]
let acknowledgementLimit = arguments.count == 4 ? Int(arguments[3]) : Int.max
guard let acknowledgementLimit else {
	report("acknowledgements must be a number")
	exit(2)
}

let model = AppModel(libraryAt: library, keyStore: AbsentKeyStore(), bindsToThisMac: false)
if mode == .verify {
	let walCheckpoints = LibraryIntegrity.walCheckpoints(libraryAt: library)
	model.start()
	await verify(model, library: library, password: password, walCheckpoints: walCheckpoints)
	exit(0)
}
model.start()

await model.submit(password: password)
let id = await noteToType(in: model)
if mode == .prepare {
	guard await model.flushPendingSaves() else {
		reportUnsaved(model)
		exit(1)
	}
	await model.close()
	report("prepared \(model.noteCount)")
	exit(0)
}

var body = model.selectedNote?.body ?? ""
report("start \(body.count)")
if mode == .acknowledge {
	Task {
		var acknowledged = 0
		var committed = body.count
		while acknowledged < acknowledgementLimit {
			try? await Task.sleep(for: .milliseconds(Int.random(in: 20 ... 300)))
			let snapshot = body
			guard snapshot.count > committed else { continue }
			guard await model.flushPendingSaves() else {
				reportUnsaved(model)
				continue
			}
			committed = snapshot.count
			acknowledged += 1
			report("ack \(acknowledged) \(snapshot.count) \(digest(snapshot))")
		}
		exit(0)
	}
}
var acknowledgedBeforeSaving = 0
while true {
	body.append(alphabet[body.count % alphabet.count])
	model.edit(id, body)
	report("\(body.count) \(DispatchTime.now().uptimeNanoseconds)")
	if mode == .acknowledgeBeforeSaving {
		acknowledgedBeforeSaving += 1
		report("ack \(acknowledgedBeforeSaving) \(body.count) \(digest(body))")
		if acknowledgedBeforeSaving >= acknowledgementLimit { exit(0) }
	}
	try await Task.sleep(for: .milliseconds(10))
}
