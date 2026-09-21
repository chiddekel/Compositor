// CoreGraphicsCompat/Context.swift — CGContext shim over the Skia render-device bridge.
//
// Plan §3, §4, §5: CoreGraphics CGContext compatibility class.
// Wraps the Skia Canvas C ABI (CompCanvas) via CompCanvasBridge.
// If the Skia bridge is unavailable or fails, falls back gracefully to pure-Swift rendering.

import Foundation

public final class CGContext: @unchecked Sendable {
    public let width: Int
    public let height: Int
    public var bytesPerRow: Int { width * 4 }

    private let pixelData: UnsafeMutablePointer<UInt8>
    private let pixelCount: Int
    private var rawCanvas: OpaquePointer?
    private let render: CompRenderFn?

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
        var dashLengths: [CGFloat] = []
        var ctm: CGAffineTransform = .identity
    }

    private var state: State = State()
    private var stateStack: [State] = []
    private var currentPath: CGMutablePath = CGMutablePath()

    public var data: UnsafeMutableRawPointer? {
        UnsafeMutableRawPointer(pixelData)
    }

    public var buffer: PixelBuffer {
        let array = [UInt8](UnsafeBufferPointer(start: pixelData, count: pixelCount))
        return PixelBuffer(width: width, height: height, bytes: array)
    }

    public init(width: Int, height: Int, render: CompRenderFn? = nil) {
        precondition(width > 0 && height > 0)
        self.width = width
        self.height = height
        self.pixelCount = width * height * 4
        self.pixelData = UnsafeMutablePointer<UInt8>.allocate(capacity: pixelCount)
        self.pixelData.initialize(repeating: 0, count: pixelCount)
        self.render = render ?? compositor_compat_current_render_fn()

        if let create = CompCanvasBridge.shared.createCanvas {
            self.rawCanvas = create(self.pixelData, width, height, width * 4)
        }
    }

    public convenience init?(data: UnsafeMutableRawPointer?,
                             width: Int,
                             height: Int,
                             bitsPerComponent: Int,
                             bytesPerRow: Int,
                             space: CGColorSpace,
                             bitmapInfo: UInt32) {
        guard width > 0, height > 0 else { return nil }
        self.init(width: width, height: height)
        if let srcData = data {
            memcpy(self.pixelData, srcData, min(self.pixelCount, height * bytesPerRow))
        }
    }

    public init(buffer: PixelBuffer, render: CompRenderFn? = nil) {
        precondition(buffer.width > 0 && buffer.height > 0)
        let w = buffer.width
        let h = buffer.height
        let count = w * h * 4
        self.width = w
        self.height = h
        self.pixelCount = count
        self.render = render ?? compositor_compat_current_render_fn()

        let ptr = UnsafeMutablePointer<UInt8>.allocate(capacity: count)
        _ = buffer.bytes.withUnsafeBufferPointer { srcPtr in
            memcpy(ptr, srcPtr.baseAddress!, min(count, srcPtr.count))
        }
        self.pixelData = ptr

        if let create = CompCanvasBridge.shared.createCanvas {
            self.rawCanvas = create(self.pixelData, w, h, w * 4)
        }
    }

    deinit {
        if let raw = rawCanvas {
            CompCanvasBridge.shared.destroyCanvas?(raw)
        }
        pixelData.deallocate()
    }

    // MARK: - State Management

    public func saveGState() {
        stateStack.append(state)
        if let raw = rawCanvas {
            CompCanvasBridge.shared.save?(raw)
        }
    }

    public func restoreGState() {
        guard let prev = stateStack.popLast() else { return }
        state = prev
        if let raw = rawCanvas {
            CompCanvasBridge.shared.restore?(raw)
        }
    }

    public func setAlpha(_ alpha: CGFloat) {
        state.alpha = alpha
        if let raw = rawCanvas {
            CompCanvasBridge.shared.setAlpha?(raw, Float(alpha))
        }
    }

    public func setBlendMode(_ mode: CGBlendMode) {
        state.blendMode = mode
        if let raw = rawCanvas {
            CompCanvasBridge.shared.setBlendMode?(raw, mode.rawValue)
        }
    }

    public var interpolationQuality: CGInterpolationQuality {
        get { state.interpolationQuality }
        set {
            state.interpolationQuality = newValue
            if let raw = rawCanvas {
                CompCanvasBridge.shared.setInterpolationQuality?(raw, mapQuality(newValue))
            }
        }
    }

    public func setShouldAntialias(_ antialias: Bool) {
        state.shouldAntialias = antialias
        if let raw = rawCanvas {
            CompCanvasBridge.shared.setAntialias?(raw, antialias ? 1 : 0)
        }
    }

    // MARK: - Transforms

    public func translateBy(x: CGFloat, y: CGFloat) {
        state.ctm = state.ctm.translatedBy(x: x, y: y)
        if let raw = rawCanvas {
            CompCanvasBridge.shared.translate?(raw, Float(x), Float(y))
        }
    }

    public func scaleBy(x sx: CGFloat, y sy: CGFloat) {
        state.ctm = state.ctm.scaledBy(x: sx, y: sy)
        if let raw = rawCanvas {
            CompCanvasBridge.shared.scale?(raw, Float(sx), Float(sy))
        }
    }

    public func rotate(by radians: CGFloat) {
        state.ctm = state.ctm.rotated(by: radians)
        if let raw = rawCanvas {
            CompCanvasBridge.shared.rotate?(raw, Float(radians))
        }
    }

    /// Apple's Swift name for `concatCTM`.
    public func concatenate(_ transform: CGAffineTransform) { concatCTM(transform) }

    /// The current transformation matrix (user space to device space).
    public var ctm: CGAffineTransform { userSpaceToDeviceSpaceTransform }

    public func concatCTM(_ transform: CGAffineTransform) {
        state.ctm = state.ctm.concatenating(transform)
        if let raw = rawCanvas {
            CompCanvasBridge.shared.concat?(raw, Float(transform.a), Float(transform.b),
                                           Float(transform.c), Float(transform.d),
                                           Float(transform.tx), Float(transform.ty))
        }
    }

    public var userSpaceToDeviceSpaceTransform: CGAffineTransform {
        if let raw = rawCanvas, let getCTM = CompCanvasBridge.shared.getCTM {
            var a: Float = 1, b: Float = 0, c: Float = 0, d: Float = 1, tx: Float = 0, ty: Float = 0
            getCTM(raw, &a, &b, &c, &d, &tx, &ty)
            return CGAffineTransform(a: CGFloat(a), b: CGFloat(b), c: CGFloat(c), d: CGFloat(d),
                                     tx: CGFloat(tx), ty: CGFloat(ty))
        }
        return state.ctm
    }

    // MARK: - Clipping

    public func clip(to rect: CGRect) {
        if let raw = rawCanvas {
            CompCanvasBridge.shared.clipRect?(raw, Float(rect.minX), Float(rect.minY),
                                             Float(rect.width), Float(rect.height),
                                             state.shouldAntialias ? 1 : 0)
        }
    }

    public func clip(to rect: CGRect, mask: CGImage) {
        if let raw = rawCanvas {
            let pImg = mask.portableImage
            pImg.bytes.withUnsafeBufferPointer { ptr in
                CompCanvasBridge.shared.clipMask?(raw, ptr.baseAddress!, pImg.width, pImg.height,
                                                 pImg.bytesPerRow, Float(rect.minX), Float(rect.minY),
                                                 Float(rect.width), Float(rect.height),
                                                 mask.isMask ? 1 : 0)
            }
        }
    }

    public func clip(using rule: CGPathFillRule = .winding) {
        if let raw = rawCanvas, let clipPath = CompCanvasBridge.shared.clipPath,
           let path = SkiaPathABI.make(currentPath.segments) {
            clipPath(raw, path, rule == .evenOdd ? 1 : 0, state.shouldAntialias ? 1 : 0)
            SkiaPathABI.destroy?(path)
        }
        currentPath = CGMutablePath()
    }

    public var boundingBoxOfClipPath: CGRect {
        if let raw = rawCanvas, let getClip = CompCanvasBridge.shared.getClipBounds {
            var x: Float = 0, y: Float = 0, w: Float = 0, h: Float = 0
            getClip(raw, &x, &y, &w, &h)
            return CGRect(x: CGFloat(x), y: CGFloat(y), width: CGFloat(w), height: CGFloat(h))
        }
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
    /// Recorded for callers that read it back; dashed strokes are not rasterised yet.
    public func setLineDash(phase: CGFloat, lengths: [CGFloat]) { state.dashPhase = phase; state.dashLengths = lengths }

    /// The colour space of the backing bitmap (sRGB, premultiplied RGBA).
    public var colorSpace: CGColorSpace { .srgbSpace }

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
        if let raw = rawCanvas {
            let c = state.fillColor
            CompCanvasBridge.shared.fillRect?(raw, Float(rect.minX), Float(rect.minY),
                                             Float(rect.width), Float(rect.height),
                                             Float(c.red), Float(c.green), Float(c.blue), Float(c.alpha))
        } else {
            fillSwift(rect, color: state.fillColor)
        }
    }

    public func fillPath(using rule: CGPathFillRule = .winding) {
        let path = currentPath
        currentPath = CGMutablePath()
        fill(path, rule: rule)
    }

    /// Fills `path` (user space) with the current fill colour, honouring the clip, alpha and blend mode.
    public func fill(_ path: CGPath, rule: CGPathFillRule = .winding) {
        let c = state.fillColor
        if let raw = rawCanvas, let fillFn = SkiaPathABI.fillPath, let sk = SkiaPathABI.make(path.segments) {
            fillFn(raw, sk, rule == .evenOdd ? 1 : 0, Float(c.red), Float(c.green), Float(c.blue), Float(c.alpha))
            SkiaPathABI.destroy?(sk)
            return
        }
        fillPathSwift(path, rule: rule, color: c)
    }

    public func stroke(_ rect: CGRect) {
        // Simple stroke fallback: stroke rect edges
        let lw = state.lineWidth
        fill(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: lw))
        fill(CGRect(x: rect.minX, y: rect.maxY - lw, width: rect.width, height: lw))
        fill(CGRect(x: rect.minX, y: rect.minY, width: lw, height: rect.height))
        fill(CGRect(x: rect.maxX - lw, y: rect.minY, width: lw, height: rect.height))
    }

    public func strokePath() {
        let path = currentPath
        currentPath = CGMutablePath()
        stroke(path)
    }

    /// Strokes `path` (user space) with the current stroke colour, width, cap, join and miter limit.
    public func stroke(_ path: CGPath) {
        let c = state.strokeColor
        if let raw = rawCanvas, let strokeFn = SkiaPathABI.strokePath, let sk = SkiaPathABI.make(path.segments) {
            strokeFn(raw, sk, Float(state.lineWidth), state.lineCap.rawValue, state.lineJoin.rawValue,
                     Float(state.miterLimit), Float(c.red), Float(c.green), Float(c.blue), Float(c.alpha))
            SkiaPathABI.destroy?(sk)
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
        guard let raw = rawCanvas, let draw = SkiaPathABI.linearGradient else { return }
        let colors = gradient.packedColors, locations = gradient.packedLocations
        draw(raw, Float(start.x), Float(start.y), Float(end.x), Float(end.y),
             colors, locations, locations.count, Int32(options.rawValue))
    }

    public func drawRadialGradient(_ gradient: CGGradient, startCenter: CGPoint, startRadius: CGFloat,
                                   endCenter: CGPoint, endRadius: CGFloat, options: CGGradientDrawingOptions) {
        guard let raw = rawCanvas, let draw = SkiaPathABI.radialGradient else { return }
        let colors = gradient.packedColors, locations = gradient.packedLocations
        draw(raw, Float(startCenter.x), Float(startCenter.y), Float(startRadius),
             Float(endCenter.x), Float(endCenter.y), Float(endRadius),
             colors, locations, locations.count, Int32(options.rawValue))
    }

    public func strokeEllipse(in rect: CGRect) {
        stroke(rect)
    }

    public func clear(_ rect: CGRect) {
        if let raw = rawCanvas {
            CompCanvasBridge.shared.clear?(raw, Float(rect.minX), Float(rect.minY),
                                          Float(rect.width), Float(rect.height))
        } else {
            clearSwift(rect)
        }
    }

    // MARK: - Drawing Images

    public func draw(_ image: CGImage, in rect: CGRect, opacity: Double = 1) {
        let finalOpacity = opacity * Double(state.alpha)
        if let raw = rawCanvas {
            let pImg = image.portableImage
            pImg.bytes.withUnsafeBufferPointer { ptr in
                CompCanvasBridge.shared.drawImageRect?(raw, ptr.baseAddress!, pImg.width, pImg.height,
                                                      pImg.bytesPerRow, Float(rect.minX), Float(rect.minY),
                                                      Float(rect.width), Float(rect.height),
                                                      Float(finalOpacity), state.blendMode.rawValue,
                                                      mapQuality(state.interpolationQuality))
            }
            return
        }

        // Check injected render closure fallback
        if finalOpacity >= 1, rect.origin == .zero,
           rect.width == CGFloat(image.width),
           rect.height == CGFloat(image.height),
           let render = self.render {
            let pImg = image.portableImage
            let rc = pImg.bytes.withUnsafeBufferPointer { srcPtr in
                render(srcPtr.baseAddress!, self.pixelData, pImg.width, pImg.height)
            }
            if rc == 0 { return }
        }

        drawSwift(image.portableImage, in: rect, opacity: finalOpacity)
    }

    public func draw(_ image: PortableImage, in rect: CGRect, opacity: Double = 1) {
        draw(CGImage(image), in: rect, opacity: opacity)
    }

    // MARK: - Transparency Layers

    public func beginTransparencyLayer(auxiliaryInfo: [AnyHashable: Any]? = nil) {
        saveGState()
        if let raw = rawCanvas {
            CompCanvasBridge.shared.beginTransparencyLayer?(raw, Float(state.alpha))
        }
    }

    public func endTransparencyLayer() {
        if let raw = rawCanvas {
            CompCanvasBridge.shared.endTransparencyLayer?(raw)
        }
        restoreGState()
    }

    // MARK: - Output

    public func makeImage() -> CGImage? {
        CGImage(buffer)
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
        guard let softwareDraw = CGContext.softwareDraw else { return }
        var tempBuffer = self.buffer
        softwareDraw(image, rect, opacity, &tempBuffer)
        _ = tempBuffer.bytes.withUnsafeBufferPointer { srcPtr in
            memcpy(self.pixelData, srcPtr.baseAddress!, pixelCount)
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