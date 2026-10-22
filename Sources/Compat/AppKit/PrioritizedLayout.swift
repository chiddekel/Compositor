import Foundation
import CoreGraphics

@MainActor private struct ViewLayoutPriorities {
    weak var view: NSView?
    var hugging: [NSLayoutConstraint.Priority] = [.defaultLow, .defaultLow]
    var compression: [NSLayoutConstraint.Priority] = [.defaultHigh, .defaultHigh]
}
@MainActor private var viewLayoutPriorities: [ObjectIdentifier: ViewLayoutPriorities] = [:]

extension NSView {
    func setLayoutPriority(_ priority: NSLayoutConstraint.Priority, orientation: NSLayoutConstraint.Orientation, compression: Bool) {
        guard priority.rawValue.isFinite, priority.rawValue > 0, priority.rawValue <= 1000 else { return }
        viewLayoutPriorities = viewLayoutPriorities.filter { $0.value.view != nil }
        let key = ObjectIdentifier(self)
        var values = viewLayoutPriorities[key] ?? ViewLayoutPriorities(view: self)
        let index = orientation == .horizontal ? 0 : 1
        if compression { values.compression[index] = priority } else { values.hugging[index] = priority }
        viewLayoutPriorities[key] = values
        needsLayout = true
        superview?.needsLayout = true
    }
    func layoutPriority(orientation: NSLayoutConstraint.Orientation, compression: Bool) -> NSLayoutConstraint.Priority {
        let index = orientation == .horizontal ? 0 : 1
        guard let values = viewLayoutPriorities[ObjectIdentifier(self)], values.view === self else {
            return compression ? .defaultHigh : .defaultLow
        }
        return compression ? values.compression[index] : values.hugging[index]
    }
}

/// Feasible required constraints are exact. Each lower priority minimizes its total violation without worsening
/// higher priorities. Intrinsic sizes supply hugging/compression bounds; weak stays settle underdetermined frames.
@MainActor enum PrioritizedLayoutSolver {
    private struct Expression {
        var terms: [Int: Double] = [:]
        var constant: Double = 0
        mutating func add(_ other: Expression, factor: Double) {
            constant += other.constant * factor
            for (index, value) in other.terms { terms[index, default: 0] += value * factor }
        }
    }
    private struct Rule {
        var expression: Expression
        var relation: NSLayoutConstraint.Relation
        var bound: Double
        var priority: Float
    }

