import Foundation
import SwiftUI
import AppKit
import Sparkle

/// Upstream's menu bar, from its own source: `CompositorApp.body`'s `.commands` (Sources/Overrides/CompositorApp.swift,
/// generated from Compositor/CompositorApp.swift) resolved like any panel ("AppMenus"). The shell builds its QMenuBar
/// from that tree, so titles, order, separators, shortcuts and enabled states are upstream's, re-read as the session
/// changes.
@MainActor enum AppMenus {
    static var nativeTextAction: NativeTextActionHandler?
    /// The app, over the shell's workspace (made once; `@NSApplicationDelegateAdaptor` hands it this delegate).
    static let delegate = CompositorApplicationDelegate(workspace: Workspace.shared)
    static func commands() -> (any View)? {
        NSApplicationDelegateStorage.delegate = delegate
        SPUStandardUpdaterController.checkHandler = { ShellProjects.pending.append("checkForUpdates") }
        // Select > All: same as a focused LayerTableView — canvas selectAll, never every layer.
        // While a layer is being renamed, leave the chord to the field (return true without selecting the canvas).
        NSApp.selectAllHandler = {
            let session = delegate.session
            if session.renamingLayerID != nil { return true }
            guard session.document != nil else { return false }
            session.selectAll()
            return true
        }
        // Register HeldModifiers' local monitor before the first flagsChanged from the shell.
        _ = HeldModifiers.shared
        NSApp.mainMenuProvider = { AppMenuBar.shared.make() }
        PopUpMenus.install()
        // openWindow(id: "editor") (ContentView's showEditor): the shell shows its window.
        OpenWindowAction.handler = { _ in ShellProjects.pending.append("showEditor") }
        return CompositorApp().body.commandsContent?()
    }

    /// One menu item: an action, a toggle, a submenu or a separator. `path` ("menu.item.subitem") names it for perform.
    struct Item {
        var title = "", path = "", enabled = true, checked: Bool? = nil, separator = false
        var key: String? = nil, modifiers = 0
        var items: [Item]? = nil
        var action: (() -> Void)? = nil
        var json: [String: Any] {
            if separator { return ["separator": true] }
            var o: [String: Any] = ["title": title, "path": path, "enabled": enabled]
            if let checked { o["checked"] = checked }
            if let key { o["key"] = key; o["modifiers"] = modifiers }
            if let items { o["items"] = items.map(\.json) }
            return o
        }
    }

