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
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
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
