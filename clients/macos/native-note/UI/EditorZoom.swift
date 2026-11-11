import Foundation

/// The editor's magnification, as View › Zoom In and Zoom Out step it, kept per user like a window size.
enum EditorZoom {
	static let key = "editorMagnification"
	static let range: ClosedRange<Double> = 0.5 ... 3
	static let step = 1.2

	static func larger(_ magnification: Double) -> Double {
		min(range.upperBound, (magnification * step * 100).rounded() / 100)
	}

	static func smaller(_ magnification: Double) -> Double {
		max(range.lowerBound, (magnification / step * 100).rounded() / 100)
	}
}
