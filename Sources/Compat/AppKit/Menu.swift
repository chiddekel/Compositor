import Foundation

/// AppKit's menus, headless: the item tree, validation and choosing an item. The Qt shell draws the real menu bar (from
/// the app's `.commands`, Sources/LinuxBridge/AppMenus.swift); these are what code that reads or runs menus works with.
@MainActor open class NSMenu {
    /// Menu tracking notifications HeldModifiers observes (a key released while a menu is open never reaches the app).
    public static let didBeginTrackingNotification = Notification.Name("NSMenuDidBeginTrackingNotification")
    public static let didEndTrackingNotification = Notification.Name("NSMenuDidEndTrackingNotification")
    public static let didAddItemNotification = Notification.Name("NSMenuDidAddItemNotification")

    public var title: String
    public private(set) var items: [NSMenuItem] = []
    public weak var delegate: (any NSMenuDelegate)?
    public weak var supermenu: NSMenu?
    public var autoenablesItems = true

    public init(title: String = "") { self.title = title }

    public var numberOfItems: Int { items.count }
    public func addItem(_ item: NSMenuItem) { insertItem(item, at: items.count) }
    @discardableResult public func addItem(withTitle title: String, action: Selector?, keyEquivalent: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        addItem(item)
        return item
    }
    public func insertItem(_ item: NSMenuItem, at index: Int) {
        item.menu = self
        item.submenu?.supermenu = self
        items.insert(item, at: index)
        NotificationCenter.default.post(name: Self.didAddItemNotification, object: self, userInfo: ["NSMenuItemIndex": index])
    }
    public func removeItem(at index: Int) { items[index].menu = nil; items.remove(at: index) }
    public func removeItem(_ item: NSMenuItem) { if let index = index(of: item) { removeItem(at: index) } }
    public func removeAllItems() { items.forEach { $0.menu = nil }; items.removeAll() }
    public func item(at index: Int) -> NSMenuItem? { items.indices.contains(index) ? items[index] : nil }
    public func item(withTitle title: String) -> NSMenuItem? { items.first { $0.title == title } }
    public func index(of item: NSMenuItem) -> Int? { items.firstIndex { $0 === item } }

    /// Enables each item as AppKit's auto-enabling does: an item with an action is enabled when its target answers it
    /// (asking `validateMenuItem(_:)` when the target validates); items without an action keep what they were given.
    public func update() {
        guard autoenablesItems else { return }
        for item in items where !item.isSeparatorItem && item.submenu == nil {
            guard let action = item.action else { continue }
            let target = item.target ?? NSApp.keyWindow?.firstResponder
            if let validating = target as? NSMenuItemValidation {
                item.isEnabled = validating.validateMenuItem(item)
            } else if let dispatching = target as? NSSelectorDispatching {
                item.isEnabled = dispatching.compatResponds(to: action)
            }
        }
    }

    /// Shows the menu at `location` in `view` (AppKit tracks it there and runs the chosen item's action). The host draws
    /// it (`presenter`), which reports the chosen item's index, or nil when the menu was dismissed; without a host the
    /// menu opens and closes with nothing chosen.
    @discardableResult public func popUp(positioning item: NSMenuItem?, at location: NSPoint, in view: NSView?) -> Bool {
        delegate?.menuNeedsUpdate?(self)
        update()
        delegate?.menuWillOpen(self)
        NotificationCenter.default.post(name: Self.didBeginTrackingNotification, object: self)
        let finish: (Int?) -> Void = { [self] index in
            if let index { performActionForItem(at: index) }
            delegate?.menuDidClose(self)
            NotificationCenter.default.post(name: Self.didEndTrackingNotification, object: self)
        }
        guard let presenter = Self.presenter else { finish(nil); return false }
        presenter(self, finish)
        return true
    }
    /// Installed by the host: shows `menu` where the pointer is and calls back with the chosen item's index (nil:
    /// dismissed).
    public static var presenter: ((NSMenu, @escaping (Int?) -> Void) -> Void)?

    /// Chooses the item at `index`, as a click on it does: its action goes to its target (or the responder chain).
    public func performActionForItem(at index: Int) {
        guard let item = item(at: index), item.isEnabled, let action = item.action else { return }
        NSApp.sendAction(action, to: item.target, from: item)
    }
}

/// What a menu tells its delegate. `menuNeedsUpdate` is an optional method on the Mac, called as
/// `delegate?.menuNeedsUpdate?(menu)`; without the Objective-C runtime an optional requirement is a closure property,
/// so that call compiles unchanged. A delegate may supply the closure (AppMenuBar) or implement the method
/// (`func menuNeedsUpdate(_:)`), which the default closure calls.
@MainActor public protocol NSMenuDelegate: AnyObject {
    var menuNeedsUpdate: ((NSMenu) -> Void)? { get }
    func menuNeedsUpdate(_ menu: NSMenu)
    func menuWillOpen(_ menu: NSMenu)
    func menuDidClose(_ menu: NSMenu)
    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?)
}
extension NSMenuDelegate {
    public var menuNeedsUpdate: ((NSMenu) -> Void)? { { [weak self] menu in self?.menuNeedsUpdate(menu) } }
    public func menuNeedsUpdate(_ menu: NSMenu) {}
    public func menuWillOpen(_ menu: NSMenu) {}
    public func menuDidClose(_ menu: NSMenu) {}
    public func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {}
}

@MainActor public protocol NSMenuItemValidation: AnyObject {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool
}

@MainActor open class NSMenuItem {
    public var title: String
    public var action: Selector?
    public weak var target: AnyObject?
    public var keyEquivalent: String
    public var keyEquivalentModifierMask: NSEvent.ModifierFlags = [.command]
    public var isEnabled = true
    public var isHidden = false
    public var state: NSControl.StateValue = .off
    public var tag = 0
    public var representedObject: Any?
    public var image: NSImage?
    /// A styled title (a font face shown in its own face); `title` stays the plain string.
    public var attributedTitle: NSAttributedString?
    public var toolTip: String?
    public var indentationLevel = 0
    public internal(set) weak var menu: NSMenu?
    public var submenu: NSMenu? { didSet { submenu?.supermenu = menu } }
    public let isSeparatorItem: Bool
    public var hasSubmenu: Bool { submenu != nil }

    public init(title: String, action: Selector?, keyEquivalent: String) {
        self.title = title; self.action = action; self.keyEquivalent = keyEquivalent; isSeparatorItem = false
    }
    private init(separator: Void) { title = ""; keyEquivalent = ""; isSeparatorItem = true }
    public static func separator() -> NSMenuItem { NSMenuItem(separator: ()) }
}

extension NSControl {
    public struct StateValue: RawRepresentable, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let off = StateValue(rawValue: 0), on = StateValue(rawValue: 1), mixed = StateValue(rawValue: -1)
    }
}
