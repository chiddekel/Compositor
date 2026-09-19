import Foundation

extension PortablePath {
    func contains(_ point: CGPoint) -> Bool {
        switch self {
        case .rectangle(let rect): return rect.contains(point)
        case .ellipse(let rect):
            guard rect.width > 0, rect.height > 0 else { return false }
            let x = (point.x - rect.midX) / (rect.width / 2), y = (point.y - rect.midY) / (rect.height / 2)
            return x * x + y * y <= 1
        case .roundedRect(let rect, let cornerRadius):
            guard rect.contains(point) else { return false }
            let r = min(max(0, cornerRadius), min(rect.width, rect.height) / 2)
            let x = max(0, abs(point.x - rect.midX) - (rect.width / 2 - r))
            let y = max(0, abs(point.y - rect.midY) - (rect.height / 2 - r))
            return x * x + y * y <= r * r
        case .polygon(let points):
            guard points.count >= 3 else { return false }
            var inside = false
            var previous = points.last!
            for current in points {
                if (current.y > point.y) != (previous.y > point.y),
                   point.x < (previous.x - current.x) * (point.y - current.y) / (previous.y - current.y) + current.x {
                    inside.toggle()
                }
                previous = current
            }
            return inside
        }
    }
}

extension DocumentSelection {
    func rasterized(in region: CGRect) -> MaskBuffer {
        var mask = MaskBuffer(width: Int(region.width), height: Int(region.height))
        let steps = antialiased ? 4 : 1
        for y in 0..<mask.height {
            for x in 0..<mask.width {
                var hits = 0
                for sy in 0..<steps { for sx in 0..<steps {
                    let point = CGPoint(x: region.minX + CGFloat(x) + (CGFloat(sx) + 0.5) / CGFloat(steps),
                                        y: region.minY + CGFloat(y) + (CGFloat(sy) + 0.5) / CGFloat(steps))
                    if path.contains(point) { hits += 1 }
                } }
                mask[x, y] = UInt8((hits * 255 + steps * steps / 2) / (steps * steps))
            }
        }
        return mask
    }
}
