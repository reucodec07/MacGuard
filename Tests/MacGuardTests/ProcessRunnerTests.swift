import XCTest
@testable import MacGuard

final class ProcessRunnerTests: XCTestCase {
    func testBasicExecution() async {
        let runner = ProcessRunner.shared
        let res = await runner.run("/bin/echo", ["hello"])
        XCTAssertEqual(res.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "hello")
        XCTAssertEqual(res.exitCode, 0)
    }
    
    func testTimeout() async {
        let runner = ProcessRunner.shared
        // Use a command that sleeps longer than the timeout
        let res = await runner.run("/bin/sleep", ["2"], options: .init(timeout: 0.5))
        // It should be terminated (signal 15 or 9, exit code != 0)
        XCTAssertNotEqual(res.exitCode, 0)
    }
    
    func testCancellation() async {
        let task = Task {
            let res = await ProcessRunner.shared.run("/bin/sleep", ["5"])
            return res
        }
        
        // Wait a bit then cancel
        try? await Task.sleep(nanoseconds: 500_000_000)
        task.cancel()
        
        let res = await task.value
        XCTAssertNotEqual(res.exitCode, 0, "Process should have been terminated due to cancellation")
    }
}

final class ConcurrentLimiterTests: XCTestCase {
    func testPeakConcurrency() async {
        let limiter = ConcurrentLimiter(limit: 2)
        var activeCount = 0
        var peakActive = 0
        let lock = NSLock()
        
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<5 {
                group.addTask {
                    await limiter.execute {
                        lock.lock()
                        activeCount += 1
                        peakActive = max(peakActive, activeCount)
                        lock.unlock()
                        
                        try? await Task.sleep(nanoseconds: 200_000_000)
                        
                        lock.lock()
                        activeCount -= 1
                        lock.unlock()
                    }
                }
            }
        }
        
        XCTAssertLessThanOrEqual(peakActive, 2)
    }
}
