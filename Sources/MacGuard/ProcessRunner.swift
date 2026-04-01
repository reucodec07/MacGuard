import Foundation
import Darwin
import os.log

class ProcessRunner {
    static let shared = ProcessRunner()
    private let logger = Logger(subsystem: "com.macguard", category: "ProcessRunner")
    
    private let limiter = ConcurrentLimiter(limit: min(8, ProcessInfo.processInfo.activeProcessorCount * 2))
    
    struct RunOptions: Sendable {
        var timeout: TimeInterval = 15.0
        var workingDirectory: URL? = nil
        var environment: [String: String]? = nil
    }

    /// Single helper to unify command execution, timeouts, and cancellation inheritance.
    @discardableResult
    func run(_ path: String, _ args: [String], options: RunOptions = RunOptions()) async -> (stdout: String, stderr: String, exitCode: Int32) {
        await limiter.execute {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: path)
            task.arguments = args
            if let wd = options.workingDirectory { task.currentDirectoryURL = wd }
            if let env = options.environment { task.environment = env }
            
            let outPipe = Pipe()
            let errPipe = Pipe()
            task.standardOutput = outPipe
            task.standardError = errPipe
            
            return await withTaskCancellationHandler {
                do {
                    try task.run()
                } catch {
                    self.logger.error("Failed to run \(path): \(error.localizedDescription)")
                    return ("", error.localizedDescription, -1)
                }
                
                let timeoutTask = Task {
                    try? await Task.sleep(nanoseconds: UInt64(options.timeout * 1_000_000_000))
                    if task.isRunning {
                        self.logger.warning("Process timeout reached for \(path), terminating.")
                        task.terminate()
                    }
                }
                
                let stdoutData = outPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = errPipe.fileHandleForReading.readDataToEndOfFile()
                
                task.waitUntilExit()
                timeoutTask.cancel()
                
                let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
                let stderr = String(data: stderrData, encoding: .utf8) ?? ""
                
                return (stdout, stderr, task.terminationStatus)
            } onCancel: {
                if task.isRunning {
                    self.logger.info("Task cancelled, terminating process: \(path)")
                    task.terminate()
                }
            }
        }
    }
    
    @discardableResult
    func run(_ path: String, _ args: [String], timeout: TimeInterval) async -> (stdout: String, stderr: String, exitCode: Int32) {
        await run(path, args, options: RunOptions(timeout: timeout))
    }

    /// Optional streaming support (simplified for now)
    func runStreaming(_ path: String, _ args: [String], onOutput: @escaping (String) -> Void) async -> Int32 {
        await limiter.execute {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: path)
            task.arguments = args
            let outPipe = Pipe()
            task.standardOutput = outPipe
            
            outPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty { return }
                if let str = String(data: data, encoding: .utf8) {
                    onOutput(str)
                }
            }
            
            return await withTaskCancellationHandler {
                do {
                    try task.run()
                    task.waitUntilExit()
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    return task.terminationStatus
                } catch {
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    return -1
                }
            } onCancel: {
                if task.isRunning { task.terminate() }
            }
        }
    }

    /// Security Hardening for Admin Script
    @discardableResult
    func runAdminScript(_ lines: [String]) async -> (success: Bool, output: String) {
        // We use a detached task here because NSAppleScript.execute is synchronous 
        // and doesn't support easy interruption/cancellation once the prompt is shown.
        await Task.detached(priority: .userInitiated) {
            let template = (NSTemporaryDirectory() as NSString)
                .appendingPathComponent("macguard.XXXXXX.sh")
            var cstr = Array(template.utf8CString)
            let fd = mkstemp(&cstr)
            guard fd != -1 else {
                self.logger.error("mkstemp failed to create temporary admin script.")
                return (false, "Security error: Could not create temporary execution file.")
            }

            fchmod(fd, S_IRWXU)

            let path = String(cString: cstr)
            let data = lines.joined(separator: "\n").data(using: .utf8) ?? Data()
            data.withUnsafeBytes { ptr in
                guard let baseAddress = ptr.baseAddress else { return }
                _ = Darwin.write(fd, baseAddress, ptr.count)
            }
            close(fd)

            let esc = path.replacingOccurrences(of: "'", with: "'\\''")
            let ascpt = """
            do shell script "bash '\(esc)'; rm -f '\(esc)'" with administrator privileges
            """
            var err: NSDictionary?
            let res = NSAppleScript(source: ascpt)?.executeAndReturnError(&err)
            
            unlink(cstr)
            
            if let err = err {
                let desc = err[NSAppleScript.errorMessage] as? String ?? err.description
                self.logger.error("Admin script failed or was cancelled: \(desc)")
                return (false, desc)
            }
            
            return (true, res?.stringValue ?? "")
        }.value
    }
}
