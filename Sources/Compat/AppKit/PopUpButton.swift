import Foundation

/// A pop-up button, as AppKit's: a button showing its menu's selected item, which opens the menu when pressed and sends
/// its action once an item is chosen. The menu is the view's `menu`; its delegate hears the menu open, highlight items
/// and close, in AppKit's order (`openMenu` / `highlight` / `choose` / `closeMenu`, driven by whoever draws the menu).
@MainActor open class NSPopUpButton: NSButton {
    public var pullsDown: Bool
    public var autoenablesItems = true
    public var preferredEdge: NSRectEdge = .maxY
    private let popUpCell = NSPopUpButtonCell()
    /// Whether the menu is open (between `openMenu` and `closeMenu`).
    public private(set) var isMenuOpen = false

    public init(frame: CGRect, pullsDown: Bool) {
        self.pullsDown = pullsDown
        super.init(frame: frame)
        menu = NSMenu()
        popUpCell.controlView = self
    }
    public required init?(coder: NSCoder) { nil }
    public override convenience init(frame frameRect: CGRect) { self.init(frame: frameRect, pullsDown: false) }

    open var cell: NSPopUpButtonCell? { popUpCell }

    public var itemArray: [NSMenuItem] { menu?.items ?? [] }
    public var numberOfItems: Int { itemArray.count }
    public var itemTitles: [String] { itemArray.map(\.title) }
    public var lastItem: NSMenuItem? { itemArray.last }
    public func item(at index: Int) -> NSMenuItem? { menu?.item(at: index) }
    public func item(withTitle title: String) -> NSMenuItem? { menu?.item(withTitle: title) }
    public func indexOfItem(withTitle title: String) -> Int { itemArray.firstIndex { $0.title == title } ?? -1 }
    public func index(of item: NSMenuItem) -> Int { itemArray.firstIndex { $0 === item } ?? -1 }

    public func addItem(withTitle title: String) {
        // As AppKit's: a title already in the menu moves to the end rather than appearing twice.
        removeItem(withTitle: title)
        menu?.addItem(NSMenuItem(title: title, action: nil, keyEquivalent: ""))
        selectFirstIfNone()
    }
    public func addItems(withTitles titles: [String]) { titles.forEach(addItem(withTitle:)) }
    public func insertItem(withTitle title: String, at index: Int) {
        removeItem(withTitle: title)
        menu?.insertItem(NSMenuItem(title: title, action: nil, keyEquivalent: ""), at: min(max(0, index), numberOfItems))
        selectFirstIfNone()
    }
    public func removeItem(at index: Int) {
        guard itemArray.indices.contains(index) else { return }
        menu?.removeItem(at: index)
        selectFirstIfNone()
    }
    public func removeItem(withTitle title: String) {
        let index = indexOfItem(withTitle: title)
        if index >= 0 { removeItem(at: index) }
    }
    public func removeAllItems() { menu?.removeAllItems(); selected = nil }

    /// The selected item (AppKit keeps it as the item whose state is on); a pop-up (not pull-down) always has one
    /// while it has items.
    private weak var selected: NSMenuItem?
    private func selectFirstIfNone() {
        guard !pullsDown, indexOfSelectedItem < 0 else { return }
        selectItem(at: itemArray.firstIndex { !$0.isSeparatorItem } ?? -1)
    }
    public var indexOfSelectedItem: Int {
        guard let selected else { return -1 }
        return itemArray.firstIndex { $0 === selected } ?? -1
    }
    public var selectedItem: NSMenuItem? { item(at: indexOfSelectedItem) }
    public var titleOfSelectedItem: String? { selectedItem?.title }
    public func selectItem(at index: Int) {
        selected = item(at: index)
        for item in itemArray { item.state = item === selected ? .on : .off }
    }
    public func selectItem(withTitle title: String) { selectItem(at: indexOfItem(withTitle: title)) }
    public func select(_ item: NSMenuItem?) { selectItem(at: item.map(index(of:)) ?? -1) }
    @discardableResult public func selectItem(withTag tag: Int) -> Bool {
        guard let index = itemArray.firstIndex(where: { $0.tag == tag }) else { return false }
        selectItem(at: index)
        return true
    }
    public func synchronizeTitleAndSelectedItem() {}

    open override var title: String {
        get { pullsDown ? (itemArray.first?.title ?? "") : (titleOfSelectedItem ?? "") }
        set {}
    }

    // MARK: Menu tracking, as AppKit runs it while its menu is shown

    /// The menu opens: the delegate updates it (`menuNeedsUpdate`), items are validated, `menuWillOpen` runs.
    public func openMenu() {
        guard !isMenuOpen, let menu else { return }
        isMenuOpen = true
        menu.delegate?.menuNeedsUpdate?(menu)
        if autoenablesItems { menu.update() }
        menu.delegate?.menuWillOpen(menu)
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: menu)
    }
    /// The pointer is over `item` (nil: over none).
    public func highlight(_ item: NSMenuItem?) {
        guard let menu else { return }
        if !isMenuOpen { openMenu() }
        menu.delegate?.menu(menu, willHighlight: item)
    }
    /// `item` is chosen: it becomes the selection and the button sends its action, as the menu finishes closing.
    public func choose(_ item: NSMenuItem) {
        guard let index = itemArray.firstIndex(where: { $0 === item }), item.isEnabled else { return }
        let opened = !isMenuOpen
        if opened { openMenu() }
        selectItem(at: index)
        if let action = item.action { NSApp.sendAction(action, to: item.target, from: item) }
        else { sendAction(action, to: target) }
        if opened { closeMenu() }
    }
    /// The menu closes (after a choice, or cancelled).
    public func closeMenu() {
        guard isMenuOpen, let menu else { return }
        isMenuOpen = false
        menu.delegate?.menuDidClose(menu)
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: menu)
    }

    open override func performClick(_ sender: Any?) { openMenu() }
    open override var intrinsicContentSize: NSSize {
        let longest = itemArray.map(\.title.count).max() ?? 0
        return NSSize(width: CGFloat(longest) * 7 + 34, height: 22)
    }
}

/// The pop-up button's cell: how its title is laid out.
@MainActor open class NSPopUpButtonCell: NSActionCell {}

public enum NSRectEdge: UInt, Sendable { case minX = 0, minY = 1, maxX = 2, maxY = 3 }

extension NSControl {
    /// The shape of a control's bezel (macOS 26): a capsule, a rounded rectangle, a circle.
    public enum BorderShape: Int, Sendable { case automatic = 0, capsule, roundedRectangle, circle }
}
