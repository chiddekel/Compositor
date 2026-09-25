// Sparkle, as far as upstream uses it (CompositorApp.swift, CompositorApplicationDelegate.swift): the standard updater
// controller behind Compositor > Check for Updates…. On Linux updates come through Flatpak; the shell installs a
// handler (`SPUStandardUpdaterController.checkHandler`) that runs its Flatpak update check.

import Foundation

public final class SPUStandardUpdaterController: @unchecked Sendable {
    /// What "Check for Updates…" does on this platform (set by the shell).
    nonisolated(unsafe) public static var checkHandler: (() -> Void)?
    public init(startingUpdater: Bool, updaterDelegate: AnyObject?, userDriverDelegate: AnyObject?) {}
    public func startUpdater() {}
    public func checkForUpdates(_ sender: Any?) { Self.checkHandler?() }
}
