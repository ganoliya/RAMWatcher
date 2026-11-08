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

    /// Also owned here rather than as `@StateObject`s on the `App` struct:
    /// a `@StateObject` there makes the whole scene body (menu bar label
    /// included) re-evaluate on every published change. Held as plain
    /// references instead, each is observed only by the view that needs
    /// it: the label observes `meter`, the popover observes `model`.
    let meter: MemoryMeter
    let model: AppModel

    override init() {
        let meter = MemoryMeter()
        self.meter = meter
        self.model = AppModel(meter: meter)
        super.init()
    }

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
    @ObservedObject var meter: MemoryMeter

    var body: some View {
        Image(nsImage: Self.image(for: meter.percent))
    }

    /// Rendered images keyed by percentage. There are at most ~102
    /// distinct labels, so each is drawn once and reused thereafter.
    @MainActor private static var imageCache: [Int: NSImage] = [:]

    @MainActor private static func image(for percent: Int?) -> NSImage {
        let key = percent ?? -1
        if let cached = imageCache[key] { return cached }
        let image = makeImage(text: percent.map { "\($0)%" } ?? "--")
        imageCache[key] = image
        return image
    }

    private static func makeImage(text: String) -> NSImage {
        let topFont    = NSFont.systemFont(ofSize: 7, weight: .regular)
        let bottomFont = NSFont.systemFont(ofSize: 11, weight: .bold)
        let gap: CGFloat = -1.04

        let top = NSAttributedString(
            string: "RAM",
            attributes: [.font: topFont]
        )
        let bottom = NSAttributedString(
            string: text,
            attributes: [.font: bottomFont]
        )

        // ascender - descender = visible glyph height (omits leading, so lines pack tightly)
        let topGlyphH    = topFont.ascender    - topFont.descender
        let bottomGlyphH = bottomFont.ascender - bottomFont.descender
        let contentH     = topGlyphH + gap + bottomGlyphH

        let menuBarH: CGFloat = 22
        // In flipped: true (y=0 at top), draw(at:) places the upper-left of the
        // bounding box at the given point, NOT the baseline. So vOffset is the
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

    var body: some Scene {
        MenuBarExtra {
            ContentView()
                .environmentObject(appDelegate.model)
                .environmentObject(appDelegate.daemonInstaller)
        } label: {
            MenuBarLabel(meter: appDelegate.meter)
        }
        .menuBarExtraStyle(.window)
    }
}
