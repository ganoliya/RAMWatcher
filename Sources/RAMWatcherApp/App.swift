import AppKit
import SwiftUI

/// Forces the "accessory" activation policy (no Dock icon, no app switcher
/// entry, no menu bar app menu) at launch. This is the belt-and-suspenders
/// half of making this a menu-bar-only app: an `Info.plist` with
/// `LSUIElement = true` is the proper packaged-app way to do this (left to
/// the install/bundling scripts), but setting the policy in code here
/// means the app behaves correctly even when run directly via
/// `swift run RAMWatcherApp` during development, where there is no
/// Info.plist at all.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Owned here (not by the `App` struct) because `applicationDidFinishLaunching`
    /// is guaranteed to run once at process launch, unlike a `.task` attached
    /// to `MenuBarExtra`'s content view -- that content closure is built
    /// lazily by SwiftUI only when the user actually opens the dropdown, so
    /// registration would silently never happen until the first click.
    /// Daemon registration needs to fire unconditionally at launch, matching
    /// how every other SMAppService-based menu bar app behaves.
    let daemonInstaller = DaemonInstaller()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        daemonInstaller.refreshStatus()
        switch daemonInstaller.state {
        case .notRegistered, .notFound:
            // `.notFound` (SMAppService.Status raw value 3) is the normal
            // status for a daemon plist that's never been registered
            // before -- it is NOT necessarily a packaging bug, despite the
            // name. Confirmed empirically: a fresh install with a verified,
            // correctly-sealed embedded plist reported `.notFound` on its
            // very first status check, and only transitioned to
            // `.requiresApproval`/`.enabled` after `register()` was
            // actually called. Treat it the same as `.notRegistered`.
            daemonInstaller.register()
        case .registered, .requiresApproval, .registrationFailed:
            break
        }
    }
}

@main
struct RAMWatcherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            ContentView()
                .environmentObject(model)
                .environmentObject(appDelegate.daemonInstaller)
        } label: {
            Text(menuBarTitle)
        }
        .menuBarExtraStyle(.window)
    }

    /// "RAM: 86%" -- real system-wide memory pressure (active + wired +
    /// compressed / total), matching Activity Monitor's gauge and what
    /// Stats-style menu bar tools show. Deliberately not the per-app
    /// footprint sum, which excludes wired/kernel/GPU memory and reads
    /// much lower than actual pressure. Falls back to a placeholder while
    /// no snapshot has loaded yet (or the daemon isn't running).
    private var menuBarTitle: String {
        guard model.snapshot != nil else {
            return "RAM: --"
        }
        return String(format: "RAM: %.0f%%", model.systemUsedFraction * 100)
    }
}