    /// The macOS menu bar: the standard menus with their standard groups, the app's CommandGroups in their places
    /// (replacing a group's default items, or before / after it), its CommandMenus between View and Window. Items the
    /// system provides on the Mac (About, Quit, Full Screen, Minimize, Zoom) are shell requests here.
    static func menus() -> [Item] {
        guard let content = commands() else { return [] }
        let nodes = ViewResolver.resolveAll(content)
        func shell(_ title: String, _ request: String, key: String? = nil, modifiers: Int = 0, enabled: Bool = true) -> Item {
            Item(title: title, enabled: enabled, key: key, modifiers: modifiers, action: { ShellProjects.pending.append(request) })
        }
        // Standard groups, in menu order, with the items macOS puts there by default.
        let command = 1 << 4, control = 1 << 2
        var defaults: [String: [Item]] = [
            "appInfo": [shell("About Compositor", "about")],
            "appVisibility": [], "appTermination": [shell("Quit Compositor", "quit", key: "q", modifiers: command)],
            "newItem": [], "saveItem": [], "undoRedo": [], "pasteboard": [], "toolbar": [],
            "windowSize": [shell("Minimize", "minimize", key: "m", modifiers: command), shell("Zoom", "zoom")],
            "help": [shell("Compositor Help", "openHelp")],
        ]
        let layout: [(String, [String])] = [
            ("Compositor", ["appInfo", "appVisibility", "appTermination"]), ("File", ["newItem", "saveItem"]),
            ("Edit", ["undoRedo", "pasteboard"]), ("View", ["toolbar", "fullScreen"]),
        ]
        defaults["fullScreen"] = [shell("Enter Full Screen", "fullScreen", key: "f", modifiers: command | control)]
        var before: [String: [Item]] = [:], after: [String: [Item]] = [:]
        var custom: [Item] = []
        for node in nodes {
            switch node.kind {
            case "CommandGroup":
                let placement = node.stringParams["placement"] ?? "", position = node.stringParams["position"] ?? ""
                let items = describe(node.children, inheritedDisabled: false)
                switch position {
                case "replacing": defaults[placement] = items
                case "before": before[placement, default: []] += items
                default: after[placement, default: []] += items
                }
            case "CommandMenu":
                custom.append(Item(title: node.stringParams["title"] ?? "", items: describe(node.children, inheritedDisabled: false)))
            default: break
            }
        }
        func assemble(_ title: String, _ groups: [String]) -> Item {
            var items: [Item] = []
            for group in groups {
                let content = (before[group] ?? []) + (defaults[group] ?? []) + (after[group] ?? [])
                guard !content.isEmpty else { continue }
                if !items.isEmpty, items.last?.separator == false, content.first?.separator == false { items.append(Item(separator: true)) }
                items += content
            }
            return Item(title: title, items: items)
        }
        var menus = layout.map { assemble($0.0, $0.1) }
        menus += custom
        menus.append(assemble("Window", ["windowSize"]))
        menus.append(assemble("Help", ["help"]))
        // Paths, for perform.
        func number(_ items: inout [Item], prefix: String) {
            for index in items.indices {
                items[index].path = prefix + "\(index)"
                if items[index].items != nil { number(&items[index].items!, prefix: items[index].path + ".") }
            }
        }
        number(&menus, prefix: "")
        return menus
    }

    private static func title(_ node: RenderNode) -> String {
        if node.kind == "Text" { return node.stringParams["text"] ?? "" }
        for child in node.children { let t = title(child); if !t.isEmpty { return t } }
        return ""
    }

    private static func describe(_ nodes: [RenderNode], inheritedDisabled: Bool) -> [Item] {
        var result: [Item] = []
        for node in nodes {
            var off = inheritedDisabled
            var key: String?, modifiers = 0
            for modifier in node.modifiers {
                if case .disabled(let value) = modifier, value { off = true }
                if case .keyboardShortcut(let k, let m) = modifier { key = k; modifiers = m }
            }
            switch node.kind {
            case "Button":
                let action = node.handlers["action"]
                result.append(Item(title: title(node), enabled: !off && action != nil, key: key, modifiers: modifiers,
                                   action: action.map { handler in { handler(()) } }))
            case "Toggle":
                let isOn = node.boolParams["isOn"] ?? false
                let set = node.handlers["isOn"]
                result.append(Item(title: title(node), enabled: !off, checked: isOn, key: key, modifiers: modifiers,
                                   action: set.map { handler in { handler(!isOn) } }))
            case "Divider":
                if !result.isEmpty { result.append(Item(separator: true)) }
            case "Menu":
                let label = node.children.first.map(title) ?? ""
                result.append(Item(title: label, enabled: !off, items: describe(Array(node.children.dropFirst()), inheritedDisabled: off)))
            default:
                result += describe(node.children, inheritedDisabled: off)
            }
        }
        return result
    }

    /// Runs the item at `path` in the menus as they are now, if it is enabled — what choosing it (or its shortcut) does.
    @discardableResult static func perform(_ path: String) -> Bool {
        var items = menus()
        var found: Item?
        for part in path.split(separator: ".") {
            guard let index = Int(part), items.indices.contains(index) else { return false }
            found = items[index]
            items = found?.items ?? []
        }
        guard let item = found, item.enabled, let action = item.action else { return false }
        // The Qt text editor owns its selection, clipboard and local history. Its focused responder gets
        // standard text commands before the document, including actions chosen from the command palette.
        let textAction: String?
        if item.title == "Undo" || item.title.hasPrefix("Undo ") { textAction = "undo" }
        else if item.title == "Redo" || item.title.hasPrefix("Redo ") { textAction = "redo" }
        else { textAction = ["Cut": "cut", "Copy": "copy", "Paste": "paste", "All": "selectAll"][item.title] }
        if let textAction, let nativeTextAction,
           textAction.withCString({ nativeTextAction($0) }) != 0 { return true }
        action()
        return true
    }
}

