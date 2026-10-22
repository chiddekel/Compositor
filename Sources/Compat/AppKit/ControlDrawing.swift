import Foundation
import CoreGraphics

// How AppKit's standard controls look, drawn with `draw(_:)` into the current graphics context: what a host shows when it
// draws a view hierarchy itself (a table and its cells). Dark appearance, as the app always uses: text in the label
// colors, symbols in the content tint, a pressed-in bezel for bordered buttons, selected rows in the selection colors.

extension NSView {
    /// Runs `body` in a space whose y grows down from this view's top-left, whichever way the view is flipped.
    func withTopDownSpace(_ body: (CGContext) -> Void) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        if !isFlipped { context.translateBy(x: 0, y: bounds.height); context.scaleBy(x: 1, y: -1) }
        body(context)
        context.restoreGState()
    }

    /// `rect` (this view's coordinates) in the top-down space `withTopDownSpace` sets up.
    func topDown(_ rect: CGRect) -> CGRect {
        isFlipped ? rect : CGRect(x: rect.minX, y: bounds.height - rect.maxY, width: rect.width, height: rect.height)
    }

    /// One line of text in `rect` (top-down space), vertically centered, cut off with an ellipsis when it doesn't fit.
    func drawLine(_ string: String, in rect: CGRect, font: NSFont, color: NSColor, alignment: NSTextAlignment, truncates: Bool) {
        guard !string.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        var shown = string
        var size = (shown as NSString).size(withAttributes: attributes)
        if truncates, size.width > rect.width, rect.width > 0 {
            var characters = Array(string)
            while !characters.isEmpty {
                characters.removeLast()
                shown = String(characters).trimmingCharacters(in: .whitespaces) + "…"
                size = (shown as NSString).size(withAttributes: attributes)
                if size.width <= rect.width { break }
            }
        }
        let x: CGFloat
        switch alignment {
        case .center: x = rect.midX - size.width / 2
        case .right: x = rect.maxX - size.width
        default: x = rect.minX
        }
        (shown as NSString).draw(at: CGPoint(x: x, y: rect.midY - size.height / 2), withAttributes: attributes)
    }

    /// Text wrapped to `rect`'s width (top-down space), from its top.
    func drawWrapped(_ string: String, in rect: CGRect, font: NSFont, color: NSColor, alignment: NSTextAlignment) {
        guard !string.isEmpty else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        let storage = NSTextStorage(attributedString: NSAttributedString(string: string, attributes: [
            .font: font, .foregroundColor: color, .paragraphStyle: paragraph]))
        let layout = NSLayoutManager()
        layout.addTextContainer(NSTextContainer(size: CGSize(width: max(rect.width, 1), height: .greatestFiniteMagnitude)))
        storage.addLayoutManager(layout)
        layout.drawGlyphs(forGlyphRange: NSRange(location: 0, length: (string as NSString).length), at: rect.origin)
    }

    /// `image` fitted into `bounds` (top-down space) as `scaling` says, centered; a symbol or template image drawn in
    /// `tint`.
    func drawImage(_ image: NSImage, in bounds: CGRect, scaling: NSImageScaling, tint: NSColor?, fraction: CGFloat) {
        guard let context = NSGraphicsContext.current?.cgContext, image.size.width > 0, image.size.height > 0 else { return }
        let natural = image.size
        let fit = min(bounds.width / natural.width, bounds.height / natural.height)
        let scale: CGFloat
        switch scaling {
        case .scaleProportionallyUpOrDown: scale = fit
        case .scaleProportionallyDown: scale = min(1, fit)
        case .scaleAxesIndependently: scale = 1
        case .scaleNone: scale = 1
        }
        var rect = CGRect(x: 0, y: 0, width: natural.width * scale, height: natural.height * scale)
        if scaling == .scaleAxesIndependently { rect.size = bounds.size }
        rect.origin = CGPoint(x: bounds.midX - rect.width / 2, y: bounds.midY - rect.height / 2)
        let pixels = CGSize(width: rect.width * 2, height: rect.height * 2)
        let color = tint ?? NSColor.labelColor
        let picture: CGImage?
        if let symbol = image.symbolName, let renderer = NSImage.symbolRenderer {
            picture = renderer(symbol, max(1, Int(pixels.width.rounded())), max(1, Int(pixels.height.rounded())),
                               (Double(color.redComponent), Double(color.greenComponent), Double(color.blueComponent),
                                Double(color.alphaComponent)))
        } else if let bitmap = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            picture = image.isTemplate ? Self.tinted(bitmap, color) : bitmap
        } else {
            picture = nil
        }
        guard let picture else { return }
        // A CGImage draws with its first row at the rect's max y; in top-down space that's upside down.
        context.saveGState()
        context.translateBy(x: 0, y: rect.minY + rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.setAlpha(fraction)
        context.draw(picture, in: rect)
        context.restoreGState()
    }

    /// A template image's shape in `color` (its alpha kept), as AppKit draws template images.
    static func tinted(_ image: CGImage, _ color: NSColor) -> CGImage? {
        let width = image.width, height = image.height
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let r = Double(color.redComponent), g = Double(color.greenComponent), b = Double(color.blueComponent)
        let a = Double(color.alphaComponent)
        for index in 0..<(width * height) {
            let alpha = Double(data[index * 4 + 3]) / 255 * a
            data[index * 4] = UInt8((r * alpha * 255).rounded())
            data[index * 4 + 1] = UInt8((g * alpha * 255).rounded())
            data[index * 4 + 2] = UInt8((b * alpha * 255).rounded())
            data[index * 4 + 3] = UInt8((alpha * 255).rounded())
        }
        return context.makeImage()
    }
}

