// CoreGraphicsCompat/Context.swift — CGContext shim over the Skia render-device bridge.
//
// Plan §3, §4, §5: CoreGraphics CGContext compatibility class.
// Draws through a `CanvasBackend` (Skia by default; see CanvasBackend.swift), with pure-Swift fallbacks.
// If the Skia bridge is unavailable or fails, falls back gracefully to pure-Swift rendering.

import Foundation

public final class CGContext: @unchecked Sendable {
    /// Backing pixel layout. Contexts made with Apple's `CGContext(data:...)` initialiser follow the colour space:
    /// a gray space gives a one-byte-per-pixel plane (what upstream's masks and C kernels expect).
    /// `rgba16` and `rgbaHalf` are Apple's 64-bit RGBA bitmaps (16 bits a component, unsigned or half floats), for
    /// 16-bit and HDR layers.
    public enum PixelFormat: Sendable {
        case rgba, gray, rgba16, rgbaHalf
        var bytesPerPixel: Int { switch self { case .gray: 1; case .rgba: 4; case .rgba16, .rgbaHalf: 8 } }
        /// The Skia bridge's code for the layout (SkiaBridge.h).
        var bridgeCode: Int32 { switch self { case .rgba: 0; case .gray: 1; case .rgba16: 2; case .rgbaHalf: 3 } }
        var depth: PortableImage.Depth { switch self { case .rgba16: .uint16; case .rgbaHalf: .half; default: .uint8 } }
        var isDeep: Bool { self == .rgba16 || self == .rgbaHalf }
    }

    public let width: Int
    public let height: Int
    public let format: PixelFormat
    public let bytesPerRow: Int
    /// Apple bitmap contexts have their origin at the bottom-left (y up); the compat's own initialisers keep the
    /// top-left origin the Linux core was written against.
    public let isYUp: Bool

    private let pixelData: UnsafeMutablePointer<UInt8>
    private let pixelCount: Int
    /// The rasterizer drawing into `pixelData`; nil when no backend can serve this context (Swift fallbacks then run).
    private var canvas: CanvasBackend?
    private let render: CompRenderFn?
    private var externalData: UnsafeMutableRawPointer?
    private var externalBytesPerRow: Int = 0

    private struct State {
        var alpha: CGFloat = 1.0
        var blendMode: CGBlendMode = .normal
        var interpolationQuality: CGInterpolationQuality = .default
        var shouldAntialias: Bool = true
        var fillColor: CGColor = .black
        var strokeColor: CGColor = .black
        var lineWidth: CGFloat = 1.0
        var lineCap: CGLineCap = .butt
        var lineJoin: CGLineJoin = .miter
        var miterLimit: CGFloat = 10
        var dashPhase: CGFloat = 0
        var shadowOffset = CGSize.zero
        var shadowBlur: CGFloat = 0
        var shadowColor: CGColor? = nil
        var dashLengths: [CGFloat] = []
        var ctm: CGAffineTransform = .identity
    }

    private var state: State = State()
    private var stateStack: [State] = []
    private var currentPath: CGMutablePath = CGMutablePath()

    public var data: UnsafeMutableRawPointer? {
        syncToExternalData()
        return externalData ?? UnsafeMutableRawPointer(pixelData)
    }

    /// Matches Apple's bitmap-context layout flag; used when copying pixels byte-for-byte from a CGImage.
    public var bitmapInfo: CGBitmapInfo {
        CGBitmapInfo(rawValue: (format == .gray ? CGImageAlphaInfo.none : CGImageAlphaInfo.premultipliedLast).rawValue
            | (format.isDeep ? CGBitmapInfo.byteOrder16Little.rawValue : 0)
            | (format == .rgbaHalf ? CGBitmapInfo.floatComponents.rawValue : 0))
    }
    public var bitsPerComponent: Int { format.isDeep ? 16 : 8 }
    public var bitsPerPixel: Int { format.bytesPerPixel * 8 }
    /// The colour space of the backing bitmap: sRGB (extended sRGB for half floats), gray for a gray plane.
    public var colorSpace: CGColorSpace? {
        format == .gray ? .deviceGraySpace : format == .rgbaHalf ? .extendedSRGBSpace : .srgbSpace
    }

    public var buffer: PixelBuffer {
        if format.isDeep {
            let native = Array(UnsafeBufferPointer(start: pixelData, count: pixelCount))
            let eight = PortableImage(width: width, height: height, kind: .rgba, depth: format.depth, bytesPerRow: bytesPerRow,
                                      bytes: native).eightBit
            return PixelBuffer(width: width, height: height, bytes: eight.bytes)
        }
        if format == .gray {
            // Legacy RGBA view of a gray plane (opaque, r = g = b).
            var expanded = [UInt8](repeating: 255, count: width * height * 4)
            for i in 0..<(width * height) { let v = pixelData[i]; expanded[i * 4] = v; expanded[i * 4 + 1] = v; expanded[i * 4 + 2] = v }
            return PixelBuffer(width: width, height: height, bytes: expanded)
        }
        let array = Array<UInt8>(unsafeUninitializedCapacity: pixelCount) { buf, initializedCount in
            memcpy(buf.baseAddress!, pixelData, pixelCount)
            initializedCount = pixelCount
        }
        return PixelBuffer(width: width, height: height, bytes: array)
    }