public typealias NativeTextActionHandler = @convention(c) (UnsafePointer<CChar>?) -> Int32

/// The native host answers standard text actions only when an editable/selectable text control has focus.
@_cdecl("compositor_set_native_text_action_handler")
nonisolated public func compositorSetNativeTextActionHandler(_ handler: NativeTextActionHandler?) {
    onMain { AppMenus.nativeTextAction = handler }
}

/// The native palette hosts upstream's catalog and ranking rather than collecting the host's legacy actions.
@MainActor enum NativeCommandPalette {
    static var pending: (handle: UInt64, query: String, data: Data)?

    static func catalog(_ handle: UInt64) -> (menu: NSMenu, entries: [CommandPaletteEntry])? {
        guard let entry = Sessions.entries[handle] else { return nil }
        if let tab = entry.workspaceTabID {
            Workspace.shared.select(tab)
            guard Workspace.shared.current.id == tab else { return nil }
        }
        let menu = AppMenuBar.shared.make()
        let entries = CommandPaletteMenu.entries(in: menu, skipping: CommandPaletteController.skipped)
            + CommandPaletteEntry.layerCommands(for: entry.editor.session)
            + CommandPaletteEntry.tools(for: entry.editor.session)
        return (menu, entries)
    }
}

@_cdecl("compositor_command_palette_search")
nonisolated public func compositorCommandPaletteSearch(_ handle: UInt64, _ query: UnsafePointer<CChar>?,
                                                        _ output: UnsafeMutablePointer<UInt8>?, _ capacity: Int) -> Int64 {
    guard let query else { return -1 }
    let value = String(cString: query)
    return onMain {
        guard Sessions.entries[handle] != nil else { return -6 }
        if let output, let pending = NativeCommandPalette.pending, pending.handle == handle, pending.query == value {
            NativeCommandPalette.pending = nil
            guard capacity >= pending.data.count else { return -1 }
            pending.data.copyBytes(to: output, count: pending.data.count)
            return Int64(pending.data.count)
        }
        guard let catalog = NativeCommandPalette.catalog(handle) else { return -6 }
        let rows = CommandPaletteSearch.rank(catalog.entries, query: value).map { entry -> [String: Any] in
            var row: [String: Any] = ["id": entry.id, "title": entry.title, "enabled": entry.isEnabled, "checked": entry.isOn]
            if let shortcut = entry.shortcut { row["shortcut"] = shortcut }
            return row
        }
        guard let data = try? JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys]) else { return -5 }
        guard let output else { NativeCommandPalette.pending = (handle, value, data); return Int64(data.count) }
        guard capacity >= data.count else { return -1 }
        data.copyBytes(to: output, count: data.count)
        return Int64(data.count)
    }
}

@_cdecl("compositor_command_palette_perform")
nonisolated public func compositorCommandPalettePerform(_ handle: UInt64, _ id: UnsafePointer<CChar>?) -> Int32 {
    guard let id else { return -1 }
    let value = String(cString: id)
    return onMain {
        guard let catalog = NativeCommandPalette.catalog(handle),
              let entry = catalog.entries.first(where: { $0.id == value }), entry.isEnabled else { return -1 }
        // Menu entries deliberately capture a weak root, as upstream does. Retain it through the dispatch.
        withExtendedLifetime(catalog.menu) { entry.perform() }
        return 0
    }
}

/// `NSApp.mainMenu`: the menus the Qt menu bar shows, as live `NSMenu`s for code that reads or runs the menu bar (the
/// command palette). SwiftUI refreshes a menu just before it opens, through its delegate; so does this — each menu
/// re-reads its items from `AppMenus.menus()` when asked (`menuNeedsUpdate`), titles, checkmarks and enabled states
/// included. As with SwiftUI, a disabled item has no action. Choosing an item runs it by its path, as the shell does.
@MainActor final class AppMenuBar: NSMenuDelegate, NSSelectorDispatching {
    static let shared = AppMenuBar()
    private static let choose = Selector("performMenuPath:")

