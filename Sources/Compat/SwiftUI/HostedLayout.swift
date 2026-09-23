// The layout an `NSHostingView` runs over its resolved tree to place the native views (`NSViewRepresentable`s) it
// hosts. The Qt renderer lays out everything else itself; this only has to answer "where does each native view go",
// which on macOS SwiftUI's own layout answers. It follows SwiftUI's proposal/response model for the parts that
// decide that — stacks (with `layoutPriority`), frames (fixed and flexible, with alignment) and padding — and treats
// every other modifier as layout-neutral. Leaves other than native views take no room.

import Foundation

@MainActor enum HostedLayout {
    struct Placement {
        let path: String
        let source: any _NativeViewSource
        /// Top-left-origin rect in the hosting view.
        let frame: CGRect
    }

    static func place(_ root: RenderNode, in rect: CGRect) -> [Placement] {
        var out: [Placement] = []
        place(root, root.modifiers.count, rect, &out)
        return out
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
        switch node.kind {
        case "_Native":
            return proposal                                     // a hosted AppKit view fills what it is offered
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

    private static func priority(_ node: RenderNode) -> Double {
        for modifier in node.modifiers.reversed() { if case .layoutPriority(let value) = modifier { return value } }
        return 0
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
        let minimum = children.map { main($0, 0) }
        let maximum = children.map { main($0, .greatestFiniteMagnitude) }
        var lengths = [CGFloat](repeating: 0, count: children.count)
        var remaining = (horizontal ? proposal.width : proposal.height) - spacing
        let priorities = Array(Set(children.map(priority))).sorted(by: >)
        for (index, level) in priorities.enumerated() {
            let lower = Set(priorities[(index + 1)...])
            let reserved = children.indices.filter { lower.contains(priority(children[$0])) }.reduce(0) { $0 + minimum[$1] }
            var available = remaining - reserved
            let group = children.indices.filter { priority(children[$0]) == level }
                .sorted { maximum[$0] - minimum[$0] < maximum[$1] - minimum[$1] }
            for (position, i) in group.enumerated() {
                let offer = max(0, available / CGFloat(group.count - position))
                lengths[i] = main(children[i], offer)
                available -= lengths[i]
                remaining -= lengths[i]
            }
        }
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
        default:
            place(node, depth - 1, rect, &out)
        }
    }

    private static func placeBase(_ node: RenderNode, _ rect: CGRect, _ out: inout [Placement]) {
        switch node.kind {
        case "_Native":
            if let source = node.nativeSource { out.append(Placement(path: node.id, source: source, frame: rect)) }
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