    public convenience init(width: Int, height: Int, render: CompRenderFn? = nil) {
        self.init(width: width, height: height, format: .rgba, yUp: false, render: render)
    }

    init(width: Int, height: Int, format: PixelFormat, yUp: Bool, render: CompRenderFn? = nil) {
        precondition(width > 0 && height > 0)
        self.width = width
        self.height = height
        self.format = format
        self.isYUp = yUp
        self.bytesPerRow = width * format.bytesPerPixel
        self.pixelCount = bytesPerRow * height
        // calloc: large blocks come straight from the kernel already zeroed, so a new context (upstream makes one per
        // halving, render and export — hundreds of MB for big layers) costs nothing until it is drawn into. The
        // runtime's deallocate frees malloc'd memory on Linux (swift_slowDealloc -> free for default alignment).
        guard let zeroed = calloc(pixelCount, 1) else { fatalError("CGContext: out of memory (\(pixelCount) bytes)") }
        self.pixelData = zeroed.assumingMemoryBound(to: UInt8.self)
        self.render = render ?? compositor_compat_current_render_fn()
        makeCanvas()
    }

    private func makeCanvas() {
        canvas = CanvasBackends.make(pixels: pixelData, width: width, height: height, bytesPerRow: bytesPerRow, format: format)
        // The flip lives below the visible CTM: user space is y-up, memory rows still run top-down.
        if isYUp {
            canvas?.translate(0, Float(height))
            canvas?.scale(1, -1)
        }
    }

    /// Apple's bitmap-context initialiser. The colour space picks the pixel layout (gray -> one byte per pixel,
    /// otherwise RGBA) and the origin is bottom-left, as in CoreGraphics.
    public convenience init?(data: UnsafeMutableRawPointer?,
                             width: Int,
                             height: Int,
                             bitsPerComponent: Int,
                             bytesPerRow: Int,
                             space: CGColorSpace,
                             bitmapInfo: UInt32) {
        guard width > 0, height > 0, bitsPerComponent == 8 || (bitsPerComponent == 16 && space.model != .monochrome) else { return nil }
        let format: PixelFormat = space.model == .monochrome ? .gray
            : bitsPerComponent == 16 ? (CGBitmapInfo(rawValue: bitmapInfo).contains(.floatComponents) ? .rgbaHalf : .rgba16) : .rgba
        self.init(width: width, height: height, format: format, yUp: true)
        // 16-bit pixels are drawn by the canvas backend only (no pure-Swift fallback at that depth).
        if format.isDeep, canvas == nil { return nil }
        if let srcData = data {
            self.externalData = srcData
            self.externalBytesPerRow = bytesPerRow
            let rowLength = self.bytesPerRow
            for y in 0..<height { memcpy(pixelData.advanced(by: y * rowLength), srcData.advanced(by: y * bytesPerRow), min(rowLength, bytesPerRow)) }
        }
    }

    public init(buffer: PixelBuffer, render: CompRenderFn? = nil) {
        precondition(buffer.width > 0 && buffer.height > 0)
        let w = buffer.width
        let h = buffer.height
        let count = w * h * 4
        self.width = w
        self.height = h
        self.format = .rgba
        self.isYUp = false
        self.bytesPerRow = w * 4
        self.pixelCount = count
        self.render = render ?? compositor_compat_current_render_fn()

        let ptr = UnsafeMutablePointer<UInt8>.allocate(capacity: count)
        _ = buffer.bytes.withUnsafeBufferPointer { srcPtr in
            memcpy(ptr, srcPtr.baseAddress!, min(count, srcPtr.count))
        }
        self.pixelData = ptr

        self.canvas = CanvasBackends.make(pixels: ptr, width: w, height: h, bytesPerRow: w * 4, format: .rgba)
    }

    deinit {
        canvas = nil   // the backend must stop drawing before its pixel memory goes
        syncToExternalData()
        pixelData.deallocate()
    }

    public func flush() {
        syncToExternalData()
    }

    public func syncToExternalData() {
        guard let dstData = externalData else { return }
        let rowLength = self.bytesPerRow
        for y in 0..<height {
            memcpy(dstData.advanced(by: y * externalBytesPerRow), pixelData.advanced(by: y * rowLength), min(rowLength, externalBytesPerRow))
        }
    }

    // MARK: - State Management

    public func saveGState() {
        stateStack.append(state)
        canvas?.save()
    }

    public func restoreGState() {
        guard let prev = stateStack.popLast() else { return }
        state = prev
        canvas?.restore()
    }

