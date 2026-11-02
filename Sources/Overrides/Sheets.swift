// `Compositor/UI/{CanvasSizeSheet,ImageSizeSheet,ExportAsSheet}.swift` are wired in (all symlinked; Export JPEG… is
// Export As starting on JPEG, as upstream 1.4.8 has it). This file only adds the Linux-only
// `SheetAutoResolving` conformance. Upstream's `ProjectController` builds sheets with `NSHostingController` /
// `NSWindow.beginSheet`; the Qt shell presents them. With no host, `resolveWithoutHost()` cancels.

import Foundation
import AppKit
import SwiftUI

// Real composite views (each has its own `var body: some View`) — only the Linux-only auto-resolve conformance is
// added; they resolve through `body` like any other panel, not as `_Native` leaves.
extension CanvasSizeSheet: SheetAutoResolving { public func resolveWithoutHost() { finish(nil) } }
extension ImageSizeSheet: SheetAutoResolving { public func resolveWithoutHost() { finish(nil) } }
extension ExportAsSheet: SheetAutoResolving { public func resolveWithoutHost() { finish(nil) } }
