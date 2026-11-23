import AppKit
import ObjectiveC
import SwiftUI
import Testing

@testable import NativeNote

enum Appearance: String, CaseIterable, CustomTestStringConvertible {
	case light, dark, increasedLight, increasedDark

	var testDescription: String { rawValue }

	var increasesContrast: Bool {
		self == .increasedLight || self == .increasedDark
	}

	var isDark: Bool {
		self == .dark || self == .increasedDark
	}

	@MainActor var appearance: NSAppearance? {
		SystemContrast.appearance(dark: isDark, increased: increasesContrast)
	}

	@MainActor func resolve(_ color: NSColor) -> RGBA {
		var resolved = RGBA(red: 0, green: 0, blue: 0, alpha: 0)
		appearance?.performAsCurrentDrawingAppearance { resolved = RGBA(color: color) }
		return resolved
	}
}

@MainActor
enum SystemContrast {
	private(set) static var isEmulating = false

	static func appearance(dark: Bool, increased: Bool) -> NSAppearance? {
		let selector = NSSelectorFromString(dark ? "_darkAquaAppearanceWithAccessibility:" : "_aquaAppearanceWithAccessibility:")
		guard let method = class_getClassMethod(NSAppearance.self, selector) else { return nil }
		let make = unsafeBitCast(method_getImplementation(method), to: (@convention(c) (AnyClass, Selector, Bool) -> NSAppearance?).self)
		return make(NSAppearance.self, selector, increased)
	}

	static func emulating<Result>(increased: Bool, _ body: () throws -> Result) throws -> Result {
		let light = try #require(appearance(dark: false, increased: increased))
		let dark = try #require(appearance(dark: true, increased: increased))
		let named = NSSelectorFromString("appearanceNamed:")
		let namedMethod = try #require(class_getClassMethod(NSAppearance.self, named))
		let flagMethod = try #require(class_getInstanceMethod(NSWorkspace.self, #selector(getter: NSWorkspace.accessibilityDisplayShouldIncreaseContrast)))
		let original = method_getImplementation(namedMethod)
		let lookUp = unsafeBitCast(original, to: (@convention(c) (AnyClass, Selector, NSString) -> NSAppearance?).self)
		let namedAppearance: @convention(block) (AnyObject, NSString) -> NSAppearance? = { _, name in
			switch NSAppearance.Name(name as String) {
			case .aqua: light
			case .darkAqua: dark
			default: lookUp(NSAppearance.self, named, name)
			}
		}
		let flag: @convention(block) (AnyObject) -> Bool = { _ in increased }
		let namedReplacement = imp_implementationWithBlock(namedAppearance)
		let flagReplacement = imp_implementationWithBlock(flag)
		let originalFlag = method_setImplementation(flagMethod, flagReplacement)
		method_setImplementation(namedMethod, namedReplacement)
		isEmulating = true
		postChange()
		defer {
			isEmulating = false
			method_setImplementation(namedMethod, original)
			method_setImplementation(flagMethod, originalFlag)
			imp_removeBlock(namedReplacement)
			imp_removeBlock(flagReplacement)
			postChange()
		}
		return try body()
	}

	private static func postChange() {
		NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: NSWorkspace.shared)
	}
}

struct RGBA: CustomStringConvertible {
	var red: Double
	var green: Double
	var blue: Double
	var alpha = 1.0

	init(red: Double, green: Double, blue: Double, alpha: Double = 1.0) {
		self.red = red
		self.green = green
		self.blue = blue
		self.alpha = alpha
	}

	init(color: NSColor) {
		let srgb = color.usingColorSpace(.sRGB) ?? .black
		self.init(red: srgb.redComponent, green: srgb.greenComponent, blue: srgb.blueComponent, alpha: srgb.alphaComponent)
	}

	static func ratio(_ first: Double, _ second: Double) -> Double {
		(max(first, second) + 0.05) / (min(first, second) + 0.05)
	}

	func over(_ background: RGBA) -> RGBA {
		RGBA(
			red: red * alpha + background.red * (1 - alpha),
			green: green * alpha + background.green * (1 - alpha),
			blue: blue * alpha + background.blue * (1 - alpha)
		)
	}

