import AppKit
import Testing

struct AppIconTests {
	@Test func theAppUsesItsIcon() {
		#expect(Bundle.main.object(forInfoDictionaryKey: "CFBundleIconName") as? String == "AppIcon")
	}

	@Test(arguments: zip([16, 32], [0.013, 0.026]))
	func theRuledPageShowsAtFinderSizes(pixels: Int, minimumSpread: Double) throws {
		let url = try #require(Bundle.main.url(forResource: "AppIcon", withExtension: "icns"))
		let icon = try #require(NSImage(contentsOf: url))
		let image = try #require(icon.representations.lazy.compactMap { $0 as? NSBitmapImageRep }.first { $0.pixelsWide == pixels })

		#expect(luminanceSpread(inside: image) > minimumSpread)
	}

	private func luminanceSpread(inside image: NSBitmapImageRep) -> Double {
		let margin = image.pixelsWide / 5
		let span = margin ..< image.pixelsWide - margin
		let luminances = span.flatMap { y in
			span.compactMap { x in
				image.colorAt(x: x, y: y)?.usingColorSpace(.sRGB).map { 0.2126 * $0.redComponent + 0.7152 * $0.greenComponent + 0.0722 * $0.blueComponent }
			}
		}
		let mean = luminances.reduce(0, +) / Double(luminances.count)
		return (luminances.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(luminances.count)).squareRoot()
	}
}
