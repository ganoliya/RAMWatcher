import AppKit
import RAMWatcherCore

/// Drives the menu bar percentage. Reads system memory locally (an
/// unprivileged sysctl + Mach host query), so it never wakes the root
/// daemon or triggers a process scan.
///
/// Refreshes once a minute, and only while the Mac is awake: the timer is
/// torn down on system sleep and display sleep (nobody can see the menu
/// bar then) and rebuilt on wake with an immediate refresh, so the number
/// is current the moment the screen comes back. The timer has generous
/// tolerance so macOS can coalesce its wakeups with other work.
///
/// Kept separate from `AppModel` (and observed only by the label view) so
/// the 2s popover polling doesn't re-render the menu bar label, and the
/// label's own changes don't re-render the popover.
@MainActor
final class MemoryMeter: ObservableObject {
    /// Whole-number percentage, so the label only re-renders when the
    /// displayed text would actually change.
    @Published private(set) var percent: Int?

    private let interval: TimeInterval
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []

    init(interval: TimeInterval = 60) {
        self.interval = interval
        refresh()
        startTimer()
        observeSleepWake()
    }

    func refresh() {
        let newValue = SystemMemory.usedFraction().map { Int(($0 * 100).rounded()) }
        if newValue != percent {
            percent = newValue
        }
    }

    private func startTimer() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.tolerance = interval * 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    /// Tracked separately because the system can wake with the display
    /// still asleep (dark wake / Power Nap); only run when both are awake.
    private var systemAsleep = false
    private var screensAsleep = false

    private func updateTimerForWakeState() {
        if systemAsleep || screensAsleep {
            stopTimer()
        } else if timer == nil {
            refresh()
            startTimer()
        }
    }

    private func observeSleepWake() {
        let center = NSWorkspace.shared.notificationCenter
        let handlers: [(Notification.Name, (MemoryMeter) -> Void)] = [
            (NSWorkspace.willSleepNotification, { $0.systemAsleep = true }),
            (NSWorkspace.didWakeNotification, { $0.systemAsleep = false }),
            (NSWorkspace.screensDidSleepNotification, { $0.screensAsleep = true }),
            (NSWorkspace.screensDidWakeNotification, { $0.screensAsleep = false }),
        ]
        for (name, apply) in handlers {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    apply(self)
                    self.updateTimerForWakeState()
                }
            })
        }
    }
}
