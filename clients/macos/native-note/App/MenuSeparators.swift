import AppKit

/// SwiftUI leaves an empty command group's separators in the View menu, so two can meet; before a menu shows, every separator that would sit next to another, or at an end, is hidden.
enum MenuSeparators {
	static func tidy(_ menu: NSMenu) {
		var previousShownIsSeparator = true
		for item in menu.items {
			if item.isSeparatorItem {
				item.isHidden = previousShownIsSeparator
			}
			if !item.isHidden {
				previousShownIsSeparator = item.isSeparatorItem
			}
			item.submenu.map(tidy)
		}
		if let last = menu.items.last(where: { !$0.isHidden }), last.isSeparatorItem {
			last.isHidden = true
		}
	}
}
