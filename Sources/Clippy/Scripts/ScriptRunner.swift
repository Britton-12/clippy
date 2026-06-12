import Foundation

/// Runs a stored script in a subprocess and captures its output. Executing a
/// script is powerful; the UI confirms before calling this. Output is read
/// concurrently from stdout and stderr so a chatty script cannot deadlock on a
/// full pipe buffer, and a watchdog terminates a run that exceeds the timeout.
enum ScriptRunner {
    /// Flag shared with the timeout watchdog. A tiny lock keeps the cross-queue
    /// write/read well defined.
    private final class TimeoutFlag {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        var didFire: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    static func run(_ script: Script, input: String? = nil,
                    timeout: TimeInterval = 30) async -> ScriptResult {
        let start = Date()

        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("clippy-\(script.id.uuidString).\(script.interpreter.fileExtension)")
        do {
            try script.body.write(to: file, atomically: true, encoding: .utf8)
        } catch {
            return ScriptResult(stdout: "", stderr: "Could not write script file: \(error.localizedDescription)",
                                exitCode: -1, durationMs: 0, timedOut: false)
        }

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                defer { try? FileManager.default.removeItem(at: file) }

                let (exe, leadingArgs) = script.interpreter.launch
                let process = Process()
                process.executableURL = URL(fileURLWithPath: exe)
                process.arguments = leadingArgs + [file.path]

                var environment = ProcessInfo.processInfo.environment
                if let input { environment["CLIPPY_CLIP"] = input }
                process.environment = environment

                let outPipe = Pipe(), errPipe = Pipe(), inPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe
                process.standardInput = inPipe

                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: ScriptResult(
                        stdout: "", stderr: "Failed to launch \(exe): \(error.localizedDescription)",
                        exitCode: -1, durationMs: Self.ms(since: start), timedOut: false))
                    return
                }

                // Feed input (if any) and close stdin so readers reach EOF.
                if let input { inPipe.fileHandleForWriting.write(Data(input.utf8)) }
                try? inPipe.fileHandleForWriting.close()

                // Watchdog.
                let flag = TimeoutFlag()
                let watchdog = DispatchWorkItem {
                    if process.isRunning { flag.set(); process.terminate() }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

                // Read both streams concurrently to avoid pipe-buffer deadlock.
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

                continuation.resume(returning: ScriptResult(
                    stdout: String(decoding: outData, as: UTF8.self),
                    stderr: String(decoding: errData, as: UTF8.self),
                    exitCode: process.terminationStatus,
                    durationMs: Self.ms(since: start),
                    timedOut: flag.didFire))
            }
        }
    }

    private static func ms(since start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1000)
    }
}
