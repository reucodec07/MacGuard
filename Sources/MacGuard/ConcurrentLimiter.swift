import Foundation

/// Limits concurrent asynchronous tasks natively in Swift Concurrency
actor ConcurrentLimiter {
    private let limit: Int
    private var active: Int = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    #if DEBUG
    var activeCount: Int { active }
    var queuedCount: Int { waiters.count }
    #endif

    init(limit: Int) {
        self.limit = limit
    }

    func wait() async {
        if active < limit && waiters.isEmpty {
            active += 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func signal() {
        if !waiters.isEmpty {
            let next = waiters.removeFirst()
            next.resume()
        } else {
            active -= 1
        }
    }

    func execute<T>(operation: () async -> T) async -> T {
        await wait()
        defer {
            Task { await self.signal() }
        }
        return await operation()
    }
}
