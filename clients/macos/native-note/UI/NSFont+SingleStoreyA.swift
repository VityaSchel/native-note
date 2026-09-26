import AppKit
import CoreText

extension NSFont {
	var withSingleStoreyA: NSFont {
		let alternate: [NSFontDescriptor.FeatureKey: Int] = [
			.typeIdentifier: kStylisticAlternativesType,
			.selectorIdentifier: kStylisticAltSevenOnSelector,
		]
		let descriptor = fontDescriptor.addingAttributes([.featureSettings: [alternate]])
		return NSFont(descriptor: descriptor, size: pointSize) ?? self
	}
}
