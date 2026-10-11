import Foundation
import CoreGraphics

// Auto Layout, as far as AppKit views built in code use it: anchors, equality constraints with a constant (and a
// multiplier on dimensions), layout guides and stack views. A view lays out its own subviews and guides from the
// active constraints that involve them, by propagation: a constraint whose one side is known fixes the other, and
// any two of an item's minimum, maximum, center and size fix the rest. That covers constraint sets that are not
// circular, which is what row and control layouts are; inequalities and priorities below required are ignored.
// An item a constraint leaves unsized takes its intrinsic size, then its current frame.

/// Something constraints can position: a view or a layout guide.
@MainActor public protocol NSLayoutItem: AnyObject {
    var layoutFrame: CGRect { get set }
    /// The view whose bounds this item's frame is measured in.
    var layoutContainer: NSView? { get }
}

@MainActor open class NSLayoutAnchor<AnchorType: AnyObject> {
    public enum Attribute: Sendable { case leading, trailing, left, right, top, bottom, centerX, centerY, width, height }
    weak var item: NSLayoutItem?
    let attribute: Attribute
    init(item: NSLayoutItem, attribute: Attribute) { self.item = item; self.attribute = attribute }

    public func constraint(equalTo anchor: NSLayoutAnchor<AnchorType>, constant c: CGFloat = 0) -> NSLayoutConstraint {
        NSLayoutConstraint(first: self, relation: .equal, second: anchor, multiplier: 1, constant: c)
    }
    public func constraint(greaterThanOrEqualTo anchor: NSLayoutAnchor<AnchorType>, constant c: CGFloat = 0) -> NSLayoutConstraint {
        NSLayoutConstraint(first: self, relation: .greaterThanOrEqual, second: anchor, multiplier: 1, constant: c)
    }
    public func constraint(lessThanOrEqualTo anchor: NSLayoutAnchor<AnchorType>, constant c: CGFloat = 0) -> NSLayoutConstraint {
        NSLayoutConstraint(first: self, relation: .lessThanOrEqual, second: anchor, multiplier: 1, constant: c)
    }
}
public final class NSLayoutXAxisAnchor: NSLayoutAnchor<NSLayoutXAxisAnchor> {}
public final class NSLayoutYAxisAnchor: NSLayoutAnchor<NSLayoutYAxisAnchor> {}
public final class NSLayoutDimension: NSLayoutAnchor<NSLayoutDimension> {
    public func constraint(equalToConstant c: CGFloat) -> NSLayoutConstraint {
        NSLayoutConstraint(first: self, relation: .equal, second: nil, multiplier: 1, constant: c)
    }
    public func constraint(greaterThanOrEqualToConstant c: CGFloat) -> NSLayoutConstraint {
        NSLayoutConstraint(first: self, relation: .greaterThanOrEqual, second: nil, multiplier: 1, constant: c)
    }
    public func constraint(lessThanOrEqualToConstant c: CGFloat) -> NSLayoutConstraint {
        NSLayoutConstraint(first: self, relation: .lessThanOrEqual, second: nil, multiplier: 1, constant: c)
    }
    public func constraint(equalTo anchor: NSLayoutDimension, multiplier m: CGFloat, constant c: CGFloat = 0) -> NSLayoutConstraint {
        NSLayoutConstraint(first: self, relation: .equal, second: anchor, multiplier: m, constant: c)
    }
}

public enum NSUserInterfaceLayoutOrientation: Int, Sendable { case horizontal = 0, vertical = 1 }

@MainActor public final class NSLayoutConstraint {
    public enum Relation: Int, Sendable { case lessThanOrEqual = -1, equal = 0, greaterThanOrEqual = 1 }
    public enum Attribute: Int, Sendable {
        case left = 1, right, top, bottom, leading, trailing, width, height, centerX, centerY, lastBaseline, firstBaseline
        case notAnAttribute = 0
    }
    public struct Priority: RawRepresentable, Hashable, Sendable, ExpressibleByFloatLiteral {
        public let rawValue: Float
        public init(rawValue: Float) { self.rawValue = rawValue }
        public init(_ rawValue: Float) { self.rawValue = rawValue }
        public init(floatLiteral value: Float) { rawValue = value }
        public static let required = Priority(1000), defaultHigh = Priority(750), defaultLow = Priority(250)
        public static let dragThatCanResizeWindow = Priority(510), windowSizeStayPut = Priority(500)
        public static let fittingSizeCompression = Priority(50)
    }

