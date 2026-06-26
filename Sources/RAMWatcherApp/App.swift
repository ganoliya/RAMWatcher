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

private struct MenuBarLabel: View {
    let fraction: Double?

    var body: some View {
        Image(nsImage: makeImage())
    }

    private func makeImage() -> NSImage {
        let topFont    = NSFont.systemFont(ofSize: 7, weight: .regular)
        let bottomFont = NSFont.systemFont(ofSize: 11, weight: .bold)
        let gap: CGFloat = -1.04

        let top = NSAttributedString(
            string: "RAM",
            attributes: [.font: topFont]
        )
        let bottom = NSAttributedString(
            string: fraction.map { String(format: "%.0f%%", $0 * 100) } ?? "--",
            attributes: [.font: bottomFont]
        )

        // ascender - descender = visible glyph height (omits leading, so lines pack tightly)
        let topGlyphH    = topFont.ascender    - topFont.descender
        let bottomGlyphH = bottomFont.ascender - bottomFont.descender
        let contentH     = topGlyphH + gap + bottomGlyphH

        let menuBarH: CGFloat = 22
        // In flipped: true (y=0 at top), draw(at:) places the upper-left of the
        // bounding box at the given point — NOT the baseline. So vOffset is the
        // top-left y of "RAM", and the percentage starts immediately below it.
        let vOffset = (menuBarH - contentH) / 2

        let w = ceil(max(top.size().width, bottom.size().width)) + 2

        let image = NSImage(size: NSSize(width: w, height: menuBarH), flipped: true) { _ in
            top.draw(at: NSPoint(x: 0, y: vOffset))
            bottom.draw(at: NSPoint(x: 0, y: vOffset + topGlyphH + gap))
            return true
        }
        image.isTemplate = true
        return image
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
            MenuBarLabel(fraction: model.snapshot != nil ? model.systemUsedFraction : nil)
        }
        .menuBarExtraStyle(.window)
    }
}