    public func setAlpha(_ alpha: CGFloat) {
        state.alpha = alpha
        canvas?.setAlpha(Float(alpha))
    }

    public func setBlendMode(_ mode: CGBlendMode) {
        state.blendMode = mode
        canvas?.setBlendMode(mode.rawValue)
    }

    /// Where the next text drawn (CTLineDraw) puts its baseline origin, in user space.
    public var textPosition: CGPoint = .zero
    public var interpolationQuality: CGInterpolationQuality {
        get { state.interpolationQuality }
        set {
            state.interpolationQuality = newValue
            canvas?.setInterpolationQuality(mapQuality(newValue))
        }
    }

    public func setShouldAntialias(_ antialias: Bool) {
        state.shouldAntialias = antialias
        canvas?.setAntialias(antialias)
    }

    // MARK: - Transforms

    public func translateBy(x: CGFloat, y: CGFloat) {
        state.ctm = state.ctm.translatedBy(x: x, y: y)
        canvas?.translate(Float(x), Float(y))
    }

    public func scaleBy(x sx: CGFloat, y sy: CGFloat) {
        state.ctm = state.ctm.scaledBy(x: sx, y: sy)
        canvas?.scale(Float(sx), Float(sy))
    }

    public func rotate(by radians: CGFloat) {
        state.ctm = state.ctm.rotated(by: radians)
        canvas?.rotate(Float(radians))
    }

    /// Apple's Swift name for `concatCTM`.
    public func concatenate(_ transform: CGAffineTransform) { concatCTM(transform) }

    /// The current transformation matrix (user space to device space).
    public var ctm: CGAffineTransform { userSpaceToDeviceSpaceTransform }

    public func concatCTM(_ transform: CGAffineTransform) {
        state.ctm = transform.concatenating(state.ctm)
        canvas?.concat(transform)
    }

    public var userSpaceToDeviceSpaceTransform: CGAffineTransform {
        if isYUp { return state.ctm }   // the y flip is below the visible CTM, as in CoreGraphics
        return canvas?.totalMatrix ?? state.ctm
    }

    // MARK: - Clipping

    public func clip(to rect: CGRect) {
        canvas?.clip(rect: rect, antialias: state.shouldAntialias)
    }

    public func clip(to rect: CGRect, mask: CGImage) {
        if let canvas {
            let pImg = mask.portableImage
            var bytes = pImg.bytes
            if isYUp {
                // The mask's first row belongs at the rect's top edge (max y in y-up space): reverse the rows.
                let row = pImg.bytesPerRow
                var flipped = [UInt8](repeating: 0, count: bytes.count)
                for y in 0..<pImg.height { flipped.replaceSubrange((y * row)..<((y + 1) * row), with: bytes[((pImg.height - 1 - y) * row)..<((pImg.height - y) * row)]) }
                bytes = flipped
            }
            canvas.clip(mask: bytes, width: pImg.width, height: pImg.height, stride: pImg.bytesPerRow, rect: rect,
                        isGray: mask.isGrayPlane)
        }
    }

    public func clip(using rule: CGPathFillRule = .winding) {
        canvas?.clip(path: currentPath.segments, evenOdd: rule == .evenOdd, antialias: state.shouldAntialias)
        currentPath = CGMutablePath()
    }

    public var boundingBoxOfClipPath: CGRect {
        if let bounds = canvas?.clipBounds, !bounds.isNull { return bounds }
        return CGRect(x: 0, y: 0, width: width, height: height)
    }

    // MARK: - Paths

    public func beginPath() { currentPath = CGMutablePath() }
    public func closePath() { currentPath.closeSubpath() }
    public func move(to point: CGPoint) { currentPath.move(to: point) }
    public func addLine(to point: CGPoint) { currentPath.addLine(to: point) }
    public func addLines(between points: [CGPoint]) { currentPath.addLines(between: points) }
    public func addQuadCurve(to end: CGPoint, control: CGPoint) { currentPath.addQuadCurve(to: end, control: control) }
    public func addCurve(to end: CGPoint, control1: CGPoint, control2: CGPoint) {
        currentPath.addCurve(to: end, control1: control1, control2: control2)
    }
    public func addRect(_ rect: CGRect) { currentPath.addRect(rect) }
    public func addEllipse(in rect: CGRect) { currentPath.addEllipse(in: rect) }
    public func addPath(_ path: CGPath) { currentPath.addPath(path) }

    public func setLineCap(_ cap: CGLineCap) { state.lineCap = cap }
    /// Dashed strokes are cut into their "on" runs when stroked (see `dashed`).
    public func setLineDash(phase: CGFloat, lengths: [CGFloat]) { state.dashPhase = phase; state.dashLengths = lengths }