    let firstAttribute: AnyAnchor
    let secondAttribute: AnyAnchor?
    public let relation: Relation
    public let multiplier: CGFloat
    public var constant: CGFloat { didSet { invalidate() } }
    public var priority: Priority = .required { didSet { invalidate() } }
    public var identifier: String?
    public var isActive = false {
        didSet {
            guard isActive != oldValue else { return }
            if isActive { Self.active.append(self) } else { Self.active.removeAll { $0 === self } }
            invalidate()
        }
    }

    /// Every active constraint; views pick theirs when they lay out.
    static var active: [NSLayoutConstraint] = []

    init<T>(first: NSLayoutAnchor<T>, relation: Relation, second: NSLayoutAnchor<T>?, multiplier: CGFloat, constant: CGFloat) {
        firstAttribute = AnyAnchor(first)
        secondAttribute = second.map(AnyAnchor.init)
        self.relation = relation
        self.multiplier = multiplier
        self.constant = constant
    }

    public static func activate(_ constraints: [NSLayoutConstraint]) { constraints.forEach { $0.isActive = true } }
    public static func deactivate(_ constraints: [NSLayoutConstraint]) { constraints.forEach { $0.isActive = false } }

    private func invalidate() {
        for anchor in [firstAttribute, secondAttribute].compactMap({ $0 }) {
            guard let item = anchor.item else { continue }
            (item.layoutContainer ?? item as? NSView)?.needsLayout = true
        }
    }

    /// An anchor without its axis type, for the solver.
    @MainActor struct AnyAnchor {
        weak var item: NSLayoutItem?
        let attribute: NSLayoutAnchor<NSLayoutXAxisAnchor>.Attribute
        init<T>(_ anchor: NSLayoutAnchor<T>) {
            item = anchor.item
            attribute = NSLayoutAnchor<NSLayoutXAxisAnchor>.Attribute(anchor.attribute)
        }
    }
}

extension NSLayoutAnchor<NSLayoutXAxisAnchor>.Attribute {
    init<T>(_ other: NSLayoutAnchor<T>.Attribute) {
        switch other {
        case .leading: self = .leading
        case .trailing: self = .trailing
        case .left: self = .left
        case .right: self = .right
        case .top: self = .top
        case .bottom: self = .bottom
        case .centerX: self = .centerX
        case .centerY: self = .centerY
        case .width: self = .width
        case .height: self = .height
        }
    }
}

/// A rectangle constraints position without a view behind it.
@MainActor open class NSLayoutGuide: NSLayoutItem {
    public init() {}
    public internal(set) weak var owningView: NSView?
    public var identifier = NSUserInterfaceItemIdentifier("")
    public internal(set) var frame: CGRect = .zero
    public var layoutFrame: CGRect { get { frame } set { frame = newValue } }
    public var layoutContainer: NSView? { owningView }
    public var leadingAnchor: NSLayoutXAxisAnchor { NSLayoutXAxisAnchor(item: self, attribute: .leading) }
    public var trailingAnchor: NSLayoutXAxisAnchor { NSLayoutXAxisAnchor(item: self, attribute: .trailing) }
    public var leftAnchor: NSLayoutXAxisAnchor { NSLayoutXAxisAnchor(item: self, attribute: .left) }
    public var rightAnchor: NSLayoutXAxisAnchor { NSLayoutXAxisAnchor(item: self, attribute: .right) }
    public var centerXAnchor: NSLayoutXAxisAnchor { NSLayoutXAxisAnchor(item: self, attribute: .centerX) }
    public var topAnchor: NSLayoutYAxisAnchor { NSLayoutYAxisAnchor(item: self, attribute: .top) }
    public var bottomAnchor: NSLayoutYAxisAnchor { NSLayoutYAxisAnchor(item: self, attribute: .bottom) }
    public var centerYAnchor: NSLayoutYAxisAnchor { NSLayoutYAxisAnchor(item: self, attribute: .centerY) }
    public var widthAnchor: NSLayoutDimension { NSLayoutDimension(item: self, attribute: .width) }
    public var heightAnchor: NSLayoutDimension { NSLayoutDimension(item: self, attribute: .height) }
}

