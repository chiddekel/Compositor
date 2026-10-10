import Foundation
import CoreGraphics

public enum NSUserInterfaceLayoutDirection: Int, Sendable { case leftToRight = 0, rightToLeft = 1 }

/// The value-and-drawing half of a control, as AppKit splits it: the control forwards its value to its cell, and the
/// cell draws into the control's bounds.
@MainActor open class NSCell {
    public required init() {}
    open var isEnabled = true
    open var doubleValue: Double = 0
    open var floatValue: Float { get { Float(doubleValue) } set { doubleValue = Double(newValue) } }
    open var intValue: Int32 { get { Int32(doubleValue) } set { doubleValue = Double(newValue) } }
    public weak var controlView: NSView?
    open var userInterfaceLayoutDirection: NSUserInterfaceLayoutDirection = .leftToRight
    open func draw(withFrame cellFrame: CGRect, in controlView: NSView) { drawInterior(withFrame: cellFrame, in: controlView) }
    open func drawInterior(withFrame cellFrame: CGRect, in controlView: NSView) {}
    /// AppKit calls this as a press starts tracking; true lets tracking go on.
    open func startTracking(at startPoint: NSPoint, in controlView: NSView) -> Bool { true }
}

@MainActor open class NSActionCell: NSCell {
    public weak var target: AnyObject?
    public var action: Selector?
}

/// A linear slider's geometry, as on macOS: the bar spans the cell, and a 20-point knob travels inside it, so its center
/// covers `[minX + 10, maxX - 10]`. `trackRect` stays empty until the cell first draws, as AppKit's does.
@MainActor open class NSSliderCell: NSActionCell {
    public enum SliderType: UInt, Sendable { case linear = 0, circular = 1 }
    public var sliderType: SliderType = .linear
    public var minValue: Double = 0 { didSet { doubleValue = clamped(doubleValue) } }
    public var maxValue: Double = 1 { didSet { doubleValue = clamped(doubleValue) } }
    private var storedValue: Double = 0
    open override var doubleValue: Double {
        get { storedValue }
        set { storedValue = clamped(newValue) }
    }
    public var numberOfTickMarks = 0
    public var allowsTickMarkValuesOnly = false
    /// Unset (nil) means AppKit's automatic choice: vertical when the control is taller than it is wide.
    private var verticalOverride: Bool?
    public var isVertical: Bool {
        get { verticalOverride ?? controlView.map { $0.bounds.height > $0.bounds.width } ?? false }
        set { verticalOverride = newValue }
    }
    public private(set) var trackRect: CGRect = .zero
    public var knobThickness: CGFloat { 20 }

    public required init() { super.init() }

    private func clamped(_ value: Double) -> Double { maxValue > minValue ? min(max(value, minValue), maxValue) : minValue }

    public func closestTickMarkValue(toValue value: Double) -> Double {
        guard numberOfTickMarks > 0 else { return value }
        guard numberOfTickMarks > 1 else { return (minValue + maxValue) / 2 }
        let step = (maxValue - minValue) / Double(numberOfTickMarks - 1)
        return minValue + (((value - minValue) / step).rounded()) * step
    }

    /// The frame the cell lays out in: what it last drew in, else its control's bounds.
    private var cellFrame: CGRect { trackRect.isEmpty ? (controlView?.bounds ?? .zero) : trackRect }

    open func knobRect(flipped: Bool) -> CGRect {
        let frame = cellFrame
        let size = min(knobThickness, max(frame.height, 0))
        let travel = max(frame.width - knobThickness, 0)
        var fraction = maxValue > minValue ? (doubleValue - minValue) / (maxValue - minValue) : 0
        if userInterfaceLayoutDirection == .rightToLeft { fraction = 1 - fraction }
        return CGRect(x: frame.minX + CGFloat(fraction) * travel, y: frame.midY - size / 2, width: knobThickness, height: size)
    }

    open func barRect(flipped: Bool) -> CGRect {
        let frame = cellFrame, height: CGFloat = 4
        return CGRect(x: frame.minX, y: frame.midY - height / 2, width: frame.width, height: height)
    }

