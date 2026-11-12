import AppKit

enum MenuSeparators {
	static func hideDoubledAndEdgeSeparators(in menu: NSMenu) {
		var previousShownIsSeparator = true
		for item in menu.items {
			if item.isSeparatorItem {
				item.isHidden = previousShownIsSeparator
			}
			if !item.isHidden {
				previousShownIsSeparator = item.isSeparatorItem
			}
			if let submenu = item.submenu { hideDoubledAndEdgeSeparators(in: submenu) }
		}
		if let last = menu.items.last(where: { !$0.isHidden }), last.isSeparatorItem {
			last.isHidden = true
		}
	}
}