	var luminance: Double {
		func linear(_ value: Double) -> Double { value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
		return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
	}

	func contrast(with other: RGBA) -> Double {
		Self.ratio(luminance, other.luminance)
	}

	func matches(_ other: RGBA) -> Bool {
		max(abs(red - other.red), abs(green - other.green), abs(blue - other.blue)) <= 8.0 / 255
	}

	var description: String {
		String(format: "#%02X%02X%02X", Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded()))
	}
}

struct Measurement {
	let background: RGBA
	let weakest: Double
	let weakestInk: RGBA
	let strongest: Double
	let segments: Int
}

@MainActor
struct Snapshot {
	static let scale = 2

	let image: NSImage
	private let rep: NSBitmapImageRep
	private let width: Int
	private let height: Int
	private let luminances: [Double]

	init?(of view: NSView, over background: RGBA) {
		let size = view.bounds.size
		width = Int(size.width.rounded()) * Self.scale
		height = Int(size.height.rounded()) * Self.scale
		guard
			let rep = NSBitmapImageRep(
				bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
				hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32
			)?.retagging(with: .sRGB)
		else { return nil }
		rep.size = size
		view.cacheDisplay(in: view.bounds, to: rep)
		guard let bytes = rep.bitmapData, rep.bytesPerRow == width * 4 else { return nil }
		let (red, green, blue) = (Int((background.red * 255).rounded()), Int((background.green * 255).rounded()), Int((background.blue * 255).rounded()))
		let linear = Self.linear
		var luminances = [Double](repeating: 0, count: width * height)
		luminances.withUnsafeMutableBufferPointer { luminances in
			linear.withUnsafeBufferPointer { linear in
				var index = 0
				while index < luminances.count {
					let pixel = bytes + index * 4
					let clear = 255 - Int(pixel[3])
					if clear > 0 {
						pixel[0] = UInt8(min(255, Int(pixel[0]) + (red * clear + 127) / 255))
						pixel[1] = UInt8(min(255, Int(pixel[1]) + (green * clear + 127) / 255))
						pixel[2] = UInt8(min(255, Int(pixel[2]) + (blue * clear + 127) / 255))
						pixel[3] = 255
					}
					luminances[index] = 0.2126 * linear[Int(pixel[0])] + 0.7152 * linear[Int(pixel[1])] + 0.0722 * linear[Int(pixel[2])]
					index += 1
				}
			}
		}
		self.luminances = luminances
		self.rep = rep
		image = NSImage(size: size)
		image.addRepresentation(rep)
	}

	private static let linear: [Double] = (0 ... 255).map { RGBA(red: Double($0) / 255, green: 0, blue: 0).luminance / 0.2126 }

	private func color(at index: Int) -> RGBA {
		let pixel = rep.bitmapData! + index * 4
		return RGBA(red: Double(pixel[0]) / 255, green: Double(pixel[1]) / 255, blue: Double(pixel[2]) / 255)
	}

	private func index(x: CGFloat, y: CGFloat) -> Int? {
		let (column, row) = (Int(x * CGFloat(Self.scale)), Int(y * CGFloat(Self.scale)))
		guard (0 ..< width).contains(column), (0 ..< height).contains(row) else { return nil }
		return row * width + column
	}

	private struct Region {
		let left: Int
		let top: Int
		let right: Int
		let bottom: Int

		func contains(_ column: Int, _ row: Int) -> Bool {
			column >= left && column < right && row >= top && row < bottom
		}
	}

	private func pixels(in rect: NSRect) -> Region {
		let scale = CGFloat(Self.scale)
		return Region(
			left: max(0, Int((rect.minX * scale).rounded(.down))), top: max(0, Int((rect.minY * scale).rounded(.down))),
			right: min(width, Int((rect.maxX * scale).rounded(.up))), bottom: min(height, Int((rect.maxY * scale).rounded(.up)))
		)
	}