    func make() -> NSMenu {
        let bar = NSMenu(title: "Main Menu")
        bar.delegate = self
        fill(bar, with: AppMenus.menus())
        return bar
    }

    var menuNeedsUpdate: ((NSMenu) -> Void)? { { [weak self] menu in self?.refresh(menu) } }

    private func refresh(_ menu: NSMenu) {
        var indices: [Int] = []
        var current = menu
        while let parent = current.supermenu {
            guard let index = parent.items.firstIndex(where: { $0.submenu === current }) else { return }
            indices.insert(index, at: 0)
            current = parent
        }
        var items = AppMenus.menus()
        for index in indices {
            guard items.indices.contains(index), let children = items[index].items else { return }
            items = children
        }
        fill(menu, with: items)
    }

    private func fill(_ menu: NSMenu, with items: [AppMenus.Item]) {
        menu.removeAllItems()
        for item in items {
            if item.separator { menu.addItem(.separator()); continue }
            let entry = NSMenuItem(title: item.title, action: item.items == nil && item.enabled ? Self.choose : nil,
                                   keyEquivalent: item.key ?? "")
            entry.keyEquivalentModifierMask = Self.flags(item.modifiers)
            entry.isEnabled = item.enabled
            entry.state = item.checked == true ? .on : .off
            entry.representedObject = item.path
            entry.target = self
            if let children = item.items {
                let submenu = NSMenu(title: item.title)
                submenu.delegate = self
                fill(submenu, with: children)
                entry.submenu = submenu
            }
            menu.addItem(entry)
        }
    }

    /// SwiftUI's `EventModifiers` bits (what AppMenus.Item.modifiers holds) as AppKit's key-equivalent mask.
    private static func flags(_ modifiers: Int) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers & (1 << 1) != 0 { flags.insert(.shift) }
        if modifiers & (1 << 2) != 0 { flags.insert(.control) }
        if modifiers & (1 << 3) != 0 { flags.insert(.option) }
        if modifiers & (1 << 4) != 0 { flags.insert(.command) }
        return flags
    }

    func compatPerform(_ selector: Selector, with argument: Any?) -> Bool {
        guard selector == Self.choose, let path = (argument as? NSMenuItem)?.representedObject as? String else { return false }
        return AppMenus.perform(path)
    }
    func compatResponds(to selector: Selector) -> Bool { selector == Self.choose }
}

/// The menu bar `NSApp.mainMenu` reads in a process the shell never set up (a test host); retained for the caller.
@_cdecl("compositor_main_menu")
nonisolated public func compositorMainMenu() -> UnsafeMutableRawPointer? {
    MainActor.assumeIsolated { Unmanaged.passRetained(AppMenuBar.shared.make()).toOpaque() }
}

/// The menu bar as JSON: [{title, items: [{title, path, enabled, checked?, key?, modifiers?, items?} | {separator}]}].
@_cdecl("compositor_app_menus")
nonisolated public func compositorAppMenus(_ output: UnsafeMutablePointer<UInt8>?, _ capacity: Int) -> Int64 {
    onMain {
        // Size query, then fill: the fill copies what the size query built instead of resolving the menus again.
        if let output, let data = pendingMenus {
            pendingMenus = nil
            guard capacity >= data.count else { return -1 }
            data.copyBytes(to: output, count: data.count)
            return Int64(data.count)
        }
        let json = AppMenus.menus().map(\.json)
        // Sorted keys: the same menus give the same bytes, so the shell can tell nothing changed.
        guard let data = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]) else { return -5 }
        guard let output else { pendingMenus = data; return Int64(data.count) }
        guard capacity >= data.count else { return -1 }
        data.copyBytes(to: output, count: data.count)
        return Int64(data.count)
    }
}

/// The menus a `compositor_app_menus` size query built, waiting for the fill call that follows it.
nonisolated(unsafe) private var pendingMenus: Data?

