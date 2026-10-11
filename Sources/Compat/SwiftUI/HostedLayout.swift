// The layout an `NSHostingView` runs over its resolved tree to place the native views (`NSViewRepresentable`s) it
// hosts. The Qt renderer lays out everything else itself; this only has to answer "where does each native view go",
// which on macOS SwiftUI's own layout answers. It follows SwiftUI's proposal/response model for the parts that
// decide that — stacks (with `layoutPriority`), frames (fixed and flexible, with alignment) and padding — and treats
// every other modifier as layout-neutral. Text/control leaves take the renderer's measured size when available.

import Foundation

@MainActor enum HostedLayout {
    struct Placement {
        let path: String
        let source: any _NativeViewSource
        /// Top-left-origin rect in the hosting view.
        let frame: CGRect
    }

    static func place(_ input: RenderNode, in rect: CGRect,
                      intrinsicSize: @escaping (String) -> CGSize? = { _ in nil },
                      nativeSize: @escaping (RenderNode, ProposedViewSize) -> CGSize? = { _, _ in nil }) -> [Placement] {
        let previous = intrinsic
        let previousNative = preferredNative
        let previousFixed = fixedAxes
        intrinsic = intrinsicSize
        preferredNative = nativeSize
        fixedAxes = (false, false)
        defer { intrinsic = previous; preferredNative = previousNative; fixedAxes = previousFixed }
        geometryChanged = false
        var out: [Placement] = []
        let root = inheritingStyles(input)
        place(root, root.modifiers.count, rect, &out)
        return out
    }

    /// Whether the last `place` gave a GeometryReader a size other than the one it was resolved with: its content
    /// must be resolved again (the hosting view does, as SwiftUI re-runs the reader's closure).
    private(set) static var geometryChanged = false

    /// A hosted view's `intrinsicContentSize` by node path (-1 on an axis it has none), for `.fixedSize()`.
    private static var intrinsic: (String) -> CGSize? = { _ in nil }
    private static var preferredNative: (RenderNode, ProposedViewSize) -> CGSize? = { _, _ in nil }
    private static var fixedAxes = (horizontal: false, vertical: false)

    /// Natural bounds when every required axis is known. The renderer measures supported text/control leaves;
    /// unsupported leaves remain unknown. Fixed frames can supply an otherwise unknown axis.
    static func fittingSize(_ input: RenderNode, intrinsicSize: (String) -> CGSize?,
                            nativeSize: (RenderNode, ProposedViewSize) -> CGSize? = { _, _ in nil }) -> CGSize? {
        let size = idealSize(input, intrinsicSize: intrinsicSize, nativeSize: nativeSize)
        guard size.width >= 0, size.height >= 0 else { return nil }
        return size
    }

    /// Unlike fitting bounds, intrinsic metrics preserve a known axis when the other cannot be measured.
    static func idealSize(_ input: RenderNode, intrinsicSize: (String) -> CGSize?,
                          nativeSize: (RenderNode, ProposedViewSize) -> CGSize? = { _, _ in nil }) -> CGSize {
        let size = proposedSize(input, proposal: .unspecified, intrinsicSize: intrinsicSize, nativeSize: nativeSize)
        return CGSize(width: size.width.isFinite ? size.width : -1, height: size.height.isFinite ? size.height : -1)
    }