extension NSTextField {
    func drawField() {
        withTopDownSpace { context in
            let box = CGRect(origin: .zero, size: bounds.size)
            if drawsBackground, let backgroundColor {
                context.setFillColor(backgroundColor.cgColor)
                context.fill(box)
            }
            if isEditable, isBezeled {
                context.setStrokeColor(NSColor.separatorColor.cgColor)
                context.setLineWidth(1)
                context.stroke(box.insetBy(dx: 0.5, dy: 0.5))
            }
            let showsPlaceholder = stringValue.isEmpty && placeholderString != nil
            let text = showsPlaceholder ? placeholderString ?? "" : stringValue
            let color = !isEnabled || showsPlaceholder ? NSColor.tertiaryLabelColor : (textColor ?? .labelColor)
            let inset = box.insetBy(dx: isBezeled && isEditable ? 3 : 2, dy: 0)
            let font = self.font ?? .systemFont(ofSize: 13)
            if maximumNumberOfLines == 1 || usesSingleLineMode || lineBreakMode != .byWordWrapping {
                drawLine(text, in: inset, font: font, color: color, alignment: alignment,
                         truncates: lineBreakMode == .byTruncatingTail || lineBreakMode == .byTruncatingMiddle)
            } else {
                drawWrapped(text, in: inset, font: font, color: color, alignment: alignment)
            }
        }
    }
}

extension NSButton {
    func drawButton() {
        withTopDownSpace { context in
            let box = CGRect(origin: .zero, size: bounds.size)
            let fraction: CGFloat = isEnabled ? 1 : 0.35
            if isBordered {
                let bezel = box.insetBy(dx: 0.5, dy: 0.5)
                let path = CGPath(roundedRect: bezel, cornerWidth: min(6, bezel.height / 2), cornerHeight: min(6, bezel.height / 2), transform: nil)
                context.addPath(path)
                context.setFillColor(NSColor(white: 1, alpha: state == .on ? 0.22 : 0.12 * fraction).cgColor)
                context.fillPath()
            }
            let tint = contentTintColor ?? (isBordered ? NSColor.labelColor : NSColor.secondaryLabelColor)
            let shownImage = state == .on ? (alternateImage ?? image) : image
            let hasTitle = !title.isEmpty && imagePosition != .imageOnly
            if let shownImage {
                let room = hasTitle ? CGRect(x: box.minX + 4, y: box.minY, width: min(box.height, box.width / 3), height: box.height) : box
                drawImage(shownImage, in: room, scaling: imageScaling, tint: tint, fraction: fraction)
            }
            if hasTitle {
                let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
                let titleBox = shownImage == nil ? box : CGRect(x: box.minX + box.height + 4, y: box.minY,
                                                                width: box.width - box.height - 8, height: box.height)
                drawLine(title, in: titleBox, font: font, color: isEnabled ? .labelColor : .tertiaryLabelColor,
                         alignment: shownImage == nil ? .center : .left, truncates: true)
            }
        }
    }
}

extension NSImageView {
    func drawImageView() {
        guard let image else { return }
        withTopDownSpace { _ in
            drawImage(image, in: CGRect(origin: .zero, size: bounds.size), scaling: imageScaling, tint: contentTintColor,
                      fraction: isEnabled ? 1 : 0.35)
        }
    }
}

extension NSTableView {
    /// The selected rows (the accent while the table has the keys, gray otherwise), and where a drag would drop.
    func drawRows() {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        if backgroundColor.alphaComponent > 0 {
            context.setFillColor(backgroundColor.cgColor)
            context.fill(bounds)
        }
        let focused: Bool = {
            var responder = window?.firstResponder
            while let current = responder { if current === self { return true }; responder = current.nextResponder }
            return false
        }()
        let selection = focused ? NSColor.selectedContentBackgroundColor : NSColor.unemphasizedSelectedContentBackgroundColor
        context.setFillColor(selection.cgColor)
        for row in selectedRowIndexes where row < numberOfRows {
            let rect = rect(ofRow: row)
            if let custom = delegate?.tableView(self, rowViewForRow: row) {
                custom.frame = CGRect(origin: .zero, size: rect.size)
                context.saveGState()
                context.translateBy(x: rect.minX, y: rect.minY)
                custom.drawSelection(in: custom.bounds)
                context.restoreGState()
            } else { context.fill(rect) }
        }
        guard showsDropIndicator, dropRow >= 0 else { return }
        context.setStrokeColor(NSColor.controlAccentColor.cgColor)
        context.setLineWidth(2)
        if dropOperation == .on, dropRow < numberOfRows {
            let frame = rect(ofRow: dropRow).insetBy(dx: 2, dy: 1)
            context.addPath(CGPath(roundedRect: frame, cornerWidth: 4, cornerHeight: 4, transform: nil))
            context.strokePath()
        } else {
            let y = dropRow < numberOfRows ? rect(ofRow: dropRow).minY : (rect(ofRow: numberOfRows - 1).maxY + intercellSpacing.height)
            context.move(to: CGPoint(x: 4, y: max(1, y - intercellSpacing.height / 2)))
            context.addLine(to: CGPoint(x: bounds.width - 4, y: max(1, y - intercellSpacing.height / 2)))
            context.strokePath()
        }
    }
}