    /// A shadow under what is drawn next, as Core Graphics casts it: `offset` and `blur` in user units, the blur a
    /// Gaussian of half its size. Without a color, black at a third opacity. Rendered for rect fills (`fill(_:)`),
    /// the only shape the canvas casts one from.
    public func setShadow(offset: CGSize, blur: CGFloat, color: CGColor? = CGColor(gray: 0, alpha: 1.0 / 3)) {
        state.shadowOffset = offset; state.shadowBlur = blur; state.shadowColor = color
    }
    /// The path under construction (Apple exposes it as `path`).
    public var path: CGPath? { currentPath.isEmpty ? nil : currentPath }
    public func convertToDeviceSpace(_ rect: CGRect) -> CGRect { rect.applying(state.ctm) }
    public func beginTransparencyLayer(in rect: CGRect, auxiliaryInfo: [AnyHashable: Any]? = nil) { beginTransparencyLayer(auxiliaryInfo: auxiliaryInfo) }
    public func convertToDeviceSpace(_ point: CGPoint) -> CGPoint { point.applying(state.ctm) }
    public func convertToUserSpace(_ point: CGPoint) -> CGPoint { point.applying(state.ctm.inverted()) }

    public func drawPath(using mode: CGPathDrawingMode) {
        let path = currentPath
        switch mode {
        case .fill, .eoFill, .fillStroke, .eoFillStroke:
            fill(path, rule: (mode == .eoFill || mode == .eoFillStroke) ? .evenOdd : .winding)
        case .stroke: break
        }
        if mode == .stroke || mode == .fillStroke || mode == .eoFillStroke { stroke(path) }
        currentPath = CGMutablePath()
    }
    public func setLineJoin(_ join: CGLineJoin) { state.lineJoin = join }
    public func setMiterLimit(_ limit: CGFloat) { state.miterLimit = limit }

    // MARK: - Painting & Colors

    public func setFillColor(gray: CGFloat, alpha: CGFloat) {
        state.fillColor = CGColor(gray: gray, alpha: alpha)
    }

    public func setFillColor(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        state.fillColor = CGColor(red: red, green: green, blue: blue, alpha: alpha)
    }

    public func setFillColor(_ color: CGColor) {
        state.fillColor = color
    }

    public func setStrokeColor(_ color: CGColor) {
        state.strokeColor = color
    }

    public func setLineWidth(_ width: CGFloat) {
        state.lineWidth = width
    }

    public func fill(_ rect: CGRect) {
        castShadow(of: rect)
        if let canvas, !state.shouldAntialias, fillsThroughClip {
            fillHardEdged(rect, on: canvas)
        } else if let canvas {
            canvas.fill(rect: rect, color: state.fillColor)
        } else {
            fillSwift(rect, color: state.fillColor)
        }
    }

    /// Fills each rect independently, as Apple's `fill(_ rects: [CGRect])` does (not their union).
    public func fill(_ rects: [CGRect]) {
        for rect in rects { fill(rect) }
    }

    /// A hard-edged rect fill under a rotated or skewed transform. Skia rounds an aliased fill's edge differently from an
    /// aliased clip's, and Core Graphics does not: a fill and a clip to the same rect cover the same pixels. Code that
    /// clears a region and then draws into a clip of it (upstream's tiled renderer) depends on that, or a seam pixel is
    /// drawn without having been cleared. Filling through a clip built from the same path as `clip(to:)` restores it.
    private var fillsThroughClip: Bool {
        let t = userSpaceToDeviceSpaceTransform
        return abs(t.b) > 1e-9 || abs(t.c) > 1e-9
    }

    private func fillHardEdged(_ rect: CGRect, on canvas: CanvasBackend) {
        canvas.save()
        canvas.clip(path: CGPath(rect: rect).segments, evenOdd: false, antialias: false)
        // Everything the clip leaves is the rect: fill a rect that covers all of it.
        canvas.fill(rect: boundingBoxOfClipPath.insetBy(dx: -2, dy: -2), color: state.fillColor)
        canvas.restore()
    }

    public func fillPath(using rule: CGPathFillRule = .winding) {
        let path = currentPath
        currentPath = CGMutablePath()
        fill(path, rule: rule)
    }

    /// Fills `path` (user space) with the current fill colour, honouring the clip, alpha and blend mode.
    public func fill(_ path: CGPath, rule: CGPathFillRule = .winding) {
        let c = state.fillColor
        if let canvas {
            canvas.fill(path: path.segments, evenOdd: rule == .evenOdd, color: c)
            return
        }
        fillPathSwift(path, rule: rule, color: c)
    }

    /// The rect's outline in the stroke color and width, centered on its edges, as `stroke(CGPath(rect:))`.
    public func stroke(_ rect: CGRect) {
        stroke(CGPath(rect: rect, transform: nil))
    }