    static func solveIfNeeded(container: NSView, constraints: [NSLayoutConstraint]) {
        func coordinate(_ anchor: NSLayoutConstraint.AnyAnchor) -> Double {
            guard let item = anchor.item else { return 0 }
            let frame = item === container ? container.bounds : item.layoutFrame
            let top = item === container ? 0 : container.isFlipped ? frame.minY : container.bounds.height - frame.maxY
            switch anchor.attribute {
            case .leading, .left: return Double(frame.minX)
            case .trailing, .right: return Double(frame.maxX)
            case .centerX: return Double(frame.midX)
            case .width: return Double(frame.width)
            case .top: return Double(top)
            case .bottom: return Double(top + frame.height)
            case .centerY: return Double(top + frame.height / 2)
            case .height: return Double(frame.height)
            }
        }
        var needsSolve = constraints.contains { rule in
            let difference = coordinate(rule.firstAttribute)
                - (rule.secondAttribute.map(coordinate) ?? 0) * Double(rule.multiplier) - Double(rule.constant)
            switch rule.relation {
            case .equal: return abs(difference) > 0.00001
            case .lessThanOrEqual: return difference > 0.00001
            case .greaterThanOrEqual: return difference < -0.00001
            }
        }
        var items: [NSLayoutItem] = []
        var indexes: [ObjectIdentifier: Int] = [:]
        for constraint in constraints {
            for anchor in [constraint.firstAttribute, constraint.secondAttribute].compactMap({ $0 }) {
                guard let item = anchor.item, item !== container, indexes[ObjectIdentifier(item)] == nil else { continue }
                if let view = item as? NSView, view.translatesAutoresizingMaskIntoConstraints { continue }
                indexes[ObjectIdentifier(item)] = items.count * 6
                items.append(item)
            }
        }
        guard !items.isEmpty else { return }
        let customized = items.contains { item in
            guard let view = item as? NSView else { return false }
            return [NSLayoutConstraint.Orientation.horizontal, .vertical].contains { axis in
                view.contentHuggingPriority(for: axis) != .defaultLow
                    || view.contentCompressionResistancePriority(for: axis) != .defaultHigh
            }
        }
        if customized {
            needsSolve = needsSolve || items.contains { item in
                guard let view = item as? NSView else { return false }
                let size = view.intrinsicContentSize
                return (size.width >= 0 && abs(size.width - view.frame.width) > 0.00001)
                    || (size.height >= 0 && abs(size.height - view.frame.height) > 0.00001)
            }
        }
        guard needsSolve else { return }
        let stayPriority = min(250, constraints.map { $0.priority.rawValue }.min() ?? 250) / 2
        func expression(_ anchor: NSLayoutConstraint.AnyAnchor) -> Expression {
            guard let item = anchor.item, let base = indexes[ObjectIdentifier(item)] else {
                return Expression(constant: coordinate(anchor))
            }
            // Positions are free variables, represented as a difference of two nonnegative variables. Sizes are
            // nonnegative themselves. Coordinates run downward, independently of the container's flippedness.
            var result = Expression()
            switch anchor.attribute {
            case .leading, .left: result.terms = [base: 1, base + 1: -1]
            case .trailing, .right: result.terms = [base: 1, base + 1: -1, base + 4: 1]
            case .centerX: result.terms = [base: 1, base + 1: -1, base + 4: 0.5]
            case .width: result.terms = [base + 4: 1]
            case .top: result.terms = [base + 2: 1, base + 3: -1]
            case .bottom: result.terms = [base + 2: 1, base + 3: -1, base + 5: 1]
            case .centerY: result.terms = [base + 2: 1, base + 3: -1, base + 5: 0.5]
            case .height: result.terms = [base + 5: 1]
            }
            return result
        }
        var rules: [Rule] = []
        for constraint in constraints {
            guard constraint.constant.isFinite, constraint.multiplier.isFinite,
                  constraint.priority.rawValue.isFinite, constraint.priority.rawValue > 0 else { return }
            var value = expression(constraint.firstAttribute)
            if let second = constraint.secondAttribute { value.add(expression(second), factor: -Double(constraint.multiplier)) }
            rules.append(Rule(expression: value, relation: constraint.relation, bound: Double(constraint.constant),
                              priority: constraint.priority.rawValue))
        }
        for item in items {
            let base = indexes[ObjectIdentifier(item)]!
            let frame = item.layoutFrame
            let intrinsic = (item as? NSView)?.intrinsicContentSize ?? CGSize(width: -1, height: -1)
            for axis in 0..<2 {
                let size = Double(axis == 0 ? intrinsic.width : intrinsic.height)
                let current = Double(axis == 0 ? frame.width : frame.height)
                let dimension = Expression(terms: [base + 4 + axis: 1])
                if size.isFinite, size >= 0 {
                    let orientation: NSLayoutConstraint.Orientation = axis == 0 ? .horizontal : .vertical
                    let view = item as? NSView
                    rules.append(Rule(expression: dimension, relation: .lessThanOrEqual, bound: size,
                                      priority: view?.contentHuggingPriority(for: orientation).rawValue ?? 250))
                    rules.append(Rule(expression: dimension, relation: .greaterThanOrEqual, bound: size,
                                      priority: view?.contentCompressionResistancePriority(for: orientation).rawValue ?? 750))
                } else {
                    rules.append(Rule(expression: dimension, relation: .equal, bound: max(0, current), priority: stayPriority))
                }
            }
            let top = container.isFlipped ? frame.minY : container.bounds.height - frame.maxY
            rules.append(Rule(expression: Expression(terms: [base: 1, base + 1: -1]), relation: .equal,
                              bound: Double(frame.minX), priority: stayPriority))
            rules.append(Rule(expression: Expression(terms: [base + 2: 1, base + 3: -1]), relation: .equal,
                              bound: Double(top), priority: stayPriority))
        }
        let frameVariables = items.count * 6
        let optional = rules.filter { $0.priority < 1000 }.count
        let variables = frameVariables + optional
        var matrix: [[Double]] = [], bounds: [Double] = []
        var errors: [Float: [Int]] = [:]
        var errorIndex = frameVariables
        for rule in rules {
            var row = [Double](repeating: 0, count: variables)
            for (index, value) in rule.expression.terms { row[index] = value }
            let bound = rule.bound - rule.expression.constant
            let error: Int? = rule.priority < 1000 ? errorIndex : nil
            if let error { errors[rule.priority, default: []].append(error); errorIndex += 1 }
            if rule.relation != .greaterThanOrEqual {
                var upper = row
                if let error { upper[error] = -1 }
                matrix.append(upper); bounds.append(bound)
            }
            if rule.relation != .lessThanOrEqual {
                var lower = row.map { -$0 }
                if let error { lower[error] = -1 }
                matrix.append(lower); bounds.append(-bound)
            }
        }
        var solution: [Double]?
        for priority in errors.keys.sorted(by: >) {
            var objective = [Double](repeating: 0, count: variables)
            let band = errors[priority]!
            for error in band { objective[error] = -1 }
            var program = LayoutLinearProgram(matrix: matrix, bounds: bounds, objective: objective)
            guard let result = program.solve() else { return }
            solution = result
            var lock = [Double](repeating: 0, count: variables)
            for error in band { lock[error] = 1 }
            matrix.append(lock)
            bounds.append(band.reduce(0) { $0 + max(0, result[$1]) } + 0.0000001)
        }
        guard let solution, solution.allSatisfy({ $0.isFinite }) else { return }
        func cleaned(_ value: Double) -> CGFloat {
            let integral = value.rounded()
            return CGFloat(abs(value - integral) < 0.000001 ? integral : value)
        }
        for item in items {
            let base = indexes[ObjectIdentifier(item)]!
            let x = cleaned(solution[base] - solution[base + 1])
            let top = cleaned(solution[base + 2] - solution[base + 3])
            let width = cleaned(max(0, solution[base + 4])), height = cleaned(max(0, solution[base + 5]))
            let y = container.isFlipped ? top : container.bounds.height - top - height
            item.layoutFrame = CGRect(x: x, y: y, width: width, height: height)
        }
    }
}

