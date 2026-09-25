import Foundation
import SwiftUI
import Sparkle

/// Upstream's menu bar, from its own source: `CompositorApp.body`'s `.commands` (Sources/Overrides/CompositorApp.swift,
/// generated from Compositor/CompositorApp.swift) resolved like any panel ("AppMenus"). The shell builds its QMenuBar
/// from that tree, so titles, order, separators, shortcuts and enabled states are upstream's, re-read as the session
/// changes.
@MainActor enum AppMenus {
    /// The app, over the shell's workspace (made once; `@NSApplicationDelegateAdaptor` hands it this delegate).
    static let delegate = CompositorApplicationDelegate(workspace: Workspace.shared)
    static func commands() -> (any View)? {
        NSApplicationDelegateStorage.delegate = delegate
        SPUStandardUpdaterController.checkHandler = { ShellProjects.pending.append("checkForUpdates") }
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
            "help": [Item(title: "Compositor Help", enabled: false)],
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
        action()
        return true
    }
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
    var window: NSWindow? { nil }
    func save(asNew: Bool = false) async -> Bool { request(asNew ? "saveAs" : "save"); return true }
    func exportPNG() async { request("exportPNG") }
    func exportJPEG() async { request("exportJPEG") }
    func canvasSize() async { request("canvasSize") }
    func imageSize() async { request("imageSize") }
    func trim() async { request("trim") }
    @discardableResult func open(_ suppliedURL: URL? = nil) async -> Bool { request("open"); return true }
    func newCanvas() async { request("newCanvas") }
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