    static func proposedSize(_ input: RenderNode, proposal: ProposedViewSize, intrinsicSize: (String) -> CGSize?,
                             nativeSize: (RenderNode, ProposedViewSize) -> CGSize? = { _, _ in nil }) -> CGSize {
        typealias Bounds = (width: CGFloat?, height: CGFloat?)
        func measure(_ node: RenderNode, proposal: ProposedViewSize = .unspecified) -> Bounds {
            var childProposal = proposal
            var offers: [Int: ProposedViewSize] = [:]
            for index in node.modifiers.indices.reversed() {
                offers[index] = childProposal
                let modifier = node.modifiers[index]
                switch modifier {
                case let .frame(width, height, minWidth, minHeight, maxWidth, maxHeight, _):
                    func offered(_ value: CGFloat?, _ fixed: Double?, _ lo: Double?, _ hi: Double?) -> CGFloat? {
                        if let fixed { return fixed }
                        guard let value else { return nil }
                        return min(max(value, lo ?? 0), hi ?? .infinity)
                    }
                    childProposal.width = offered(childProposal.width, width, minWidth, maxWidth)
                    childProposal.height = offered(childProposal.height, height, minHeight, maxHeight)
                case let .padding(top, leading, bottom, trailing):
                    if let width = childProposal.width { childProposal.width = max(0, width - leading - trailing) }
                    if let height = childProposal.height { childProposal.height = max(0, height - top - bottom) }
                case let .fixedSize(horizontal, vertical):
                    if horizontal { childProposal.width = nil }
                    if vertical { childProposal.height = nil }
                default: break
                }
            }
            var result: Bounds
            if node.kind == "_Native", let size = nativeSize(node, childProposal) ?? intrinsicSize(node.id) {
                result = (size.width >= 0 ? size.width : nil, size.height >= 0 ? size.height : nil)
            } else if node.kind == "_Empty" {
                result = (0, 0)
            } else if let size = HostingMeasurementBackend.measure(node, proposal: childProposal) {
                result = (size.width, size.height)
            } else if ["HStack", "VStack", "ZStack", "_ViewList", "Group"].contains(node.kind) {
                let horizontal = node.kind == "HStack", vertical = node.kind == "VStack"
                var children: [Bounds]
                let available = horizontal ? childProposal.width : vertical ? childProposal.height : nil
                if let available, available.isFinite {
                    func offer(_ length: CGFloat) -> ProposedViewSize {
                        var proposed = childProposal
                        if horizontal { proposed.width = length } else { proposed.height = length }
                        return proposed
                    }
                    if let lengths = stackLengths(node, available: available, main: { child, length in
                        let measured = measure(child, proposal: offer(length))
                        return horizontal ? measured.width : measured.height
                    }) {
                        children = node.children.enumerated().map { index, child in
                            measure(child, proposal: offer(lengths[index]))
                        }
                    } else {
                        // A renderer-owned leaf has no measured bounds yet; don't infer a cross-axis size from
                        // children that were never given their actual share of the constrained main axis.
                        children = node.children.map { _ in (nil, nil) }
                    }
                } else {
                    children = node.children.map { measure($0, proposal: childProposal) }
                }
                func combined(_ values: [CGFloat?], sum: Bool) -> CGFloat? {
                    guard values.allSatisfy({ $0 != nil }) else { return nil }
                    let known = values.compactMap { $0 }
                    return sum ? known.reduce(0, +) : known.max() ?? 0
                }
                result = (combined(children.map(\.width), sum: horizontal), combined(children.map(\.height), sum: vertical))
                let spacing = CGFloat(node.doubleParams["spacing"] ?? 8) * CGFloat(max(0, children.count - 1))
                if horizontal, let width = result.width { result.width = width + spacing }
                if vertical, let height = result.height { result.height = height + spacing }
            } else {
                result = (nil, nil)
            }
            for (index, modifier) in node.modifiers.enumerated() {
                switch modifier {
                case let .padding(top, leading, bottom, trailing):
                    if let width = result.width { result.width = width + leading + trailing }
                    if let height = result.height { result.height = height + top + bottom }
                case let .frame(width, height, minWidth, minHeight, maxWidth, maxHeight, _):
                    func axis(_ value: CGFloat?, _ received: CGFloat?, _ fixed: Double?, _ lo: Double?, _ hi: Double?) -> CGFloat? {
                        if let fixed { return fixed }
                        if let lo, lo == hi { return lo }
                        if (lo != nil || hi != nil), let received {
                            return min(max(received, lo ?? value ?? 0), hi ?? value ?? .infinity)
                        }
                        guard let value else { return nil }
                        return min(max(value, lo ?? 0), hi ?? .infinity)
                    }
                    result = (axis(result.width, offers[index]?.width, width, minWidth, maxWidth),
                              axis(result.height, offers[index]?.height, height, minHeight, maxHeight))
                default: break
                }
            }
            return result
        }
        let result = measure(inheritingStyles(input), proposal: proposal)
        func metric(_ value: CGFloat?) -> CGFloat {
            guard let value, !value.isNaN else { return -1 }
            return max(0, value)
        }
        return CGSize(width: metric(result.width), height: metric(result.height))
    }

