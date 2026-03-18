import Foundation
import AppKit

// MARK: — AdminSession
// Acquires and caches admin privileges for the current app session.
// Call `AdminSession.shared.warmUp()` once when the user first enters
// a feature that needs admin (Uninstaller, Login Items).
// All subsequent `do shell script ... with administrator privileges` calls
// within macOS's auth timeout (~5 min) will not re-prompt.

class AdminSession {
    static let shared = AdminSession()

    private var isWarmed = false
    private var lastWarmDate: Date?
    private let warmInterval: TimeInterval = 270 // re-warm after 4.5 min to stay inside macOS cache window
    private let lock = NSLock()

    private init() {}

    func warmUp(completion: @escaping (_ granted: Bool) -> Void) {
        lock.lock()
        let needsWarm: Bool
        if let last = lastWarmDate, Date().timeIntervalSince(last) < warmInterval {
            needsWarm = false
        } else {
            needsWarm = true
        }
        lock.unlock()

        guard needsWarm else {
            DispatchQueue.main.async { completion(true) }
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            var err: NSDictionary?
            if let script = NSAppleScript(source: "do shell script \"true\" with administrator privileges") {
                script.executeAndReturnError(&err)
            }
            let granted = err == nil

            self.lock.lock()
            if granted {
                self.isWarmed = true
                self.lastWarmDate = Date()
            }
            self.lock.unlock()

            DispatchQueue.main.async { completion(granted) }
        }
    }

    func invalidate() {
        lock.lock()
        isWarmed = false
        lastWarmDate = nil
        lock.unlock()
    }
}
