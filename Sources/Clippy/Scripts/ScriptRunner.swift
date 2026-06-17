import Foundation

/// Runs a stored script in a subprocess and captures its output. Executing a
/// script is powerful; the UI confirms before calling this. Subprocess.run
/// handles concurrent pipe reads, the size ceiling, and the timeout watchdog.
enum ScriptRunner {

    static func run(_ script: Script, input: String? = nil,
                    timeout: TimeInterval = 30) async -> ScriptResult {
        // Clock starts before the temp-file write so durationMs includes that
        // overhead — consistent with the original behavior.
        let start = Date()

        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("clippy-\(script.id.uuidString).\(script.interpreter.fileExtension)")
        do {
            try script.body.write(to: file, atomically: true, encoding: .utf8)
        } catch {
            return ScriptResult(stdout: "", stderr: "Could not write script file: \(error.localizedDescription)",
                                exitCode: -1, durationMs: 0, timedOut: false)
        }

        defer { try? FileManager.default.removeItem(at: file) }

        // Build a fully-merged environment: inherit the parent process env so
        // the interpreter can locate system tools, then inject CLIPPY_CLIP.
        // Subprocess.run replaces the environment entirely when given a non-nil
        // dict, so the full merge must happen here rather than relying on
        // inheritance.
        var env = ProcessInfo.processInfo.environment
        if let input { env["CLIPPY_CLIP"] = input }

        let (exe, leadingArgs) = script.interpreter.launch
        let output = await Subprocess.run(exe, leadingArgs + [file.path],
                                          input: input,
                                          environment: env,
                                          timeout: timeout)

        return ScriptResult(
            stdout: output.stdout,
            stderr: output.stderr,
            exitCode: output.exitCode,
            durationMs: Self.ms(since: start),
            timedOut: output.timedOut,
            truncated: output.truncated)
    }

    private static func ms(since start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1000)
    }
}