    /// The current shadow of a filled `rect`: the rect moved by the offset and blurred, in the shadow color. A
    /// Gaussian-blurred rectangle is a product of two error-function steps, so it is computed directly, at device
    /// resolution, and drawn as an image before the fill.
    private func castShadow(of rect: CGRect) {
        guard let color = state.shadowColor, color.alpha > 0, state.shadowBlur > 0 || state.shadowOffset != .zero,
              rect.width > 0, rect.height > 0 else { return }
        let ctm = userSpaceToDeviceSpaceTransform
        guard abs(ctm.b) < 1e-9, abs(ctm.c) < 1e-9 else { return }   // axis-aligned only, as the canvas draws it
        let sigma = state.shadowBlur / 2
        let cast = rect.offsetBy(dx: state.shadowOffset.width, dy: state.shadowOffset.height)
        let area = cast.insetBy(dx: -3 * sigma, dy: -3 * sigma)
        let sx = abs(ctm.a), sy = abs(ctm.d)
        let width = Int(ceil(area.width * sx)), height = Int(ceil(area.height * sy))
        guard width > 0, height > 0, width * height <= 64_000_000,
              let image = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
              let data = image.data else { return }
        // Coverage of the blurred rect along one axis at a pixel center, in user units.
        func coverage(_ u: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
            guard sigma > 0 else { return u >= lo && u < hi ? 1 : 0 }
            let k = 1 / (sigma * 2.0.squareRoot())
            return (erf((hi - u) * k) - erf((lo - u) * k)) / 2
        }
        let across = (0..<width).map { coverage(area.minX + (CGFloat($0) + 0.5) / sx, cast.minX, cast.maxX) }
        let down = (0..<height).map { coverage(area.minY + (CGFloat($0) + 0.5) / sy, cast.minY, cast.maxY) }
        let r = color.red, g = color.green, b = color.blue, a = color.alpha
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        // The image's rows run along the area's y, symmetric enough that either drawing direction lands the same.
        for y in 0..<height {
            for x in 0..<width {
                let alpha = a * across[x] * down[y], i = (y * width + x) * 4
                bytes[i] = UInt8((r * alpha * 255).rounded()); bytes[i + 1] = UInt8((g * alpha * 255).rounded())
                bytes[i + 2] = UInt8((b * alpha * 255).rounded()); bytes[i + 3] = UInt8((alpha * 255).rounded())
            }
        }
        guard let shadow = image.makeImage() else { return }
        let saved = (state.shadowOffset, state.shadowBlur, state.shadowColor)
        state.shadowOffset = .zero; state.shadowBlur = 0; state.shadowColor = nil
        draw(shadow, in: CGRect(x: area.minX, y: area.minY, width: CGFloat(width) / sx, height: CGFloat(height) / sy))
        (state.shadowOffset, state.shadowBlur, state.shadowColor) = saved
    }

    public func strokePath() {
        let path = currentPath
        currentPath = CGMutablePath()
        stroke(path)
    }

    /// The "on" parts of `segments` under a dash pattern: curves flattened to lines, the pattern restarting (at `phase`)
    /// with each subpath.
    static func dashed(_ segments: [PathSegment], lengths: [CGFloat], phase: CGFloat) -> [PathSegment] {
        var polylines: [[CGPoint]] = []
        var current: [CGPoint] = []
        var start = CGPoint.zero
        func point(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint { CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t) }
        for segment in segments {
            switch segment {
            case .move(let p):
                if current.count > 1 { polylines.append(current) }
                current = [p]; start = p
            case .line(let p): current.append(p)
            case .quad(let c, let p):
                guard let from = current.last else { current = [p]; continue }
                for i in 1...16 { let t = CGFloat(i) / 16; current.append(point(point(from, c, t), point(c, p, t), t)) }
            case .cubic(let c1, let c2, let p):
                guard let from = current.last else { current = [p]; continue }
                for i in 1...24 {
                    let t = CGFloat(i) / 24
                    let a = point(from, c1, t), b = point(c1, c2, t), c = point(c2, p, t)
                    current.append(point(point(a, b, t), point(b, c, t), t))
                }
            case .close:
                if !current.isEmpty { current.append(start); polylines.append(current); current = [start] }
            }
        }
        if current.count > 1 { polylines.append(current) }
        let total = lengths.reduce(0, +)
        var result: [PathSegment] = []
        for line in polylines {
            // Where in the pattern the subpath starts.
            var offset = phase.truncatingRemainder(dividingBy: total)
            if offset < 0 { offset += total }
            var index = 0
            while offset >= lengths[index] { offset -= lengths[index]; index = (index + 1) % lengths.count }
            var remaining = lengths[index] - offset
            var on = index % 2 == 0
            if on { result.append(.move(line[0])) }
            for k in 1..<line.count {
                var a = line[k - 1]
                let b = line[k]
                var length = hypot(b.x - a.x, b.y - a.y)
                while length > 0 {
                    let step = min(remaining, length)
                    let t = step / length
                    let p = point(a, b, t)
                    if on { result.append(.line(p)) }
                    length -= step
                    remaining -= step
                    a = p
                    if remaining <= 0.0001 {
                        index = (index + 1) % lengths.count
                        remaining = lengths[index]
                        on = index % 2 == 0
                        if on { result.append(.move(p)) }
                    }
                }
            }
        }
        return result
    }

