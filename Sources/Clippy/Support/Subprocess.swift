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

                var errData = Data()
                let errDone = DispatchSemaphore(value: 0)
                DispatchQueue.global().async {
                    errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    errDone.signal()
                }
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
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
