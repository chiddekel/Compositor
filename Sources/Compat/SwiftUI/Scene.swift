// The App/Scene/Commands layer, as far as upstream's CompositorApp.swift uses it. Nothing here opens windows (the Qt
// shell owns the one editor window); what matters is `.commands`: the shell resolves those views as the menu bar
// (see Sources/LinuxBridge/AppMenus.swift), so the menus are upstream's own, titles, order, shortcuts and enabled
// states included.

import Foundation
import CoreGraphics

public protocol Scene {}

@resultBuilder public enum SceneBuilder {
    public static func buildBlock<S: Scene>(_ scene: S) -> S { scene }
}

public protocol App {
    associatedtype Body: Scene
    @SceneBuilder var body: Body { get }
    init()
}

public struct Window<Content: View>: Scene {
    public let title: String, id: String
    let content: () -> Content
    public init(_ title: String, id: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title; self.id = id; self.content = content
    }
}

public struct WindowGroup<Content: View>: Scene {
    let content: () -> Content
    public init(@ViewBuilder content: @escaping () -> Content) { self.content = content }
    public init(id: String, @ViewBuilder content: @escaping () -> Content) { self.content = content }
}

/// A scene with its settings; `commands` is the menu content the app declared.
public struct ModifiedScene: Scene {
    public let base: any Scene
    public let commands: (() -> any View)?
}

public struct WindowToolbarStyle: Sendable {
    public static func unifiedCompact(showsTitle: Bool = true) -> WindowToolbarStyle { WindowToolbarStyle() }
    public static func unified(showsTitle: Bool = true) -> WindowToolbarStyle { WindowToolbarStyle() }
    public static let expanded = WindowToolbarStyle(), automatic = WindowToolbarStyle()
}

public struct WindowPlacement {
    public let size: CGSize?
    public init(size: CGSize? = nil) { self.size = size }
    public init(_ position: Any? = nil, size: CGSize? = nil) { self.size = size }
}
public struct DisplayProxy { public var visibleRect = CGRect(x: 0, y: 0, width: 1920, height: 1080) }
public struct WindowPlacementContext { public var defaultDisplay = DisplayProxy() }
public struct WindowLayoutRoot {}

extension Scene {
    public func defaultSize(width: CGFloat, height: CGFloat) -> ModifiedScene { passing() }
    public func handlesExternalEvents(matching conditions: Set<String>) -> ModifiedScene { passing() }
    public func defaultWindowPlacement(_ placement: @escaping (WindowLayoutRoot, WindowPlacementContext) -> WindowPlacement) -> ModifiedScene { passing() }
    public func windowToolbarStyle(_ style: WindowToolbarStyle) -> ModifiedScene { passing() }
    public func windowResizability(_ resizability: Any) -> ModifiedScene { passing() }
    public func commands<Content: View>(@ViewBuilder content: @escaping () -> Content) -> ModifiedScene {
        ModifiedScene(base: self, commands: { content() })
    }
    private func passing() -> ModifiedScene {
        if let scene = self as? ModifiedScene { return scene }
        return ModifiedScene(base: self, commands: nil)
    }
    /// The app's `.commands` content, wherever it sits in the scene's modifiers.
    public var commandsContent: (() -> any View)? { (self as? ModifiedScene)?.commands }
}

/// Where a `CommandGroup` goes among the standard menus.
public struct CommandGroupPlacement: Sendable, Equatable {
    public let name: String
    public static let appInfo = Self(name: "appInfo"), appSettings = Self(name: "appSettings"), systemServices = Self(name: "systemServices")
    public static let appVisibility = Self(name: "appVisibility"), appTermination = Self(name: "appTermination")
    public static let newItem = Self(name: "newItem"), saveItem = Self(name: "saveItem"), importExport = Self(name: "importExport")
    public static let printItem = Self(name: "printItem"), undoRedo = Self(name: "undoRedo"), pasteboard = Self(name: "pasteboard")
    public static let textEditing = Self(name: "textEditing"), textFormatting = Self(name: "textFormatting")
    public static let toolbar = Self(name: "toolbar"), sidebar = Self(name: "sidebar"), windowSize = Self(name: "windowSize")
    public static let windowList = Self(name: "windowList"), singleWindowList = Self(name: "singleWindowList")
    public static let windowArrangement = Self(name: "windowArrangement"), help = Self(name: "help")
}

/// Menu content replacing, or placed before / after, one of the standard groups. Resolves to a "CommandGroup" node
/// (`placement`, `position` = replacing | before | after) holding the items.
public struct CommandGroup<Content: View>: View, PrimitiveView {
    let placement: CommandGroupPlacement, position: String
    let content: Content
    public init(replacing placement: CommandGroupPlacement, @ViewBuilder addition: () -> Content) {
        self.placement = placement; position = "replacing"; content = addition()
    }
    public init(before placement: CommandGroupPlacement, @ViewBuilder addition: () -> Content) {
        self.placement = placement; position = "before"; content = addition()
    }
    public init(after placement: CommandGroupPlacement, @ViewBuilder addition: () -> Content) {
        self.placement = placement; position = "after"; content = addition()
    }
    public var _childViews: [any View] { [content] }
    public func _makeNode(children: [RenderNode]) -> RenderNode {
        var node = RenderNode(kind: "CommandGroup")
        node.stringParams["placement"] = placement.name
        node.stringParams["position"] = position
        node.children = children
        return node
    }
}

/// A top-level menu of the app's own ("Select", "Image", ...).
public struct CommandMenu<Content: View>: View, PrimitiveView {
    let title: String
    let content: Content
    public init(_ title: String, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }
    public var _childViews: [any View] { [content] }
    public func _makeNode(children: [RenderNode]) -> RenderNode {
        var node = RenderNode(kind: "CommandMenu")
        node.stringParams["title"] = title
        node.children = children
        return node
    }
}

/// `@NSApplicationDelegateAdaptor`: the delegate the host installed (`NSApplicationDelegateStorage.delegate`).
@MainActor public enum NSApplicationDelegateStorage { public static var delegate: AnyObject? }
@MainActor @propertyWrapper public struct NSApplicationDelegateAdaptor<Delegate: AnyObject> {
    public init(_ type: Delegate.Type) {}
    public var wrappedValue: Delegate { NSApplicationDelegateStorage.delegate as! Delegate }
}
