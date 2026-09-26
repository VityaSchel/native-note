import AppKit
import SwiftUI
import Testing

@testable import NativeNote
@testable import NativeNoteKit

@MainActor @Suite(.serialized, .timeLimit(.minutes(2)))
struct TypingPerformanceTests {
	private let alarm = Alarm()

	private struct Library {
		let model: AppModel
		let directory: URL
		let offscreen: OffscreenWindow<ContentView>
		let editor: NSTextView
	}

	private func library(notes count: Int) async throws -> Library {
		let (model, directory) = try await unlockedModel(alarm: alarm)
		let store = try await observer(of: directory)
		for body in RealisticCorpus.bodies(count: count) { try await store.save(sampleNote(body: body)) }
		await store.close()
		await model.lock()
		await model.submit(password: workspacePassword)
		model.selection = model.groups.first?.notes.first?.id
		let offscreen = OffscreenWindow(ContentView(exchange: LibraryExchange(model: model)), width: 980, height: 560)
		offscreen.pump(for: 0.2)
		let editor = try #require(offscreen.views(of: NSTextView.self).first { !$0.isFieldEditor && $0.isEditable })
		try #require(offscreen.window.makeFirstResponder(editor))
		return Library(model: model, directory: directory, offscreen: offscreen, editor: editor)
	}

	private func type<Content: View>(_ index: Int, into editor: NSTextView, of offscreen: OffscreenWindow<Content>, measuring timings: inout Timings) async {
		await timings.measure {
			editor.insertText(String(index % 10), replacementRange: NSRange(location: (editor.string as NSString).length, length: 0))
			offscreen.window.layoutIfNeeded()
			offscreen.host.layoutSubtreeIfNeeded()
			offscreen.host.displayIfNeeded()
		}
		offscreen.pump(for: 0.002)
	}

	@Test func typingCostsLittleMoreThanAPlainTextViewAndBarelyGrowsWithAThousandNotes() async throws {
		let plain = NSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 560))
		plain.string = RealisticCorpus.bodies(count: 1)[0]
		let reference = OffscreenWindow(PlainEditor(textView: plain), width: 600, height: 560)
		defer { reference.close() }
		let small = try await library(notes: 10)
		let large = try await library(notes: 1_000)
		var warmUp = Timings()
		var plainKeystrokes = Timings()
		var smallKeystrokes = Timings()
		var largeKeystrokes = Timings()

		for index in 0 ..< 20 {
			await type(index, into: plain, of: reference, measuring: &warmUp)
			await type(index, into: small.editor, of: small.offscreen, measuring: &warmUp)
			await type(index, into: large.editor, of: large.offscreen, measuring: &warmUp)
		}
		for index in 20 ..< 170 {
			await type(index, into: plain, of: reference, measuring: &plainKeystrokes)
			await type(index, into: small.editor, of: small.offscreen, measuring: &smallKeystrokes)
			await type(index, into: large.editor, of: large.offscreen, measuring: &largeKeystrokes)
		}

		let costs = "\(largeKeystrokes.percentile(0.5)) ms with 1,000 notes, \(smallKeystrokes.percentile(0.5)) ms with 10, \(plainKeystrokes.percentile(0.5)) ms in a plain text view"
		#expect(large.model.noteCount == 1_000)
		#expect(large.model.selectedNote?.body.hasSuffix("6789") == true)
		#expect(largeKeystrokes.percentile(0.5) <= 20 * plainKeystrokes.percentile(0.5), "a keystroke costs \(costs)")
		#expect(largeKeystrokes.percentile(0.5) <= 3 * smallKeystrokes.percentile(0.5), "a keystroke costs \(costs)")
		for library in [small, large] {
			#expect(await library.model.flushPendingSaves())
			library.offscreen.close()
			try? FileManager.default.removeItem(at: library.directory)
		}
	}
}

private struct PlainEditor: NSViewRepresentable {
	let textView: NSTextView

	func makeNSView(context: Context) -> NSScrollView {
		let scrollView = NSScrollView()
		scrollView.documentView = textView
		return scrollView
	}

	func updateNSView(_ scrollView: NSScrollView, context: Context) {}
}
