import Foundation
import os

// MARK: - ClippyLog
// Persistent rotating logger. Every event goes to both os.Logger (Console.app
// visible, no file-system cost) and a plain-text file so post-mortem diagnosis
// is possible even after crashes that clear the os_log ring buffer.
//
// File layout:
//   ~/Library/Application Support/Clippy/Logs/clippy.log       (active)
//   ~/Library/Application Support/Clippy/Logs/clippy.log.1     (one prior rotation)
//
// Rotation: when clippy.log exceeds 2 MB, it is renamed to clippy.log.1 (any
// existing .1 is overwritten) and a fresh clippy.log is started. Total on-disk
// budget is therefore ~4 MB.
//
// All file I/O runs on a dedicated serial queue so logging never blocks the
// caller (capture, UI, sync).

enum ClippyLog {

    // MARK: - os.Logger accessors (one per functional area)

    static let lifecycle = Logger(subsystem: "com.bytesavvy.clippy", category: "lifecycle")
    static let capture   = Logger(subsystem: "com.bytesavvy.clippy", category: "capture")
    static let storage   = Logger(subsystem: "com.bytesavvy.clippy", category: "storage")
    static let sync      = Logger(subsystem: "com.bytesavvy.clippy", category: "sync")
    static let mcp       = Logger(subsystem: "com.bytesavvy.clippy", category: "mcp")
    static let ai        = Logger(subsystem: "com.bytesavvy.clippy", category: "ai")

    // MARK: - File sink internals

    // Serial queue: all appends and rotations serialize here, never blocking callers.
    private static let fileQueue = DispatchQueue(label: "com.bytesavvy.clippy.log-file",
                                                 qos: .utility)

    // 2 MB rotation threshold; ~4 MB total with one backup.
    private static let maxLogBytes: UInt64 = 2 * 1024 * 1024

    private static let logDir: URL = {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Clippy", isDirectory: true)
        return support.appendingPathComponent("Logs", isDirectory: true)
    }()

    private static let logURL:   URL = logDir.appendingPathComponent("clippy.log")
    private static let backupURL: URL = logDir.appendingPathComponent("clippy.log.1")

    // FileHandle kept open for the lifetime of the process (append-only).
    // Created lazily on the fileQueue the first time a line is written.
    private static var _handle: FileHandle?

    // MARK: - Public API

    /// Write an info-level message to both os.Logger and the file sink.
    static func info(_ message: String, category: Logger) {
        category.info("\(message, privacy: .public)")
        fileSink(level: "INFO", message: message)
    }

    /// Write an error-level message to both os.Logger and the file sink.
    static func error(_ message: String, category: Logger) {
        category.error("\(message, privacy: .public)")
        fileSink(level: "ERROR", message: message)
    }

    // MARK: - Synchronous flush (for crash handler)

    /// Write directly on the calling thread without queuing. Used by the
    /// uncaught-exception handler so the line is guaranteed to land before
    /// the process exits.
    static func syncWrite(_ message: String, level: String = "FATAL") {
        let line = formatLine(level: level, message: message)
        // Best-effort: open, append, close inline.
        do {
            try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
            if let data = (line + "\n").data(using: .utf8) {
                if FileManager.default.fileExists(atPath: logURL.path) {
                    let fh = try FileHandle(forWritingTo: logURL)
                    fh.seekToEndOfFile()
                    fh.write(data)
                    try fh.close()
                } else {
                    try data.write(to: logURL, options: .atomic)
                }
            }
        } catch {
            // Last resort: os_log only — cannot recurse into ClippyLog.error here.
            os_log(.fault, "ClippyLog syncWrite failed: %{public}@", error.localizedDescription)
        }
    }

    // MARK: - File sink implementation

    private static func fileSink(level: String, message: String) {
        let line = formatLine(level: level, message: message)
        fileQueue.async {
            appendToFile(line + "\n")
        }
    }

    private static func formatLine(level: String, message: String) -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        // Extract category name from the message context is not straightforward;
        // callers supply it via the public API's `category` label instead.
        return "\(iso.string(from: Date())) | \(level) | \(message)"
    }

    /// Must only be called on fileQueue.
    private static func appendToFile(_ text: String) {
        // Ensure log directory exists.
        if _handle == nil {
            do {
                try FileManager.default.createDirectory(
                    at: logDir, withIntermediateDirectories: true)
                if !FileManager.default.fileExists(atPath: logURL.path) {
                    FileManager.default.createFile(atPath: logURL.path, contents: nil)
                }
                _handle = try FileHandle(forWritingTo: logURL)
                _handle?.seekToEndOfFile()
            } catch {
                os_log(.error, "ClippyLog: could not open log file: %{public}@",
                       error.localizedDescription)
                return
            }
        }

        guard let data = text.data(using: .utf8) else { return }
        _handle?.write(data)

        // Rotate when the file exceeds the threshold.
        rotateIfNeeded()
    }

    /// Must only be called on fileQueue.
    private static func rotateIfNeeded() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: logURL.path),
              let size = attrs[.size] as? UInt64,
              size >= maxLogBytes else { return }

        // Close the active handle before renaming.
        try? _handle?.close()
        _handle = nil

        // Overwrite any existing backup and rotate.
        let fm = FileManager.default
        try? fm.removeItem(at: backupURL)
        try? fm.moveItem(at: logURL, to: backupURL)

        // Open a fresh file.
        fm.createFile(atPath: logURL.path, contents: nil)
        if let fh = try? FileHandle(forWritingTo: logURL) {
            _handle = fh
        }
    }
}

// MARK: - Convenience wrappers with category string

extension ClippyLog {
    /// Convenience: log with a string category name. Dispatches to the matching
    /// Logger accessor; unknown categories fall through to `lifecycle`.
    static func info(_ message: String, categoryName: String) {
        info("[\(categoryName)] \(message)", category: logger(for: categoryName))
    }

    static func error(_ message: String, categoryName: String) {
        error("[\(categoryName)] \(message)", category: logger(for: categoryName))
    }

    private static func logger(for name: String) -> Logger {
        switch name {
        case "capture":   return capture
        case "storage":   return storage
        case "sync":      return sync
        case "mcp":       return mcp
        case "ai":        return ai
        default:          return lifecycle
        }
    }
}