    // MARK: Sizing (`depth` = how many of the node's modifiers, innermost first, still apply)

    static func size(_ node: RenderNode, _ depth: Int, _ proposal: CGSize) -> CGSize {
        guard depth > 0 else { return baseSize(node, proposal) }
        switch node.modifiers[depth - 1] {
        case let .frame(width, height, minWidth, minHeight, maxWidth, maxHeight, _):
            let (w, h) = frameAxes(node, depth, proposal, width, height, minWidth, minHeight, maxWidth, maxHeight)
            return CGSize(width: w.result, height: h.result)
        case let .padding(top, leading, bottom, trailing):
            let inner = size(node, depth - 1, CGSize(width: max(0, proposal.width - leading - trailing),
                                                    height: max(0, proposal.height - top - bottom)))
            return CGSize(width: inner.width + leading + trailing, height: inner.height + top + bottom)
        case let .fixedSize(horizontal, vertical):
            // Fixed axes stay unspecified through intervening padding and containers, down to the native leaf.
            let previous = fixedAxes
            fixedAxes = (horizontal || previous.horizontal, vertical || previous.vertical)
            defer { fixedAxes = previous }
            return size(node, depth - 1, proposal)
        default:
            return size(node, depth - 1, proposal)
        }
    }

    private typealias Axis = (proposal: CGFloat, result: CGFloat)

    /// One axis of a frame: what it proposes to its content, and its own resulting length. A fixed frame is exactly
    /// its length; a flexible one is the proposal clamped to [min, max], an unspecified bound falling back to the
    /// content's own length — SwiftUI's rule.
    private static func frameAxes(_ node: RenderNode, _ depth: Int, _ proposal: CGSize, _ width: Double?, _ height: Double?,
                                  _ minWidth: Double?, _ minHeight: Double?, _ maxWidth: Double?, _ maxHeight: Double?)
        -> (Axis, Axis) {
        func childProposal(_ p: CGFloat, _ fixed: Double?, _ lo: Double?, _ hi: Double?) -> CGFloat {
            if let fixed, lo == nil, hi == nil { return fixed }
            if lo != nil || hi != nil { return min(max(p, lo ?? -.infinity), hi ?? .infinity) }
            return p
        }
        let pw = childProposal(proposal.width, width, minWidth, maxWidth)
        let ph = childProposal(proposal.height, height, minHeight, maxHeight)
        let child = size(node, depth - 1, CGSize(width: pw, height: ph))
        func result(_ p: CGFloat, _ c: CGFloat, _ fixed: Double?, _ lo: Double?, _ hi: Double?) -> CGFloat {
            if let fixed, lo == nil, hi == nil { return fixed }
            if lo != nil || hi != nil { return min(max(p, lo ?? c), hi ?? c) }
            return c
        }
        return ((pw, result(proposal.width, child.width, width, minWidth, maxWidth)),
                (ph, result(proposal.height, child.height, height, minHeight, maxHeight)))
    }

    private static func baseSize(_ node: RenderNode, _ proposal: CGSize) -> CGSize {
        if let size = HostingMeasurementBackend.measure(node,
            proposal: ProposedViewSize(width: fixedAxes.horizontal ? nil : proposal.width,
                                       height: fixedAxes.vertical ? nil : proposal.height)) { return size }
        switch node.kind {
        case "_Native":
            if let preferred = preferredNative(node, ProposedViewSize(width: fixedAxes.horizontal ? nil : proposal.width,
                                                                      height: fixedAxes.vertical ? nil : proposal.height)) { return preferred }
            var result = proposal
            if let ideal = intrinsic(node.id) {
                if fixedAxes.horizontal, ideal.width >= 0 { result.width = ideal.width }
                if fixedAxes.vertical, ideal.height >= 0 { result.height = ideal.height }
            }
            return result
        case "GeometryReader":
            return proposal
        case "HStack", "VStack":
            return stack(node, proposal).size
        default:
            // Any other container stacks its children on top of each other; a leaf takes no room.
            var result = CGSize.zero
            for child in node.children {
                let s = size(child, child.modifiers.count, proposal)
                result = CGSize(width: max(result.width, s.width), height: max(result.height, s.height))
            }
            return result
        }
    }

