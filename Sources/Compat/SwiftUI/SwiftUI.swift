// SwiftUI compat: upstream's model code imports SwiftUI only for a few value-level conveniences (and, on Apple
// platforms, for the Observation re-export). The views themselves are the Qt shell's job.

@_exported import Foundation
@_exported import CoreGraphics
@_exported import Observation

extension MutableCollection where Self: RangeReplaceableCollection {
    /// SwiftUI's `move(fromOffsets:toOffset:)` used by list reordering (`onMove`): moves the elements at `source`
    /// so that they end up before the element originally at `destination` (or at the end).
    public mutating func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        let moving = source.map { self[index(startIndex, offsetBy: $0)] }
        var remaining: [Element] = []
        var insertAt = 0
        for (offset, element) in self.enumerated() {
            if offset == destination { insertAt = remaining.count }
            if !source.contains(offset) { remaining.append(element) }
        }
        if destination >= count { insertAt = remaining.count }
        remaining.insert(contentsOf: moving, at: insertAt)
        self = Self(remaining)
    }
}