/// Chooses the menu item at `path` (see compositor_app_menus); 0 when it ran, -1 when it is gone or disabled.
@_cdecl("compositor_app_menu_perform")
nonisolated public func compositorAppMenuPerform(_ path: UnsafePointer<CChar>?) -> Int32 {
    guard let path else { return -1 }
    let value = String(cString: path)
    return onMain { AppMenus.perform(value) ? 0 : -1 }
}

/// What upstream's ProjectController does from the menus (save, export, sizes, open, ...), done by the shell: each call
/// queues a request the shell takes after dispatching the menu item (compositor_take_shell_requests).
@MainActor final class ShellProjects {
    weak var workspace: ProjectWorkspace?
    init(workspace: ProjectWorkspace) { self.workspace = workspace }
    static var pending: [String] = []
    private func request(_ name: String) { Self.pending.append(name) }

    var canStart: Bool { workspace?.current.controller.canStart ?? true }
    /// The current tab's window, as upstream's delegate's `projects` (the current ProjectController) keeps it.
    var window: NSWindow? {
        get {
            guard let workspace else { return nil }
            if let window = workspace.current.controller.window { return window }
            // Qt hosts the workspace without embedding ProjectWindowBridge's native view. Use the current
            // canvas's existing window so upstream's Close Project guard can reach the shell request.
            guard let (handle, entry) = Sessions.entries.first(where: { $0.value.workspaceTabID == workspace.current.id }) else { return nil }
            return UpstreamCanvases.canvas(handle, entry).window
        }
        set { workspace?.current.controller.window = newValue }
    }
    func save(asNew: Bool = false) async -> Bool { request(asNew ? "saveAs" : "save"); return true }
    func exportPNG() async { request("exportPNG") }
    func exportJPEG() async { request("exportJPEG") }
    /// Tip File › Export As… / Export JPEG… — shell still runs PNG/JPEG paths; PDF lands with the Export As port.
    func exportAs(start: ExportFormat? = nil) async {
        switch start {
        case .jpeg: request("exportJPEG")
        case .pdf: request("exportPDF")
        case .exr: request("exportAs:exr")
        case .tiff: request("exportAs:tiff")
        case .png, nil: request("exportPNG")
        }
    }
    func canvasSize() async { request("canvasSize") }
    func imageSize() async { request("imageSize") }
    func trim() async { request("trim") }
    /// With a URL (File > Open Recent) that project opens directly; without one the shell asks for it.
    @discardableResult func open(_ suppliedURL: URL? = nil) async -> Bool {
        request(suppliedURL.map { "open:" + $0.path } ?? "open"); return true
    }
    func newCanvas() async { request("newCanvas") }
    func gridSettings() async { request("gridSettings") }
    func close(_ window: NSWindow?) async { request("close") }
}

/// The requests queued by the last menu actions, as a JSON array of names (same buffer convention as the state call).
@_cdecl("compositor_take_shell_requests")
nonisolated public func compositorTakeShellRequests(_ output: UnsafeMutablePointer<UInt8>?, _ capacity: Int) -> Int64 {
    onMain {
        let data = (try? JSONEncoder().encode(ShellProjects.pending)) ?? Data("[]".utf8)
        guard let output else { return Int64(data.count) }
        guard capacity >= data.count else { return -1 }
        data.copyBytes(to: output, count: data.count)
        ShellProjects.pending = []
        return Int64(data.count)
    }
}

/// A project the shell saved or opened: upstream's recent list (RecentProjects, which File > Open Recent shows).
@_cdecl("compositor_note_recent_project")
nonisolated public func compositorNoteRecentProject(_ path: UnsafePointer<CChar>?) {
    guard let path else { return }
    let url = URL(fileURLWithPath: String(cString: path))
    onMain { RecentProjects.shared.note(url) }
}

/// The app came to the front (a window was activated): as NSApplication posts it — upstream re-checks its recent list.
@_cdecl("compositor_app_did_become_active")
nonisolated public func compositorAppDidBecomeActive() {
    onMain { Foundation.NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil) }
}

