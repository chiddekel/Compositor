import Foundation
import CoreGraphics

/// Reuses shared spatial work within one render. No image or parameter survives into the next frame.
final class RasterRenderCache: @unchecked Sendable {
    private struct Key: Hashable {
        let owner: ObjectIdentifier
        let gpu: ObjectIdentifier?
        let linear: Bool
        let region: [UInt64]
    }
    private struct Entry {
        let owner: AnyObject
        let gpu: AnyObject?
        let raster: Raster
        var used: UInt64
    }
    private let lock = NSLock()
    private let byteLimit: Int
    private let sharedNodes: Set<ObjectIdentifier>?
    private var entries: [Key: Entry] = [:]
    private var bytes = 0
    private var clock: UInt64 = 0

    init(byteLimit: Int = 512 * 1024 * 1024, sharedNodes: Set<ObjectIdentifier>? = nil) {
        self.byteLimit = max(0, byteLimit); self.sharedNodes = sharedNodes
    }

    func isShared(_ owner: AnyObject) -> Bool { sharedNodes?.contains(ObjectIdentifier(owner)) != false }

    func raster(for owner: AnyObject, region: CGRect, linear: Bool, gpu: AnyObject?, evaluate: () -> Raster) -> Raster {
        let identity = ObjectIdentifier(owner)
        guard sharedNodes?.contains(identity) != false else { return evaluate() }
        let key = Key(owner: identity, gpu: gpu.map(ObjectIdentifier.init), linear: linear,
            region: [Double(region.minX), Double(region.minY), Double(region.width), Double(region.height)].map(\.bitPattern))
        lock.lock()
        clock += 1
        if var entry = entries[key] {
            entry.used = clock; entries[key] = entry
            lock.unlock()
            return entry.raster
        }
        lock.unlock()
        let result = evaluate()
        let count = result.data.count * MemoryLayout<Float>.stride
        guard count <= byteLimit else { return result }
        lock.lock()
        defer { lock.unlock() }
        if let entry = entries[key] { return entry.raster }
        while entries.count >= 64 || bytes > byteLimit - count {
            guard let oldest = entries.min(by: { $0.value.used < $1.value.used }) else { break }
            bytes -= oldest.value.raster.data.count * MemoryLayout<Float>.stride
            entries.removeValue(forKey: oldest.key)
        }
        clock += 1
        entries[key] = Entry(owner: owner, gpu: gpu, raster: result, used: clock)
        bytes += count
        return result
    }
}

enum RasterRenderScope {
    @TaskLocal static var current: RasterRenderCache?

    static func withCache<Result>(sharedNodes: @autoclosure () -> Set<ObjectIdentifier>, _ body: () -> Result) -> Result {
        if current != nil { return body() }
        return $current.withValue(RasterRenderCache(sharedNodes: sharedNodes()), operation: body)
    }
}