extension NSView: NSLayoutItem {
    public var layoutFrame: CGRect { get { frame } set { if frame != newValue { frame = newValue } } }
    public var layoutContainer: NSView? { superview }
    public var leadingAnchor: NSLayoutXAxisAnchor { NSLayoutXAxisAnchor(item: self, attribute: .leading) }
    public var trailingAnchor: NSLayoutXAxisAnchor { NSLayoutXAxisAnchor(item: self, attribute: .trailing) }
    public var leftAnchor: NSLayoutXAxisAnchor { NSLayoutXAxisAnchor(item: self, attribute: .left) }
    public var rightAnchor: NSLayoutXAxisAnchor { NSLayoutXAxisAnchor(item: self, attribute: .right) }
    public var centerXAnchor: NSLayoutXAxisAnchor { NSLayoutXAxisAnchor(item: self, attribute: .centerX) }
    public var topAnchor: NSLayoutYAxisAnchor { NSLayoutYAxisAnchor(item: self, attribute: .top) }
    public var bottomAnchor: NSLayoutYAxisAnchor { NSLayoutYAxisAnchor(item: self, attribute: .bottom) }
    public var centerYAnchor: NSLayoutYAxisAnchor { NSLayoutYAxisAnchor(item: self, attribute: .centerY) }
    public var firstBaselineAnchor: NSLayoutYAxisAnchor { NSLayoutYAxisAnchor(item: self, attribute: .top) }
    public var widthAnchor: NSLayoutDimension { NSLayoutDimension(item: self, attribute: .width) }
    public var heightAnchor: NSLayoutDimension { NSLayoutDimension(item: self, attribute: .height) }

    public var layoutGuides: [NSLayoutGuide] { layoutGuideStorage[ObjectIdentifier(self)] ?? [] }
    public func addLayoutGuide(_ guide: NSLayoutGuide) {
        guide.owningView = self
        layoutGuideStorage[ObjectIdentifier(self), default: []].append(guide)
        needsLayout = true
    }
    public func removeLayoutGuide(_ guide: NSLayoutGuide) {
        layoutGuideStorage[ObjectIdentifier(self)]?.removeAll { $0 === guide }
    }
    /// The active constraints that involve this view's own anchors or its subviews' and guides'.
    public var constraints: [NSLayoutConstraint] {
        NSLayoutConstraint.active.filter { constraint in
            [constraint.firstAttribute, constraint.secondAttribute].contains { anchor in
                guard let item = anchor?.item else { return false }
                return item === self || item.layoutContainer === self
            }
        }
    }
    public func setContentHuggingPriority(_ priority: NSLayoutConstraint.Priority, for orientation: NSLayoutConstraint.Orientation) {}
    public func setContentCompressionResistancePriority(_ priority: NSLayoutConstraint.Priority,
                                                        for orientation: NSLayoutConstraint.Orientation) {}

    /// Positions the subviews and guides that constraints place (those with
    /// `translatesAutoresizingMaskIntoConstraints` off), in this view's bounds.
    func solveConstraints() {
        // Only what this view lays out: constraints entirely among itself and its own subviews and guides. One that
        // places it among its siblings is its superview's to solve, in the superview's space.
        let mine = constraints.filter { constraint in
            [constraint.firstAttribute, constraint.secondAttribute].allSatisfy { anchor in
                guard let item = anchor?.item else { return true }
                return item === self || item.layoutContainer === self
            }
        }
        guard !mine.isEmpty else { return }
        var solver = LayoutSolver(container: self)
        solver.solve(mine)
    }
}

extension NSLayoutConstraint {
    public enum Orientation: Int, Sendable { case horizontal = 0, vertical = 1 }
}

/// Per item, per axis: minimum, maximum, center and size, each known or not.
@MainActor private struct LayoutSolver {
    struct Axis { var min, max, center, size: CGFloat? }
    struct Item { var x = Axis(), y = Axis(); let item: NSLayoutItem }
    let container: NSView
    var items: [ObjectIdentifier: Item] = [:]

    init(container: NSView) { self.container = container }

    private func isContainer(_ item: NSLayoutItem) -> Bool { item === container }

    /// The value of an anchor of the container (its bounds), or of an item solved so far.
    private func value(_ anchor: NSLayoutConstraint.AnyAnchor) -> CGFloat? {
        guard let item = anchor.item else { return nil }
        if isContainer(item) {
            // y runs top down here whether the view is flipped or not, as Auto Layout's does.
            let b = container.bounds
            switch anchor.attribute {
            case .leading, .left: return b.minX
            case .trailing, .right: return b.maxX
            case .centerX: return b.midX
            case .width: return b.width
            case .top: return 0
            case .bottom: return b.height
            case .centerY: return b.height / 2
            case .height: return b.height
            }
        }
        guard let entry = items[ObjectIdentifier(item)] else { return nil }
        let (axis, part) = slot(anchor.attribute)
        let a = axis == 0 ? entry.x : entry.y
        switch part { case 0: return a.min; case 1: return a.max; case 2: return a.center; default: return a.size }
    }