	private func background(in region: Region, outside hole: Region? = nil) -> RGBA? {
		let (columns, rows) = (max(0, region.right - region.left), max(0, region.bottom - region.top))
		guard let bytes = rep.bitmapData, columns > 0, rows > 0 else { return nil }
		var counts = [Int32](repeating: 0, count: 1 << 15)
		var keys = [Int32](repeating: -1, count: columns * rows)
		var mode = -1
		counts.withUnsafeMutableBufferPointer { counts in
			keys.withUnsafeMutableBufferPointer { keys in
				var local = 0
				while local < keys.count {
					let (column, row) = (region.left + local % columns, region.top + local / columns)
					if hole?.contains(column, row) != true {
						let pixel = bytes + (row * width + column) * 4
						let bucket = Int(pixel[0] >> 3) << 10 | Int(pixel[1] >> 3) << 5 | Int(pixel[2] >> 3)
						keys[local] = Int32(bucket)
						counts[bucket] += 1
						if mode < 0 || counts[bucket] > counts[mode] { mode = bucket }
					}
					local += 1
				}
			}
		}
		guard mode >= 0 else { return nil }
		var sum = SIMD3<Double>.zero
		var members = 0.0
		keys.withUnsafeBufferPointer { keys in
			var local = 0
			while local < keys.count {
				if keys[local] == Int32(mode) {
					let pixel = bytes + ((region.top + local / columns) * width + region.left + local % columns) * 4
					sum += SIMD3(Double(pixel[0]), Double(pixel[1]), Double(pixel[2]))
					members += 1
				}
				local += 1
			}
		}
		let average = sum / members / 255
		return RGBA(red: average.x, green: average.y, blue: average.z)
	}

	func measure(_ rect: NSRect, againstSurroundings: Bool = false) -> Measurement? {
		let region = pixels(in: rect)
		let (columns, rows) = (region.right - region.left, region.bottom - region.top)
		guard columns > 2, rows > 2 else { return nil }
		let area = columns * rows
		let surroundings = againstSurroundings ? background(in: pixels(in: rect.insetBy(dx: -3, dy: -3)), outside: region) : nil
		guard let background = surroundings ?? background(in: region) else { return nil }
		let backgroundLuminance = background.luminance

		var ratios = [Double](repeating: 0, count: area)
		var strongest = 1.0
		ratios.withUnsafeMutableBufferPointer { ratios in
			luminances.withUnsafeBufferPointer { luminances in
				var local = 0
				while local < area {
					let ratio = RGBA.ratio(luminances[(region.top + local / columns) * width + region.left + local % columns], backgroundLuminance)
					if ratio >= 1.1 { ratios[local] = ratio }
					if ratio > strongest { strongest = ratio }
					local += 1
				}
			}
		}

		var weakest = Double.infinity
		var weakestAt = 0
		var segments = 0
		var visited = [Bool](repeating: false, count: area)
		var pending: [Int] = []
		ratios.withUnsafeBufferPointer { ratios in
			visited.withUnsafeMutableBufferPointer { visited in
				var start = 0
				while start < area {
					defer { start += 1 }
					guard ratios[start] > 0, !visited[start] else { continue }
					visited[start] = true
					pending.append(start)
					var (size, peak, peakAt) = (0, 0.0, start)
					while let next = pending.popLast() {
						size += 1
						if ratios[next] > peak { (peak, peakAt) = (ratios[next], next) }
						let (column, row) = (next % columns, next / columns)
						var neighborRow = max(0, row - 1)
						while neighborRow <= min(rows - 1, row + 1) {
							var neighborColumn = max(0, column - 4)
							while neighborColumn <= min(columns - 1, column + 4) {
								let neighbor = neighborRow * columns + neighborColumn
								if ratios[neighbor] > 0, !visited[neighbor] {
									visited[neighbor] = true
									pending.append(neighbor)
								}
								neighborColumn += 1
							}
							neighborRow += 1
						}
					}
					guard size >= 6 else { continue }
					segments += 1
					if peak < weakest { (weakest, weakestAt) = (peak, peakAt) }
				}
			}
		}
		guard segments > 0 else { return Measurement(background: background, weakest: 1, weakestInk: background, strongest: strongest, segments: 0) }
		let ink = (region.top + weakestAt / columns) * width + region.left + weakestAt % columns
		return Measurement(background: background, weakest: weakest, weakestInk: color(at: ink), strongest: strongest, segments: segments)
	}