    /// Strokes `path` (user space) with the current stroke colour, width, cap, join and miter limit.
    public func stroke(_ path: CGPath) {
        // A dash pattern (setLineDash) cuts the outline into its "on" runs first, as Core Graphics does, in user space.
        if !state.dashLengths.isEmpty, state.dashLengths.reduce(0, +) > 0 {
            let dashed = Self.dashed(path.segments, lengths: state.dashLengths, phase: state.dashPhase)
            let saved = state.dashLengths
            state.dashLengths = []
            defer { state.dashLengths = saved }
            stroke(CGPath(segments: dashed))
            return
        }
        let c = state.strokeColor
        if let canvas {
            canvas.stroke(path: path.segments, width: Float(state.lineWidth), cap: state.lineCap.rawValue,
                          join: state.lineJoin.rawValue, miterLimit: Float(state.miterLimit), color: c)
            return
        }
        let outline = path.copy(strokingWithWidth: state.lineWidth, lineCap: state.lineCap,
                                lineJoin: state.lineJoin, miterLimit: state.miterLimit)
        fillPathSwift(outline, rule: .winding, color: c)
    }

    public func fillEllipse(in rect: CGRect) {
        currentPath.addEllipse(in: rect)
        fillPath()
    }

    // MARK: - Gradients

    public func drawLinearGradient(_ gradient: CGGradient, start: CGPoint, end: CGPoint,
                                   options: CGGradientDrawingOptions) {
        canvas?.linearGradient(gradient, from: start, to: end, options: Int32(options.rawValue))
    }

    public func drawRadialGradient(_ gradient: CGGradient, startCenter: CGPoint, startRadius: CGFloat,
                                   endCenter: CGPoint, endRadius: CGFloat, options: CGGradientDrawingOptions) {
        canvas?.radialGradient(gradient, from: startCenter, startRadius: Float(startRadius), to: endCenter,
                               endRadius: Float(endRadius), options: Int32(options.rawValue))
    }

    public func strokeEllipse(in rect: CGRect) {
        stroke(CGPath(ellipseIn: rect))
    }

    public func clear(_ rect: CGRect) {
        if let canvas {
            canvas.clear(rect: rect)
        } else {
            clearSwift(rect)
        }
    }

    // MARK: - Drawing Images

    public func draw(_ image: CGImage, in rect: CGRect, opacity: Double = 1) {
        // PDF contexts record the full-resolution image (media box is in points, often ≪ pixels).
        if PDFRecording.noteDrawIfNeeded(self, image: image, in: rect) { return }
        if let canvas {
            // The canvas already holds setAlpha's graphics state. Pass only the per-draw
            // opacity; multiplying here as well would square the context alpha in Skia.
            // In y-up user space an image's first row sits at the rect's top edge (max y): draw it through a local flip.
            if isYUp {
                saveGState()
                translateBy(x: rect.minX, y: rect.maxY)
                scaleBy(x: 1, y: -1)
                drawRaw(canvas, image, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height), opacity: opacity)
                restoreGState()
            } else {
                drawRaw(canvas, image, in: rect, opacity: opacity)
            }
            return
        }
        guard format == .rgba else { return }
        let finalOpacity = opacity * Double(state.alpha)
        // Software path must honor CTM (ExportTests scales then drawPDFPage into a point-sized media box).
        let device = Self.bounds(of: rect, under: state.ctm)

        // Check injected render closure fallback (Vulkan CompRenderer when activated).
        if finalOpacity >= 1, device.origin == .zero,
           device.width == CGFloat(image.width),
           device.height == CGFloat(image.height),
           let render = self.render {
            let pImg = image.portableImage
            let rc = pImg.bytes.withUnsafeBufferPointer { srcPtr -> Int32 in
                return render(srcPtr.baseAddress!, self.pixelData, pImg.width, pImg.height,
                              state.blendMode.rawValue)
            }
            if rc == 0 { return }
        }