    /// Which axis (0 x, 1 y) and part (0 min, 1 max, 2 center, 3 size) an attribute names; y is top down.
    private func slot(_ attribute: NSLayoutAnchor<NSLayoutXAxisAnchor>.Attribute) -> (Int, Int) {
        switch attribute {
        case .leading, .left: return (0, 0)
        case .trailing, .right: return (0, 1)
        case .centerX: return (0, 2)
        case .width: return (0, 3)
        case .top: return (1, 0)
        case .bottom: return (1, 1)
        case .centerY: return (1, 2)
        case .height: return (1, 3)
        }
    }

    /// Sets an item's anchor; false when it was already known (or belongs to the container, which is fixed).
    private mutating func set(_ anchor: NSLayoutConstraint.AnyAnchor, _ newValue: CGFloat) -> Bool {
        guard let item = anchor.item, !isContainer(item) else { return false }
        let key = ObjectIdentifier(item)
        guard var entry = items[key] else { return false }
        let (axis, part) = slot(anchor.attribute)
        var a = axis == 0 ? entry.x : entry.y
        switch part {
        case 0: guard a.min == nil else { return false }; a.min = newValue
        case 1: guard a.max == nil else { return false }; a.max = newValue
        case 2: guard a.center == nil else { return false }; a.center = newValue
        default: guard a.size == nil else { return false }; a.size = newValue
        }
        if axis == 0 { entry.x = a } else { entry.y = a }
        items[key] = entry
        return true
    }

    private static func complete(_ a: inout Axis) -> Bool {
        var changed = false
        func fill(_ slot: inout CGFloat?, _ value: CGFloat?) { if slot == nil, let value { slot = value; changed = true } }
        if let lo = a.min, let hi = a.max { fill(&a.size, hi - lo); fill(&a.center, (lo + hi) / 2) }
        if let lo = a.min, let s = a.size { fill(&a.max, lo + s); fill(&a.center, lo + s / 2) }
        if let hi = a.max, let s = a.size { fill(&a.min, hi - s); fill(&a.center, hi - s / 2) }
        if let c = a.center, let s = a.size { fill(&a.min, c - s / 2); fill(&a.max, c + s / 2) }
        if let c = a.center, let lo = a.min { fill(&a.size, (c - lo) * 2); fill(&a.max, 2 * c - lo) }
        if let c = a.center, let hi = a.max { fill(&a.size, (hi - c) * 2); fill(&a.min, 2 * c - hi) }
        return changed
    }

    private mutating func propagate(_ constraints: [NSLayoutConstraint]) {
        for _ in 0..<32 {
            var changed = false
            for c in constraints where c.relation == .equal && c.priority == .required {
                if let second = c.secondAttribute {
                    if let v = value(second), value(c.firstAttribute) == nil {
                        changed = set(c.firstAttribute, v * c.multiplier + c.constant) || changed
                    } else if let v = value(c.firstAttribute), value(second) == nil, c.multiplier != 0 {
                        changed = set(second, (v - c.constant) / c.multiplier) || changed
                    }
                } else if value(c.firstAttribute) == nil {
                    changed = set(c.firstAttribute, c.constant) || changed
                }
            }
            for key in Array(items.keys) {
                var entry = items[key]!
                let x = Self.complete(&entry.x), y = Self.complete(&entry.y)
                if x || y { items[key] = entry; changed = true }
            }
            if !changed { return }
        }
    }

    mutating func solve(_ constraints: [NSLayoutConstraint]) {
        for c in constraints {
            for anchor in [c.firstAttribute, c.secondAttribute].compactMap({ $0 }) {
                guard let item = anchor.item, !isContainer(item), items[ObjectIdentifier(item)] == nil else { continue }
                if let view = item as? NSView, view.translatesAutoresizingMaskIntoConstraints { continue }
                items[ObjectIdentifier(item)] = Item(item: item)
            }
        }
        propagate(constraints)
        // Unsized items take their intrinsic size, then their current one; then whatever that lets the constraints fix.
        for key in Array(items.keys) {
            var entry = items[key]!
            let current = entry.item.layoutFrame
            let intrinsic = (entry.item as? NSView)?.intrinsicContentSize ?? NSSize(width: -1, height: -1)
            if entry.x.size == nil { entry.x.size = intrinsic.width >= 0 ? intrinsic.width : current.width }
            if entry.y.size == nil { entry.y.size = intrinsic.height >= 0 ? intrinsic.height : current.height }
            items[key] = entry
        }
        propagate(constraints)
        // Back from top-down y to the container's own coordinates.
        let flipped = container.isFlipped, height = container.bounds.height
        for (_, entry) in items {
            let current = entry.item.layoutFrame
            let width = max(0, entry.x.size ?? current.width), itemHeight = max(0, entry.y.size ?? current.height)
            let x = entry.x.min ?? current.minX
            let top = entry.y.min ?? (flipped ? current.minY : height - current.maxY)
            let y = flipped ? top : height - top - itemHeight
            entry.item.layoutFrame = CGRect(x: x, y: y, width: width, height: itemHeight)
        }
    }
}