	func ring(leftOf field: NSRect) -> Double? {
		guard let outside = index(x: field.minX - 20, y: field.midY) else { return nil }
		var strongest: Double?
		var x = field.minX - 17
		while x < field.minX {
			if let inside = index(x: x, y: field.midY) {
				strongest = max(strongest ?? 1, RGBA.ratio(luminances[inside], luminances[outside]))
			}
			x += 1 / CGFloat(Self.scale)
		}
		return strongest
	}
}

@MainActor
struct DrawnElement {
	let name: String
	let frame: NSRect
	let isGraphic: Bool
	let isAppleControl: Bool

	var threshold: Double {
		isGraphic ? 3 : 4.5
	}

	func value(of measurement: Measurement) -> Double {
		isAppleControl ? measurement.strongest : measurement.weakest
	}

	private static let textRoles: Set<NSAccessibility.Role> = [.staticText, NSAccessibility.Role(rawValue: "AXHeading"), .link, .textArea]
	private static let controlRoles: Set<NSAccessibility.Role> = [.button, .checkBox, .radioButton, .popUpButton, .menuButton, .comboBox, .textField]

	init?(_ element: AccessibilityElement, in frame: NSRect) {
		guard let role = element.role, element.isEnabled || role == .textArea, frame.width >= 4, frame.height >= 4 else { return nil }
		let iconOnly = role == .button && element.label == UnlockView.arrowLabel
		let drawsText = role == .textField ? !element.value.isEmpty || !element.placeholder.isEmpty : !element.label.isEmpty || !element.value.isEmpty
		guard Self.textRoles.contains(role) || Self.controlRoles.contains(role) && (drawsText || iconOnly) || role == .image else { return nil }
		name = ([role.rawValue] + [element.label, element.value, element.placeholder].filter { !$0.isEmpty }.map { "\"\($0)\"" }).joined(separator: " ")
		self.frame = frame
		isGraphic = role == .image || iconOnly
		isAppleControl = Self.controlRoles.contains(role) && !iconOnly
	}
}

@MainActor
struct ContrastReading {
	let element: DrawnElement
	let appearance: Appearance
	let emphasized: Bool
	let measurement: Measurement

	var value: Double {
		element.value(of: measurement)
	}

	var meetsThreshold: Bool {
		value >= element.threshold
	}

	var mayFallShort: Bool {
		guard !appearance.increasesContrast else { return false }
		if element.isAppleControl { return true }
		let lifted: [NSColor] = [.secondaryLabelColor, .tertiaryLabelColor, .systemRed, .systemOrange]
		if lifted.contains(where: { appearance.resolve($0).over(measurement.background).matches(measurement.weakestInk) }) { return true }
		return emphasized && appearance.resolve(.selectedContentBackgroundColor).matches(measurement.background)
	}

	var description: String {
		String(
			format: "%@ in %@%@ is %.2f:1, needs %.1f:1 (%@ on %@)",
			element.name, appearance.rawValue, emphasized ? " with the selection emphasized" : "", value, element.threshold,
			"\(measurement.weakestInk)", "\(measurement.background)"
		)
	}
}

@MainActor
struct ContrastAudit {
	var readings: [ContrastReading] = []
	var rings: [(appearance: Appearance, ratio: Double)] = []

	func readings(of name: String, in appearance: Appearance) -> [ContrastReading] {
		readings.filter { $0.element.name.contains(name) && $0.appearance == appearance && !$0.emphasized }
	}
}

extension OffscreenWindow {
	func drawnElements() -> [DrawnElement] {
		let scrollPockets = views(of: NSView.self).filter { NSStringFromClass(Swift.type(of: $0)).hasSuffix("ScrollPocket") }
		let materials = views(of: NSVisualEffectView.self).filter { $0.blendingMode == .behindWindow }
		let sidebars = views(of: NSTableView.self).filter { $0.effectiveStyle == .sourceList }
		let covered = (scrollPockets + materials.map { $0 as NSView } + sidebars.map { $0 as NSView }).map { flipped(host.convert($0.bounds, from: $0)) }
		return EnhancedAccessibility.reading {
			_ = accessibilityNodes()
			pump(for: 0.2)
			return accessibilityNodes().compactMap { node in
				let frame = hostRect(ofScreen: node.frame)
				guard !covered.contains(where: { $0.contains(NSPoint(x: frame.midX, y: frame.midY)) }) else { return nil }
				return DrawnElement(node, in: frame)
			}
		}
	}