/// Two-phase simplex for max(c*x), A*x <= b, x >= 0. Phase one finds a feasible basis even when some bounds are
/// negative. Stable variable-index tie breaking prevents cycling on degenerate layout constraints.
private struct LayoutLinearProgram {
    private static let epsilon = 0.000000001
    private let rows: Int, columns: Int
    private var basis: [Int], nonbasis: [Int]
    private var tableau: [[Double]]

    init(matrix: [[Double]], bounds: [Double], objective: [Double]) {
        rows = bounds.count; columns = objective.count
        basis = (0..<bounds.count).map { objective.count + $0 }
        nonbasis = Array(0..<columns) + [-1]
        tableau = Array(repeating: Array(repeating: 0, count: columns + 2), count: rows + 2)
        for row in 0..<rows {
            for column in 0..<columns { tableau[row][column] = matrix[row][column] }
            tableau[row][columns] = -1
            tableau[row][columns + 1] = bounds[row]
        }
        for column in 0..<columns { tableau[rows][column] = -objective[column] }
        tableau[rows + 1][columns] = 1
    }
    private mutating func pivot(row: Int, column: Int) {
        let inverse = 1 / tableau[row][column]
        for otherRow in 0..<(rows + 2) where otherRow != row {
            let factor = tableau[otherRow][column] * inverse
            for otherColumn in 0..<(columns + 2) where otherColumn != column {
                tableau[otherRow][otherColumn] -= tableau[row][otherColumn] * factor
            }
        }
        for otherColumn in 0..<(columns + 2) where otherColumn != column { tableau[row][otherColumn] *= inverse }
        for otherRow in 0..<(rows + 2) where otherRow != row { tableau[otherRow][column] *= -inverse }
        tableau[row][column] = inverse
        let old = basis[row]; basis[row] = nonbasis[column]; nonbasis[column] = old
    }
    private mutating func optimize(phase: Int) -> Bool {
        let objective = phase == 1 ? rows + 1 : rows
        for _ in 0..<10000 {
            var entering: Int?
            for column in 0...columns where phase == 1 || nonbasis[column] != -1 {
                guard tableau[objective][column] < -Self.epsilon else { continue }
                if entering == nil || nonbasis[column] < nonbasis[entering!] { entering = column }
            }
            guard let entering else { return true }
            var leaving: Int?
            for row in 0..<rows where tableau[row][entering] > Self.epsilon {
                guard let previous = leaving else { leaving = row; continue }
                let ratio = tableau[row][columns + 1] / tableau[row][entering]
                let previousRatio = tableau[previous][columns + 1] / tableau[previous][entering]
                if ratio < previousRatio - Self.epsilon || (abs(ratio - previousRatio) <= Self.epsilon && basis[row] < basis[previous]) {
                    leaving = row
                }
            }
            guard let leaving else { return false }
            pivot(row: leaving, column: entering)
        }
        return false
    }
    mutating func solve() -> [Double]? {
        guard let row = (0..<rows).min(by: { tableau[$0][columns + 1] < tableau[$1][columns + 1] }) else {
            return [Double](repeating: 0, count: columns)
        }
        if tableau[row][columns + 1] < -Self.epsilon {
            pivot(row: row, column: columns)
            guard optimize(phase: 1), abs(tableau[rows + 1][columns + 1]) <= Self.epsilon else { return nil }
            if let artificial = basis.firstIndex(of: -1) {
                let real = (0...columns).filter { nonbasis[$0] != -1 && abs(tableau[artificial][$0]) > Self.epsilon }
                    .min(by: { nonbasis[$0] < nonbasis[$1] })
                if let real { pivot(row: artificial, column: real) }
            }
        }
        guard optimize(phase: 2) else { return nil }
        var result = [Double](repeating: 0, count: columns)
        for row in 0..<rows where basis[row] >= 0 && basis[row] < columns { result[basis[row]] = tableau[row][columns + 1] }
        return result
    }
}