/// Guides per view, outside the class so the view's stored layout stays untouched.
@MainActor private var layoutGuideStorage: [ObjectIdentifier: [NSLayoutGuide]] = [:]

/// A row or column of views, laid out in order with `spacing` between them.
@MainActor open class NSStackView: NSView {
    public enum Distribution: Int, Sendable { case gravityAreas = -1, fill = 0, fillEqually, fillProportionally, equalSpacing, equalCentering }
    public var orientation: NSUserInterfaceLayoutOrientation = .horizontal { didSet { needsLayout = true } }
    public var alignment: NSLayoutConstraint.Attribute = .centerY
    public var distribution: Distribution = .gravityAreas
    public var spacing: CGFloat = 8 { didSet { needsLayout = true } }
    public var edgeInsets = NSEdgeInsets()
    public private(set) var arrangedSubviews: [NSView] = []

    public convenience init(views: [NSView]) {
        self.init(frame: .zero)
        views.forEach(addArrangedSubview)
    }

    public func addArrangedSubview(_ view: NSView) {
        arrangedSubviews.append(view)
        if view.superview !== self { addSubview(view) }
        needsLayout = true
    }
    public func insertArrangedSubview(_ view: NSView, at index: Int) {
        arrangedSubviews.insert(view, at: min(index, arrangedSubviews.count))
        if view.superview !== self { addSubview(view) }
        needsLayout = true
    }
    public func removeArrangedSubview(_ view: NSView) {
        arrangedSubviews.removeAll { $0 === view }
        needsLayout = true
    }

    private var visibleArranged: [NSView] { arrangedSubviews.filter { !$0.isHidden && $0.superview === self } }

    private func extent(of view: NSView) -> CGSize {
        let intrinsic = view.intrinsicContentSize
        // A height or width constant fixes the view's size along the stack, as Auto Layout would.
        func fixed(_ attribute: NSLayoutAnchor<NSLayoutXAxisAnchor>.Attribute) -> CGFloat? {
            NSLayoutConstraint.active.first {
                $0.firstAttribute.item === view && $0.firstAttribute.attribute == attribute && $0.secondAttribute == nil
                    && $0.relation == .equal
            }?.constant
        }
        return CGSize(width: fixed(.width) ?? (intrinsic.width >= 0 ? intrinsic.width : view.frame.width),
                      height: fixed(.height) ?? (intrinsic.height >= 0 ? intrinsic.height : view.frame.height))
    }

    open override var intrinsicContentSize: NSSize {
        let views = visibleArranged
        let sizes = views.map(extent)
        let gaps = CGFloat(max(0, views.count - 1)) * spacing
        if orientation == .vertical {
            return NSSize(width: (sizes.map(\.width).max() ?? 0) + edgeInsets.left + edgeInsets.right,
                          height: sizes.reduce(0) { $0 + $1.height } + gaps + edgeInsets.top + edgeInsets.bottom)
        }
        return NSSize(width: sizes.reduce(0) { $0 + $1.width } + gaps + edgeInsets.left + edgeInsets.right,
                      height: (sizes.map(\.height).max() ?? 0) + edgeInsets.top + edgeInsets.bottom)
    }

    open override func layout() {
        super.layout()
        var offset: CGFloat = orientation == .vertical ? edgeInsets.top : edgeInsets.left
        for view in visibleArranged {
            let size = extent(of: view)
            if orientation == .vertical {
                let width = alignment == .width ? bounds.width : (view.frame.width > 0 ? view.frame.width : size.width)
                // Top to bottom, in this view's coordinates.
                let y = isFlipped ? offset : bounds.height - offset - size.height
                view.frame = CGRect(x: edgeInsets.left, y: y, width: width, height: size.height)
                offset += size.height + spacing
            } else {
                view.frame = CGRect(x: offset, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
                offset += size.width + spacing
            }
        }
    }
}

public struct NSEdgeInsets: Sendable, Equatable {
    public var top: CGFloat, left: CGFloat, bottom: CGFloat, right: CGFloat
    public init(top: CGFloat = 0, left: CGFloat = 0, bottom: CGFloat = 0, right: CGFloat = 0) {
        self.top = top; self.left = left; self.bottom = bottom; self.right = right
    }
}