    /// Font and control environments reach leaves even when measurement visits them separately from the container.
    private static func inheritingStyles(_ node: RenderNode, inherited: [RenderModifier] = []) -> RenderNode {
        var result = node
        result.modifiers = inherited + node.modifiers
        let styles = result.modifiers.filter {
            switch $0 {
            case .font, .controlSize, .buttonStyle, .toggleStyle, .pickerStyle, .textFieldStyle: return true
            default: return false
            }
        }
        result.children = node.children.map { inheritingStyles($0, inherited: styles) }
        return result
    }

    private static func priority(_ node: RenderNode) -> Double {
        for modifier in node.modifiers.reversed() { if case .layoutPriority(let value) = modifier { return value } }
        return 0
    }

    /// Shared main-axis allocation for natural measurement and placement. A missing response keeps fitting
    /// bounds unknown; placement's size responses are always known.
    private static func stackLengths(_ node: RenderNode, available: CGFloat,
                                     main: (RenderNode, CGFloat) -> CGFloat?) -> [CGFloat]? {
        let children = node.children
        guard !children.isEmpty else { return [] }
        let spacing = CGFloat(node.doubleParams["spacing"] ?? 8) * CGFloat(children.count - 1)
        let lowerBounds = children.map { main($0, 0) }
        let upperBounds = children.map { main($0, .greatestFiniteMagnitude) }
        guard lowerBounds.allSatisfy({ $0 != nil }), upperBounds.allSatisfy({ $0 != nil }) else { return nil }
        let minimum = lowerBounds.compactMap { $0 }, maximum = upperBounds.compactMap { $0 }
        var lengths = [CGFloat](repeating: 0, count: children.count)
        var remaining = available - spacing
        let priorities = Array(Set(children.map(priority))).sorted(by: >)
        for (index, level) in priorities.enumerated() {
            let lower = Set(priorities[(index + 1)...])
            let reserved = children.indices.filter { lower.contains(priority(children[$0])) }.reduce(0) { $0 + minimum[$1] }
            var offered = remaining - reserved
            let group = children.indices.filter { priority(children[$0]) == level }
                .sorted { maximum[$0] - minimum[$0] < maximum[$1] - minimum[$1] }
            for (position, i) in group.enumerated() {
                let offer = max(0, offered / CGFloat(group.count - position))
                guard let length = main(children[i], offer) else { return nil }
                lengths[i] = length
                offered -= length
                remaining -= length
            }
        }
        return lengths
    }

    /// A stack's main-axis lengths per child: higher `layoutPriority` groups are offered space first, after
    /// reserving the minimum of every lower-priority child; within a group the least flexible child goes first and
    /// each is offered an even share of what is left — SwiftUI's stack algorithm.
    private static func stack(_ node: RenderNode, _ proposal: CGSize) -> (size: CGSize, lengths: [CGFloat]) {
        let horizontal = node.kind == "HStack"
        let children = node.children
        guard !children.isEmpty else { return (.zero, []) }
        let spacing = CGFloat(node.doubleParams["spacing"] ?? 8) * CGFloat(children.count - 1)
        let cross = horizontal ? proposal.height : proposal.width
        func main(_ child: RenderNode, _ offer: CGFloat) -> CGFloat {
            let s = size(child, child.modifiers.count, horizontal ? CGSize(width: offer, height: cross)
                                                                  : CGSize(width: cross, height: offer))
            return horizontal ? s.width : s.height
        }
        let lengths = stackLengths(node, available: horizontal ? proposal.width : proposal.height,
                                   main: { child, offer in main(child, offer) }) ?? []
        var crossLength: CGFloat = 0
        for (i, child) in children.enumerated() {
            let s = size(child, child.modifiers.count, horizontal ? CGSize(width: lengths[i], height: cross)
                                                                  : CGSize(width: cross, height: lengths[i]))
            crossLength = max(crossLength, horizontal ? s.height : s.width)
        }
        let total = lengths.reduce(0, +) + spacing
        return (horizontal ? CGSize(width: total, height: crossLength) : CGSize(width: crossLength, height: total), lengths)
    }

