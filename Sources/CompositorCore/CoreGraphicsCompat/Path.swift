// CoreGraphicsCompat/Path.swift — CGPath and CGMutablePath shims.
//
// Plan §3, §4, §5: Wraps the C ABI CompPath (backed by Skia SkPathBuilder)
// and tracks path contours for clipping and drawing.

import Foundation

// MARK: - CGPathFillRule

public enum CGPathFillRule: Sendable {
    case winding
    case evenOdd
}

// MARK: - CGPath Element

public enum CGPathElement: Sendable, Equatable {
    case moveTo(CGPoint)
    case lineTo(CGPoint)
    case addRect(CGRect)
    case addEllipse(CGRect)
    case closeSubpath
}

// MARK: - CGPath

public class CGPath: @unchecked Sendable {
    var elements: [CGPathElement]
    var subtractions: [CGPath]
    var rawPath: OpaquePointer?

    public var isEmpty: Bool {
        elements.isEmpty && subtractions.isEmpty
    }

    public var boundingBox: CGRect {
        if elements.isEmpty { return .zero }
        var minX = CGFloat.infinity, minY = CGFloat.infinity
        var maxX = -CGFloat.infinity, maxY = -CGFloat.infinity

        for el in elements {
            switch el {
            case .moveTo(let p), .lineTo(let p):
                minX = min(minX, p.x); minY = min(minY, p.y)
                maxX = max(maxX, p.x); maxY = max(maxY, p.y)
            case .addRect(let r), .addEllipse(let r):
                minX = min(minX, r.minX); minY = min(minY, r.minY)
                maxX = max(maxX, r.maxX); maxY = max(maxY, r.maxY)
            case .closeSubpath:
                break
            }
        }
        guard minX.isFinite, minY.isFinite, maxX.isFinite, maxY.isFinite else { return .zero }
        return CGRect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
    }

    public init() {
        self.elements = []
        self.subtractions = []
        self.rawPath = CompCanvasBridge.shared.pathCreate?()
    }

    public init(rect: CGRect, transform: [CGAffineTransform]? = nil) {
        self.elements = []
        self.subtractions = []
        self.rawPath = CompCanvasBridge.shared.pathCreate?()
        let t = transform?.first
        if let t = t {
            let p1 = CGPoint(x: rect.minX, y: rect.minY).applying(t)
            let p2 = CGPoint(x: rect.maxX, y: rect.minY).applying(t)
            let p3 = CGPoint(x: rect.maxX, y: rect.maxY).applying(t)
            let p4 = CGPoint(x: rect.minX, y: rect.maxY).applying(t)
            elements.append(.moveTo(p1))
            elements.append(.lineTo(p2))
            elements.append(.lineTo(p3))
            elements.append(.lineTo(p4))
            elements.append(.closeSubpath)
            if let p = rawPath, let bridge = CompCanvasBridge.shared.pathMoveTo {
                bridge(p, Float(p1.x), Float(p1.y))
                CompCanvasBridge.shared.pathLineTo?(p, Float(p2.x), Float(p2.y))
                CompCanvasBridge.shared.pathLineTo?(p, Float(p3.x), Float(p3.y))
                CompCanvasBridge.shared.pathLineTo?(p, Float(p4.x), Float(p4.y))
                CompCanvasBridge.shared.pathClose?(p)
            }
        } else {
            elements.append(.addRect(rect))
            if let p = rawPath {
                CompCanvasBridge.shared.pathAddRect?(p, Float(rect.minX), Float(rect.minY), Float(rect.width), Float(rect.height))
            }
        }
    }

    public init(ellipseIn rect: CGRect, transform: [CGAffineTransform]? = nil) {
        self.elements = []
        self.subtractions = []
        self.rawPath = CompCanvasBridge.shared.pathCreate?()
        elements.append(.addEllipse(rect))
        if let p = rawPath {
            let cx = rect.midX, cy = rect.midY
            let rx = rect.width / 2, ry = rect.height / 2
            CompCanvasBridge.shared.pathAddEllipse?(p, Float(cx), Float(cy), Float(rx), Float(ry))
        }
    }

