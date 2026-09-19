import Foundation

/// One headless project tab. File loading and saving stay in the host; the tab
/// keeps identity, optional URL text, manifest metadata, and editor state.
final class ProjectTab: Identifiable {
    let id = UUID()
    let session: EditorSession
    let defaultName: String
    var urlString: String?
    var manifest: ProjectManifest?

    var title: String {
        urlString?.split(separator: "/").last.map(String.init) ?? defaultName
    }

    init(name: String, urlString: String? = nil, manifest: ProjectManifest? = nil,
         session: EditorSession = EditorSession()) {
        defaultName = name
        self.urlString = urlString
        self.manifest = manifest
        self.session = session
    }
}

/// Portable tab and selection state. The host owns filesystem and window work.
final class ProjectWorkspace {
    private(set) var tabs: [ProjectTab]
    private(set) var selectedID: UUID
    private var nextNumber = 2

    var current: ProjectTab { tabs.first { $0.id == selectedID } ?? tabs[0] }
    var selectedTab: ProjectTab { current }
    var canSwitch: Bool {
        let session = current.session
        return session.brushStroke == nil && session.warpStroke == nil && session.filterEdit == nil
    }

    init() {
        let tab = ProjectTab(name: "Untitled")
        tabs = [tab]
        selectedID = tab.id
    }

    @discardableResult
    func addTab(urlString: String? = nil, manifest: ProjectManifest? = nil,
                reuseEmpty: Bool = true) -> ProjectTab {
        if let urlString, let existing = tabs.first(where: { $0.urlString == urlString }) {
            selectedID = existing.id
            return existing
        }
        if reuseEmpty, tabs.count == 1, current.session.document == nil {
            current.urlString = urlString
            current.manifest = manifest
            return current
        }
        let tab = ProjectTab(name: "Untitled \(nextNumber)", urlString: urlString, manifest: manifest)
        nextNumber += 1
        tabs.append(tab)
        selectedID = tab.id
        return tab
    }

    @discardableResult
    func newCanvas() -> ProjectTab {
        guard canSwitch else { return current }
        return addTab(reuseEmpty: false)
    }

    @discardableResult
    func addTab(url: String?, manifest: ProjectManifest? = nil,
                reuseEmpty: Bool = true) -> ProjectTab {
        addTab(urlString: url, manifest: manifest, reuseEmpty: reuseEmpty)
    }

    func select(_ id: UUID) {
        guard canSwitch, tabs.contains(where: { $0.id == id }) else { return }
        selectedID = id
    }

    func removeTab(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: index)
        if tabs.isEmpty {
            _ = addTab(reuseEmpty: false)
        } else if selectedID == id {
            selectedID = tabs[min(index, tabs.count - 1)].id
        }
    }
}
