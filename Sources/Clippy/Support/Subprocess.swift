import Foundation

/// Run an external executable and capture its output. Used by integrations that
/// shell out (the 1Password CLI). stdout and stderr are read concurrently so a
/// chatty process cannot deadlock on a full pipe buffer, with a timeout watchdog.
enum Subprocess {
    struct Output {
        let stdout: String
        let stderr: String
        let exitCode: Int32
        let launchFailed: Bool
        var succeeded: Bool { exitCode == 0 && !launchFailed }
    }

    private final class Flag {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    /// Read from a pipe file handle in chunks, stopping once `ceiling` bytes
    /// have been accumulated. When truncated, the child process is terminated
    /// so both pipes drain to EOF quickly rather than blocking indefinitely.
    /// Returns the accumulated bytes with an optional truncation marker appended.
    private static func readBounded(_ handle: FileHandle,
                                    ceiling: Int,
                                    truncationMarker: String,
                                    process: Process) -> Data {
        var accumulated = Data()
        let chunkSize = 65_536  // 64 KB read granularity
        var truncated = false

        while true {
            let chunk = handle.availableData
            if chunk.isEmpty {
                // availableData returns empty at EOF on a pipe whose write-end is closed.
                break
            }
            accumulated.append(chunk)
            if accumulated.count >= ceiling {
                // Ceiling hit: kill the child so we reach EOF quickly on both
                // streams instead of waiting for the process to finish naturally.
                if process.isRunning { process.terminate() }
                truncated = true
                break
            }
            // Yield briefly so the OS can schedule the child to produce more data.
            Thread.sleep(forTimeInterval: 0.001)
            _ = chunkSize  // suppress unused-variable warning
        }

        if truncated, let marker = truncationMarker.data(using: .utf8) {
            accumulated.append(marker)
        }
        return accumulated
    }

    static func run(_ executable: String, _ arguments: [String],
                    input: String? = nil, environment: [String: String]? = nil,
                    timeout: TimeInterval = 20) async -> Output {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                if let environment { process.environment = environment }

                let outPipe = Pipe(), errPipe = Pipe(), inPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe
                process.standardInput = inPipe

                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: Output(
                        stdout: "", stderr: error.localizedDescription,
                        exitCode: -1, launchFailed: true))
                    return
                }

                if let input { inPipe.fileHandleForWriting.write(Data(input.utf8)) }
                try? inPipe.fileHandleForWriting.close()

                let timedOut = Flag()
                let watchdog = DispatchWorkItem {
                    if process.isRunning { timedOut.set(); process.terminate() }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

                // Hard ceiling per stream: a runaway producer (e.g. an infinite
                // loop printing to stdout) would otherwise fill RAM before the
                // timeout fires, because readDataToEndOfFile blocks until EOF.
                // Instead we read in chunks and stop accumulating once the limit
                // is reached, then terminate the child so the pipes drain quickly.
                let outputCeiling = 5 * 1024 * 1024  // 5 MB per stream
                let truncationMarker = "\n[output truncated]"

                var errData = Data()
                let errDone = DispatchSemaphore(value: 0)
                DispatchQueue.global().async {
                    errData = Self.readBounded(errPipe.fileHandleForReading,
                                               ceiling: outputCeiling,
                                               truncationMarker: truncationMarker,
                                               process: process)
                    errDone.signal()
                }
                let outData = Self.readBounded(outPipe.fileHandleForReading,
                                               ceiling: outputCeiling,
                                               truncationMarker: truncationMarker,
                                               process: process)
                errDone.wait()
                process.waitUntilExit()
                watchdog.cancel()

                continuation.resume(returning: Output(
                    stdout: String(decoding: outData, as: UTF8.self),
                    stderr: timedOut.isSet ? "Timed out" : String(decoding: errData, as: UTF8.self),
                    exitCode: process.terminationStatus,
                    launchFailed: false))
            }
        }
    }
}
