import XCTest
@testable import CompositorCore

final class ProjectWorkspaceTests: XCTestCase {
    func testTabsSelectRemoveAndDeduplicateByURLString() {
        let workspace = ProjectWorkspace()
        let first = workspace.current
        let opened = workspace.addTab(urlString: "/tmp/project.comp", reuseEmpty: false)
        let duplicate = workspace.addTab(urlString: "/tmp/project.comp", reuseEmpty: false)

        XCTAssertTrue(duplicate === opened)
        XCTAssertEqual(workspace.tabs.count, 2)
        XCTAssertTrue(workspace.current === opened)

        workspace.select(first.id)
        XCTAssertTrue(workspace.current === first)
        workspace.removeTab(first.id)
        XCTAssertTrue(workspace.current === opened)
        workspace.removeTab(opened.id)
        XCTAssertEqual(workspace.tabs.count, 1)
        XCTAssertNil(workspace.current.urlString)
    }

    func testCanSwitchTracksSessionBusyState() throws {
        let workspace = ProjectWorkspace()
        try workspace.current.session.importImage(
            PortableImage(PixelBuffer(width: 4, height: 4, fill: 0xff0000ff)),
            name: "Image", replacing: true)
        var settings = BrushSettings()
        settings.diameter = 1
        try workspace.current.session.beginBrush(at: CGPoint(x: 1, y: 1), settings: settings)

        XCTAssertFalse(workspace.canSwitch)
        workspace.current.session.cancelBrush()
        XCTAssertTrue(workspace.canSwitch)
    }
}