	private func accessibilityNodes() -> [AccessibilityElement] {
		var found: [AccessibilityElement] = []
		var visited: Set<ObjectIdentifier> = []
		var pending: [AnyObject] = [host]
		while let node = pending.popLast(), found.count < 5000 {
			guard visited.insert(ObjectIdentifier(node)).inserted else { continue }
			if node !== host { found.append(AccessibilityElement(node)) }
			pending.append(contentsOf: AttributeElement.children(of: node).reversed())
		}
		return found
	}

	func hostRect(ofScreen frame: NSRect) -> NSRect {
		flipped(host.convert(window.convertFromScreen(frame), from: nil))
	}

	private func flipped(_ rect: NSRect) -> NSRect {
		host.isFlipped ? rect : NSRect(x: rect.minX, y: host.bounds.height - rect.maxY, width: rect.width, height: rect.height)
	}

	func auditContrast(_ screen: String, attachingShortfalls: Bool = true, sourceLocation: SourceLocation = #_sourceLocation) async throws -> ContrastAudit {
		window.appearance = Appearance.light.appearance
		pump(for: 0.05)
		let elements = drawnElements()
		let capsules = views(of: NSSecureTextField.self).filter { !$0.isBezeled && !$0.isBordered }.map { flipped(host.convert($0.bounds, from: $0)) }
		let selects = views(of: NSTableView.self).contains { $0.selectedRow >= 0 }
		var audit = ContrastAudit()
		for emphasized in selects ? [false, true] : [false] {
			if emphasized {
				emphasizeSelection()
				pump(for: 0.05)
			}
			let standard = try SystemContrast.emulating(increased: false) {
				[try render(.light, emphasized: emphasized), try render(.dark, emphasized: emphasized)]
			}
			let increased = try SystemContrast.emulating(increased: true) {
				[try render(.increasedLight, emphasized: emphasized), try render(.increasedDark, emphasized: emphasized)]
			}
			for (appearance, snapshot) in zip([Appearance.light, .dark, .increasedLight, .increasedDark], standard + increased) {
				var readings: [ContrastReading] = []
				for element in elements {
					if let measurement = snapshot.measure(element.frame, againstSurroundings: element.isGraphic), measurement.segments > 0 {
						readings.append(ContrastReading(element: element, appearance: appearance, emphasized: emphasized, measurement: measurement))
					}
					await Task.yield()
				}
				let rings = capsules.compactMap { snapshot.ring(leftOf: $0) }
				let shortfalls = readings.filter { !$0.meetsThreshold && !$0.mayFallShort }.map(\.description)
					+ (appearance.increasesContrast ? rings.filter { $0 < 3 }.map { String(format: "capsule field outline in %@ is %.2f:1, needs 3.0:1", appearance.rawValue, $0) } : [])
				for shortfall in shortfalls {
					Issue.record("\(screen): \(shortfall)", sourceLocation: sourceLocation)
				}
				if attachingShortfalls, !shortfalls.isEmpty {
					Attachment.record(snapshot.image, named: "\(screen) \(appearance)\(emphasized ? " emphasized" : "")", as: .png, sourceLocation: sourceLocation)
				}
				audit.readings += readings
				audit.rings += rings.map { (appearance: appearance, ratio: $0) }
			}
		}
		return audit
	}

	private func render(_ appearance: Appearance, emphasized: Bool) throws -> Snapshot {
		let drawing: NSAppearance = try #require(appearance.appearance)
		window.appearance = drawing
		host._renderForTest(interval: 0)
		if emphasized {
			emphasizeSelection()
			host._renderForTest(interval: 0)
		}
		window.layoutIfNeeded()
		host.layoutSubtreeIfNeeded()
		host.displayIfNeeded()
		return try #require(Snapshot(of: host, over: appearance.resolve(.windowBackgroundColor)))
	}

	private func emphasizeSelection() {
		for table in views(of: NSTableView.self) {
			table.enumerateAvailableRowViews { row, _ in row.isEmphasized = true }
		}
	}
}
