import AppKit
import SwiftUI

/// Reports whether the window hosting this view is on screen.
///
/// `MenuBarExtra(.window)` keeps its content view alive between opens and
/// just orders the panel in and out, so SwiftUI's `onAppear`/`onDisappear`
/// can't be relied on to fire on every open/close. Watching the hosting
/// window's occlusion state is reliable: it flips to visible when the
/// popover opens and back when it closes (or is fully covered).
struct WindowVisibilityObserver: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> ObservingView {
        let view = ObservingView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: ObservingView, context: Context) {
        nsView.onChange = onChange
    }

    final class ObservingView: NSView {
        var onChange: ((Bool) -> Void)?
        private var observers: [NSObjectProtocol] = []
        private var lastReported: Bool?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()

            guard let window else {
                report(false)
                return
            }

            let names: [Notification.Name] = [
                NSWindow.didChangeOcclusionStateNotification,
                NSWindow.didBecomeKeyNotification,
                NSWindow.willCloseNotification,
            ]
            for name in names {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] note in
                    guard let self, let window = self.window else { return }
                    if note.name == NSWindow.willCloseNotification {
                        self.report(false)
                    } else {
                        self.report(window.isVisible && window.occlusionState.contains(.visible))
                    }
                })
            }
            report(window.isVisible && window.occlusionState.contains(.visible))
        }

        private func report(_ visible: Bool) {
            guard visible != lastReported else { return }
            lastReported = visible
            onChange?(visible)
        }

        deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
        }
    }
}
