import UIKit

/// Platform switch for keeping the screen awake: UIApplication in production, a fake in tests. SystemScreenIdleTimer is the only writer of isIdleTimerDisabled in the app.
protocol ScreenIdleTimer: AnyObject {
    var isIdleTimerDisabled: Bool { get set }
}

final class SystemScreenIdleTimer: ScreenIdleTimer {
    var isIdleTimerDisabled: Bool {
        get { UIApplication.shared.isIdleTimerDisabled }
        set { UIApplication.shared.isIdleTimerDisabled = newValue }
    }
}

/// Screen-awake hold counting shared by dictation recording and read-aloud: the screen stays awake while any holder is present.
/// The original value is saved once before the first holder acquires and restored when the last one releases;
/// acquiring or releasing repeatedly for the same holder is idempotent.
final class ScreenAwakeHolds {
    enum Holder: Hashable {
        case dictation
        case readAloud
    }

    static let shared = ScreenAwakeHolds(timer: SystemScreenIdleTimer())

    private let timer: ScreenIdleTimer
    private var holders: Set<Holder> = []
    /// Value of isIdleTimerDisabled before the first holder acquired; nil when there are no holders.
    private var savedIdleTimerDisabled: Bool?

    init(timer: ScreenIdleTimer) {
        self.timer = timer
    }

    func acquire(_ holder: Holder) {
        guard !holders.contains(holder) else { return }
        if holders.isEmpty {
            savedIdleTimerDisabled = timer.isIdleTimerDisabled
            timer.isIdleTimerDisabled = true
        }
        holders.insert(holder)
    }

    func release(_ holder: Holder) {
        guard holders.remove(holder) != nil, holders.isEmpty else { return }
        if let saved = savedIdleTimerDisabled { timer.isIdleTimerDisabled = saved }
        savedIdleTimerDisabled = nil
    }
}
