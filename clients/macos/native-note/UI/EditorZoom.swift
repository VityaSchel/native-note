import Foundation

enum EditorZoom {
	static let key = "editorZoom"
	static let range: ClosedRange<Double> = 0.5 ... 3
	static let step = 1.2

	static func larger(_ zoom: Double) -> Double {
		min(range.upperBound, (zoom * step * 100).rounded() / 100)
	}

	static func smaller(_ zoom: Double) -> Double {
		max(range.lowerBound, (zoom / step * 100).rounded() / 100)
	}
}