    open func drawBar(inside rect: CGRect, flipped: Bool) {
        let bar = CGRect(x: rect.minX, y: rect.midY - 2, width: rect.width, height: 4)
        NSColor(white: 0.5, alpha: 0.5).setFill()
        NSBezierPath(roundedRect: bar, xRadius: 2, yRadius: 2).fill()
    }

    open func drawKnob(_ knobRect: CGRect) {
        NSColor.white.setFill()
        NSBezierPath(ovalIn: knobRect.insetBy(dx: 1, dy: 1)).fill()
    }

    open func drawKnob() { drawKnob(knobRect(flipped: controlView?.isFlipped ?? false)) }

    open override func drawInterior(withFrame cellFrame: CGRect, in controlView: NSView) {
        trackRect = cellFrame
        drawBar(inside: barRect(flipped: controlView.isFlipped), flipped: controlView.isFlipped)
        drawKnob()
    }

    /// Installed by the app (`SliderSnap.install()` on Linux): runs as a press starts tracking, before the cell does.
    public static var startTrackingHook: ((NSSliderCell, NSPoint, NSView) -> Void)?

    open override func startTracking(at startPoint: NSPoint, in controlView: NSView) -> Bool {
        Self.startTrackingHook?(self, startPoint, controlView)
        return super.startTracking(at: startPoint, in: controlView)
    }
}

/// A slider control: its value lives in its `NSSliderCell`.
@MainActor open class NSSlider: NSControl {
    open class var cellClass: NSSliderCell.Type { NSSliderCell.self }
    public var cell: NSCell? {
        didSet { cell?.controlView = self; (cell as? NSActionCell).map { $0.target = target; $0.action = action } }
    }
    private var sliderCell: NSSliderCell? { cell as? NSSliderCell }

    public override init(frame: CGRect) {
        super.init(frame: frame)
        let cell = Self.cellClass.init()
        cell.controlView = self
        self.cell = cell
    }
    public required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    public convenience init(value: Double, minValue: Double, maxValue: Double, target: AnyObject?, action: Selector?) {
        self.init(frame: CGRect(x: 0, y: 0, width: 96, height: 28))
        self.minValue = minValue
        self.maxValue = maxValue
        self.doubleValue = value
        self.target = target
        self.action = action
    }

    public var minValue: Double {
        get { sliderCell?.minValue ?? 0 }
        set { sliderCell?.minValue = newValue }
    }
    public var maxValue: Double {
        get { sliderCell?.maxValue ?? 1 }
        set { sliderCell?.maxValue = newValue }
    }
    public override var doubleValue: Double {
        get { cell?.doubleValue ?? 0 }
        set { cell?.doubleValue = newValue; needsDisplay = true }
    }
    public var sliderType: NSSliderCell.SliderType {
        get { sliderCell?.sliderType ?? .linear }
        set { sliderCell?.sliderType = newValue }
    }
    public var isVertical: Bool {
        get { sliderCell?.isVertical ?? false }
        set { sliderCell?.isVertical = newValue }
    }
    public var numberOfTickMarks: Int {
        get { sliderCell?.numberOfTickMarks ?? 0 }
        set { sliderCell?.numberOfTickMarks = newValue }
    }
    public var allowsTickMarkValuesOnly: Bool {
        get { sliderCell?.allowsTickMarkValuesOnly ?? false }
        set { sliderCell?.allowsTickMarkValuesOnly = newValue }
    }
    public var userInterfaceLayoutDirection: NSUserInterfaceLayoutDirection {
        get { cell?.userInterfaceLayoutDirection ?? .leftToRight }
        set { cell?.userInterfaceLayoutDirection = newValue }
    }
    public func closestTickMarkValue(toValue value: Double) -> Double { sliderCell?.closestTickMarkValue(toValue: value) ?? value }

    open override func draw(_ dirtyRect: CGRect) {
        cell?.draw(withFrame: bounds, in: self)
    }

    /// A press: the cell starts tracking at the press, and the value under it goes out through target-action.
    open override func mouseDown(with event: NSEvent) {
        guard isEnabled, let cell else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard cell.startTracking(at: point, in: self) else { return }
        if let action { NSApp.sendAction(action, to: target, from: self) }
    }
}