    // MARK: Placement

    private static func place(_ node: RenderNode, _ depth: Int, _ rect: CGRect, _ out: inout [Placement]) {
        guard depth > 0 else { placeBase(node, rect, &out); return }
        switch node.modifiers[depth - 1] {
        case let .frame(width, height, minWidth, minHeight, maxWidth, maxHeight, alignment):
            let (w, h) = frameAxes(node, depth, rect.size, width, height, minWidth, minHeight, maxWidth, maxHeight)
            let frame = aligned(CGSize(width: w.result, height: h.result), in: rect, alignment: "center")
            let child = size(node, depth - 1, CGSize(width: w.proposal, height: h.proposal))
            place(node, depth - 1, aligned(child, in: frame, alignment: alignment), &out)
        case let .padding(top, leading, bottom, trailing):
            place(node, depth - 1, CGRect(x: rect.minX + leading, y: rect.minY + top,
                                          width: max(0, rect.width - leading - trailing),
                                          height: max(0, rect.height - top - bottom)), &out)
        case .fixedSize:
            place(node, depth - 1, aligned(size(node, depth, rect.size), in: rect, alignment: "center"), &out)
        default:
            place(node, depth - 1, rect, &out)
        }
    }

    private static func placeBase(_ node: RenderNode, _ rect: CGRect, _ out: inout [Placement]) {
        switch node.kind {
        case "_Native":
            if let source = node.nativeSource { out.append(Placement(path: node.id, source: source, frame: rect)) }
        case "GeometryReader":
            // Reports the size it is laid out at, as the Qt shell does, and puts its content at its top leading corner.
            let width = node.doubleParams["width"] ?? 0, height = node.doubleParams["height"] ?? 0
            if abs(width - Double(rect.width)) > 0.5 || abs(height - Double(rect.height)) > 0.5, let report = node.handlers["size"] {
                report([Double(rect.width), Double(rect.height)])
                geometryChanged = true
            }
            for child in node.children {
                let s = size(child, child.modifiers.count, rect.size)
                place(child, child.modifiers.count, aligned(s, in: rect, alignment: "topLeading"), &out)
            }
        case "HStack", "VStack":
            let horizontal = node.kind == "HStack"
            let (_, lengths) = stack(node, rect.size)
            let gap = CGFloat(node.doubleParams["spacing"] ?? 8)
            let alignment = node.stringParams["alignment"] ?? "center"
            var cursor = horizontal ? rect.minX : rect.minY
            for (i, child) in node.children.enumerated() {
                let slot = horizontal ? CGRect(x: cursor, y: rect.minY, width: lengths[i], height: rect.height)
                                      : CGRect(x: rect.minX, y: cursor, width: rect.width, height: lengths[i])
                let s = size(child, child.modifiers.count, slot.size)
                place(child, child.modifiers.count, aligned(s, in: slot, alignment: alignment), &out)
                cursor += lengths[i] + gap
            }
        default:
            for child in node.children {
                let s = size(child, child.modifiers.count, rect.size)
                place(child, child.modifiers.count, aligned(s, in: rect, alignment: "center"), &out)
            }
        }
    }

    /// `size` inside `rect` per an `Alignment`/stack alignment name ("leading", "topTrailing", "center", ...).
    private static func aligned(_ size: CGSize, in rect: CGRect, alignment: String) -> CGRect {
        let name = alignment.lowercased()
        let x = name.contains("leading") ? rect.minX : name.contains("trailing") ? rect.maxX - size.width
            : rect.midX - size.width / 2
        let y = name.hasPrefix("top") ? rect.minY : name.hasPrefix("bottom") ? rect.maxY - size.height
            : rect.midY - size.height / 2
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }
}
