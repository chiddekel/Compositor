// SwiftUI compat: upstream's model code imports SwiftUI only for a few value-level conveniences (and, on Apple
// platforms, for the Observation re-export). The views themselves are the Qt shell's job.

@_exported import Foundation
@_exported import CoreGraphics
@_exported import Observation
import AppKit

/// The view protocol; upstream's SwiftUI views are not compiled on Linux, but the sheet stand-ins conform to it.
public protocol View {}

/// Carries a root view for `NSWindow.beginSheet`; the Qt shell (or a headless resolver) decides what to show.
@MainActor public final class NSHostingController<Root: View>: NSViewController {
    public var rootView: Root { didSet { representedRootView = rootView } }
    public init(rootView: Root) { self.rootView = rootView; super.init(); representedRootView = rootView }
}

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