@_cdecl("compositor_app_did_resign_active")
nonisolated public func compositorAppDidResignActive() {
    onMain { Foundation.NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil) }
}

@_cdecl("compositor_menu_did_end_tracking")
nonisolated public func compositorMenuDidEndTracking() {
    onMain { Foundation.NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: nil) }
}

extension ProjectWindowBridge {
    /// The Linux delegate's `projects` (ShellProjects) stands for the current tab's controller.
    @MainActor init(controller projects: ShellProjects) {
        self.init(controller: (projects.workspace ?? Workspace.shared).current.controller)
    }
}

extension ProjectWindowView {
    /// The Linux delegate's `projects` (ShellProjects) stands for the current tab's controller.
    convenience init(controller projects: ShellProjects) {
        self.init(controller: (projects.workspace ?? Workspace.shared).current.controller)
    }
}

/// Context and pop-up menus (`NSMenu.popUp`): the shell shows the menu at the pointer ("popUpMenu" request), reading its
/// items here, and reports the choice back.
@MainActor enum PopUpMenus {
    struct Item: Encodable {
        let id: Int
        let title: String
        let enabled: Bool
        let checked: Bool
        let separator: Bool
        let children: [Item]?
    }
    struct Choice { let menu: NSMenu; let index: Int; let enabled: Bool }
    struct Presentation {
        let menu: NSMenu
        let finish: (Int?) -> Void
        var choices: [Int: Choice] = [:]
    }
    static var current: Presentation?
    static func install() {
        NSMenu.presenter = { menu, finish in
            current?.finish(nil)
            current = Presentation(menu: menu, finish: finish)
            ShellProjects.pending.append("popUpMenu")
        }
    }
    static func items() -> [Item] {
        guard var presentation = current else { return [] }
        presentation.choices.removeAll()
        var nextID = 0
        func describe(_ menu: NSMenu, enabled: Bool) -> [Item] {
            menu.update()
            return menu.items.enumerated().filter { !$0.element.isHidden }.map { index, item in
                let id = nextID; nextID += 1
                let active = enabled && item.isEnabled
                let children = item.submenu.map { describe($0, enabled: active) }
                if children == nil, !item.isSeparatorItem {
                    presentation.choices[id] = Choice(menu: menu, index: index, enabled: active)
                }
                return Item(id: id, title: item.title, enabled: active, checked: item.state == .on,
                            separator: item.isSeparatorItem, children: children)
            }
        }
        let result = describe(presentation.menu, enabled: true)
        current = presentation
        return result
    }
}

/// The recursive items of the waiting menu, including IDs for leaf dispatch (same buffer convention
/// as the state call); empty when none is waiting.
@_cdecl("compositor_popup_menu_items")
nonisolated public func compositorPopUpMenuItems(_ output: UnsafeMutablePointer<UInt8>?, _ capacity: Int) -> Int64 {
    onMain {
        let items = PopUpMenus.items()
        let data = (try? JSONEncoder().encode(items)) ?? Data("[]".utf8)
        guard let output else { return Int64(data.count) }
        guard capacity >= data.count else { return -1 }
        data.copyBytes(to: output, count: data.count)
        return Int64(data.count)
    }
}

/// The shown menu closed: `index` is the serialized leaf ID, or -1 when it was dismissed.
@_cdecl("compositor_popup_menu_choose")
nonisolated public func compositorPopUpMenuChoose(_ index: Int32) {
    onMain {
        guard let current = PopUpMenus.current else { return }
        PopUpMenus.current = nil
        if let choice = current.choices[Int(index)], choice.enabled {
            choice.menu.performActionForItem(at: choice.index)
        }
        current.finish(nil)
    }
}

/// The shell's event pump (one turn of Qt's event loop, answering whether the left button is still down): AppKit
/// tracking loops wait on it in NSWindow.nextEvent, as they wait on the run loop on the Mac.
@_cdecl("compositor_register_event_pump")
nonisolated public func compositorRegisterEventPump(_ pump: (@convention(c) () -> Int32)?) {
    onMain { NSApp.eventPump = pump.map { pump in { pump() != 0 } } }
}