    init(elements: [CGPathElement], subtractions: [CGPath], rawPath: OpaquePointer?) {
        self.elements = elements
        self.subtractions = subtractions
        self.rawPath = rawPath
    }

    deinit {
        if let p = rawPath {
            CompCanvasBridge.shared.pathDestroy?(p)
        }
    }

    public func copy() -> CGPath {
        let newPath = CompCanvasBridge.shared.pathCreate?()
        if let newPath = newPath {
            replay(into: newPath)
        }
        return CGPath(elements: elements, subtractions: subtractions, rawPath: newPath)
    }

    public func mutableCopy() -> CGMutablePath {
        let newPath = CompCanvasBridge.shared.pathCreate?()
        if let newPath = newPath {
            replay(into: newPath)
        }
        let m = CGMutablePath()
        m.elements = self.elements
        m.subtractions = self.subtractions
        if let old = m.rawPath {
            CompCanvasBridge.shared.pathDestroy?(old)
        }
        m.rawPath = newPath
        return m
    }

    public func subtracting(_ other: CGPath, using rule: CGPathFillRule = .winding) -> CGPath {
        let newPath = self.copy()
        newPath.subtractions.append(other)
        return newPath
    }

    func replay(into raw: OpaquePointer) {
        let bridge = CompCanvasBridge.shared
        for el in elements {
            switch el {
            case .moveTo(let pt):
                bridge.pathMoveTo?(raw, Float(pt.x), Float(pt.y))
            case .lineTo(let pt):
                bridge.pathLineTo?(raw, Float(pt.x), Float(pt.y))
            case .addRect(let r):
                bridge.pathAddRect?(raw, Float(r.minX), Float(r.minY), Float(r.width), Float(r.height))
            case .addEllipse(let r):
                let cx = r.midX, cy = r.midY, rx = r.width / 2, ry = r.height / 2
                bridge.pathAddEllipse?(raw, Float(cx), Float(cy), Float(rx), Float(ry))
            case .closeSubpath:
                bridge.pathClose?(raw)
            }
        }
    }
}

// MARK: - CGMutablePath

public final class CGMutablePath: CGPath, @unchecked Sendable {
    public override init() {
        super.init()
    }

    public func move(to point: CGPoint) {
        elements.append(.moveTo(point))
        if let p = rawPath {
            CompCanvasBridge.shared.pathMoveTo?(p, Float(point.x), Float(point.y))
        }
    }

    public func addLine(to point: CGPoint) {
        elements.append(.lineTo(point))
        if let p = rawPath {
            CompCanvasBridge.shared.pathLineTo?(p, Float(point.x), Float(point.y))
        }
    }

    public func addRect(_ rect: CGRect) {
        elements.append(.addRect(rect))
        if let p = rawPath {
            CompCanvasBridge.shared.pathAddRect?(p, Float(rect.minX), Float(rect.minY), Float(rect.width), Float(rect.height))
        }
    }

    public func addRects(_ rects: [CGRect]) {
        for r in rects { addRect(r) }
    }

    public func addEllipse(in rect: CGRect) {
        elements.append(.addEllipse(rect))
        if let p = rawPath {
            let cx = rect.midX, cy = rect.midY
            let rx = rect.width / 2, ry = rect.height / 2
            CompCanvasBridge.shared.pathAddEllipse?(p, Float(cx), Float(cy), Float(rx), Float(ry))
        }
    }

    public func addPath(_ path: CGPath) {
        elements.append(contentsOf: path.elements)
        subtractions.append(contentsOf: path.subtractions)
        if let p = rawPath {
            path.replay(into: p)
        }
    }

    public func closeSubpath() {
        elements.append(.closeSubpath)
        if let p = rawPath {
            CompCanvasBridge.shared.pathClose?(p)
        }
    }
}