        drawSwift(image.portableImage, in: device, opacity: finalOpacity)
    }

    private static func bounds(of rect: CGRect, under t: CGAffineTransform) -> CGRect {
        let p0 = CGPoint(x: rect.minX, y: rect.minY).applying(t)
        let p1 = CGPoint(x: rect.maxX, y: rect.minY).applying(t)
        let p2 = CGPoint(x: rect.minX, y: rect.maxY).applying(t)
        let p3 = CGPoint(x: rect.maxX, y: rect.maxY).applying(t)
        let xs = [p0.x, p1.x, p2.x, p3.x], ys = [p0.y, p1.y, p2.y, p3.y]
        let minX = xs.min()!, maxX = xs.max()!, minY = ys.min()!, maxY = ys.max()!
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Device-space blit used by `drawPDFPage` after applying the CTM to the media box.
    func drawPDFImage(_ image: CGImage, mediaBox: CGRect) {
        guard format == .rgba else { return }
        let device = Self.bounds(of: mediaBox, under: state.ctm)
        // PortableImage rows are top-down, matching `makeImage` / `NSBitmapImageRep.colorAt`.
        drawSwift(image.portableImage, in: device, opacity: Double(state.alpha))
    }

    /// `opacity` is the caller's own; the context's alpha is applied by the backend from its tracked state.
    private func drawRaw(_ canvas: CanvasBackend, _ image: CGImage, in rect: CGRect, opacity: Double) {
        if image.supportsRegionRendering, rect.width > 0, rect.height > 0,
           state.shadowBlur == 0, state.shadowOffset == .zero, !canvas.clipBounds.isNull {
            let visible = canvas.clipBounds.intersection(rect)
            guard !visible.isNull, !visible.isEmpty else { return }
            let sx = CGFloat(image.width) / rect.width, sy = CGFloat(image.height) / rect.height
            // Two source pixels retain the interpolation kernel at the cropped edge.
            let source = CGRect(x: (visible.minX - rect.minX) * sx, y: (visible.minY - rect.minY) * sy,
                                width: visible.width * sx, height: visible.height * sy)
                .insetBy(dx: -2, dy: -2).integral
                .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            guard let cropped = image.cropping(to: source) else { return }
            let placed = CGRect(x: rect.minX + source.minX / sx, y: rect.minY + source.minY / sy,
                                width: source.width / sx, height: source.height / sy)
            canvas.draw(image: cropped.nativeImage.drawable, isGray: cropped.isGrayPlane, in: placed, opacity: Float(opacity),
                        blendMode: state.blendMode.rawValue, quality: mapQuality(state.interpolationQuality))
            return
        }
        canvas.draw(image: image.nativeImage.drawable, isGray: image.isGrayPlane, in: rect, opacity: Float(opacity),
                    blendMode: state.blendMode.rawValue, quality: mapQuality(state.interpolationQuality))
    }

    public func draw(_ image: PortableImage, in rect: CGRect, opacity: Double = 1) {
        draw(CGImage(image), in: rect, opacity: opacity)
    }

    // MARK: - Transparency Layers

    public func beginTransparencyLayer(auxiliaryInfo: [AnyHashable: Any]? = nil) {
        saveGState()
        canvas?.beginLayer(alpha: Float(state.alpha))
    }

    public func endTransparencyLayer() {
        canvas?.endLayer()
        restoreGState()
    }

    // MARK: - Output

    public func makeImage() -> CGImage? {
        syncToExternalData()
        if format == .gray || format.isDeep {
            let plane = Array<UInt8>(unsafeUninitializedCapacity: pixelCount) { buf, initializedCount in
                memcpy(buf.baseAddress!, pixelData, pixelCount)
                initializedCount = pixelCount
            }
            return CGImage(PortableImage(width: width, height: height, kind: format == .gray ? .mask : .rgba, depth: format.depth,
                                         bytesPerRow: bytesPerRow, bytes: plane))
        }
        return CGImage(buffer)
    }

    // MARK: - Swift Fallbacks

    private func fillSwift(_ rect: CGRect, color: CGColor) {
        let r = UInt8(clamping: Int(color.red * 255))
        let g = UInt8(clamping: Int(color.green * 255))
        let b = UInt8(clamping: Int(color.blue * 255))
        let a = UInt8(clamping: Int(color.alpha * state.alpha * 255))
        let ix = max(0, Int(rect.minX)), iy = max(0, Int(rect.minY))
        let iw = min(width - ix, Int(rect.width)), ih = min(height - iy, Int(rect.height))
        guard iw > 0 && ih > 0 else { return }

        for y in iy..<(iy + ih) {
            for x in ix..<(ix + iw) {
                let off = (y * width + x) * 4
                pixelData[off] = r
                pixelData[off + 1] = g
                pixelData[off + 2] = b
                pixelData[off + 3] = a
            }
        }
    }

    /// Software path fill: 4x4 supersampled coverage through `CGPath.contains`, source-over with the fill alpha.
    /// Used only when no render device is bound; ignores clipping and blend modes beyond source-over.
    private func fillPathSwift(_ path: CGPath, rule: CGPathFillRule, color: CGColor) {
        guard !path.isEmpty else { return }
        let device = state.ctm == .identity ? path : (path.copy(using: [state.ctm]) ?? path)
        let bounds = device.boundingBoxOfPath
        guard !bounds.isNull else { return }
        let x0 = max(0, Int(floor(bounds.minX))), x1 = min(width, Int(ceil(bounds.maxX)))
        let y0 = max(0, Int(floor(bounds.minY))), y1 = min(height, Int(ceil(bounds.maxY)))
        guard x0 < x1, y0 < y1 else { return }
        let a = Double(color.alpha * state.alpha)
        let premul = [Double(color.red) * a, Double(color.green) * a, Double(color.blue) * a, a]
        for y in y0..<y1 {
            for x in x0..<x1 {
                var hits = 0
                for sy in 0..<4 { for sx in 0..<4 {
                    if device.contains(CGPoint(x: CGFloat(x) + (CGFloat(sx) + 0.5) / 4, y: CGFloat(y) + (CGFloat(sy) + 0.5) / 4), using: rule) { hits += 1 }
                } }
                guard hits > 0 else { continue }
                let cov = Double(hits) / 16
                let off = (y * width + x) * 4
                let inv = 1 - premul[3] * cov
                for i in 0..<4 {
                    let dst = Double(pixelData[off + i])
                    pixelData[off + i] = UInt8(max(0, min(255, (premul[i] * cov * 255 + dst * inv).rounded())))
                }
            }
        }
    }

    private func clearSwift(_ rect: CGRect) {
        let ix = max(0, Int(rect.minX)), iy = max(0, Int(rect.minY))
        let iw = min(width - ix, Int(rect.width)), ih = min(height - iy, Int(rect.height))
        guard iw > 0 && ih > 0 else { return }

        for y in iy..<(iy + ih) {
            let rowOff = (y * width + ix) * 4
            memset(pixelData.advanced(by: rowOff), 0, iw * 4)
        }
    }

    /// Pure-Swift software drawing used when no render device is bound. The compat module has no knowledge of
    /// the document domain, so whoever links a renderer installs it (see `CompositorCore.installSoftwareRasterizer`).
    public typealias SoftwareDraw = (_ image: PortableImage, _ rect: CGRect, _ opacity: Double, _ into: inout PixelBuffer) -> Void
    nonisolated(unsafe) public static var softwareDraw: SoftwareDraw?

    private func drawSwift(_ image: PortableImage, in rect: CGRect, opacity: Double) {
        if let softwareDraw = CGContext.softwareDraw {
            var tempBuffer = self.buffer
            softwareDraw(image, rect, opacity, &tempBuffer)
            _ = tempBuffer.bytes.withUnsafeBufferPointer { srcPtr in
                memcpy(self.pixelData, srcPtr.baseAddress!, pixelCount)
            }
            return
        }
        // Built-in nearest-neighbor blit when no host rasterizer is installed (CompatTests, PDF redraw).
        guard format == .rgba, rect.width > 0, rect.height > 0, image.width > 0, image.height > 0 else { return }
        let dstX0 = max(0, Int(floor(rect.minX)))
        let dstY0 = max(0, Int(floor(rect.minY)))
        let dstX1 = min(width, Int(ceil(rect.maxX)))
        let dstY1 = min(height, Int(ceil(rect.maxY)))
        guard dstX0 < dstX1, dstY0 < dstY1 else { return }
        let src = image.bytes
        let sbpr = image.bytesPerRow
        let spp = image.kind == .rgba ? 4 : 1
        let op = max(0, min(1, opacity))
        for dy in dstY0..<dstY1 {
            let v = (Double(dy) + 0.5 - Double(rect.minY)) / Double(rect.height)
            let sy = min(image.height - 1, max(0, Int(v * Double(image.height))))
            for dx in dstX0..<dstX1 {
                let u = (Double(dx) + 0.5 - Double(rect.minX)) / Double(rect.width)
                let sx = min(image.width - 1, max(0, Int(u * Double(image.width))))
                let si = sy * sbpr + sx * spp
                let di = (dy * width + dx) * 4
                let sr: UInt8, sg: UInt8, sb: UInt8, sa: UInt8
                if spp == 4 {
                    sr = src[si]; sg = src[si + 1]; sb = src[si + 2]; sa = src[si + 3]
                } else {
                    sr = src[si]; sg = src[si]; sb = src[si]; sa = 255
                }
                let a = Double(sa) / 255 * op
                if a <= 0 { continue }
                if a >= 1 {
                    pixelData[di] = sr; pixelData[di + 1] = sg; pixelData[di + 2] = sb; pixelData[di + 3] = sa
                } else {
                    let inv = 1 - a
                    pixelData[di] = UInt8(Double(pixelData[di]) * inv + Double(sr) * a)
                    pixelData[di + 1] = UInt8(Double(pixelData[di + 1]) * inv + Double(sg) * a)
                    pixelData[di + 2] = UInt8(Double(pixelData[di + 2]) * inv + Double(sb) * a)
                    pixelData[di + 3] = UInt8(min(255, Double(pixelData[di + 3]) * inv + Double(sa) * op))
                }
            }
        }
    }

    private func mapQuality(_ q: CGInterpolationQuality) -> Int32 {
        switch q {
        case .none: return 1
        case .low: return 2
        case .medium: return 3
        case .high: return 4
        case .default: return 0
        }
    }
}

public enum CGPathDrawingMode: Int32, Sendable { case fill, eoFill, stroke, fillStroke, eoFillStroke }

public typealias CGContextCompat = CGContext
