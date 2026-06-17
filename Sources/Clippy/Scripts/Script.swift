import Foundation

/// How a script body is executed. Each case maps to a launch executable and the
/// arguments used to run a body written to a temp file.
enum ScriptInterpreter: String, Codable, CaseIterable, Identifiable {
    case zsh
    case bash
    case sh
    case python3
    case node
    case ruby
    case applescript
    case swift

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .zsh: return "Zsh"
        case .bash: return "Bash"
        case .sh: return "Shell (sh)"
        case .python3: return "Python 3"
        case .node: return "Node.js"
        case .ruby: return "Ruby"
        case .applescript: return "AppleScript"
        case .swift: return "Swift"
        }
    }

    /// File extension for the temp script file (helps interpreters and editors).
    var fileExtension: String {
        switch self {
        case .zsh, .bash, .sh: return "sh"
        case .python3: return "py"
        case .node: return "js"
        case .ruby: return "rb"
        case .applescript: return "scpt"
        case .swift: return "swift"
        }
    }

    /// The launch executable and the leading arguments before the script path.
    /// Shells use absolute paths; the rest resolve via /usr/bin/env so they
    /// follow the user's PATH. The script file path is appended by the runner.
    var launch: (executable: String, leadingArgs: [String]) {
        switch self {
        case .zsh: return ("/bin/zsh", [])
        case .bash: return ("/bin/bash", [])
        case .sh: return ("/bin/sh", [])
        case .python3: return ("/usr/bin/env", ["python3"])
        case .node: return ("/usr/bin/env", ["node"])
        case .ruby: return ("/usr/bin/env", ["ruby"])
        case .applescript: return ("/usr/bin/osascript", [])
        case .swift: return ("/usr/bin/env", ["swift"])
        }
    }
}

/// A user-stored script that can be run from Clippy. Bodies are arbitrary code;
/// running one is gated behind a confirmation in the UI.
struct Script: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var interpreter: ScriptInterpreter
    var body: String
    /// When true, the runner feeds the active clip's text on stdin and in the
    /// CLIPPY_CLIP environment variable.
    var feedsClipboard: Bool
    /// When true, the script's stdout is offered as a new clip after it runs.
    var outputToClipboard: Bool
    var createdAt: Date
    var updatedAt: Date
    /// User-defined display order. Lower values appear first. Defaults to 0 so
    /// JSON saved by older builds (which have no sortOrder key) migrates cleanly
    /// via `decodeIfPresent ?? 0`.
    var sortOrder: Int

    init(id: UUID = UUID(),
         name: String,
         interpreter: ScriptInterpreter = .zsh,
         body: String = "",
         feedsClipboard: Bool = false,
         outputToClipboard: Bool = false,
         createdAt: Date = Date(),
         updatedAt: Date = Date(),
         sortOrder: Int = 0) {
        self.id = id
        self.name = name
        self.interpreter = interpreter
        self.body = body
        self.feedsClipboard = feedsClipboard
        self.outputToClipboard = outputToClipboard
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.sortOrder = sortOrder
    }

    // MARK: - Codable with migration

    enum CodingKeys: String, CodingKey {
        case id, name, interpreter, body, feedsClipboard, outputToClipboard
        case createdAt, updatedAt, sortOrder
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        interpreter = try c.decode(ScriptInterpreter.self, forKey: .interpreter)
        body = try c.decode(String.self, forKey: .body)
        feedsClipboard = try c.decode(Bool.self, forKey: .feedsClipboard)
        outputToClipboard = try c.decode(Bool.self, forKey: .outputToClipboard)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        // Old JSON has no sortOrder; default to 0 so migration backfill runs in load().
        sortOrder = try c.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
    }
}

/// The outcome of a run, surfaced to the UI.
struct ScriptResult: Equatable {
    let stdout: String
    let stderr: String
    let exitCode: Int32
    let durationMs: Int
    let timedOut: Bool
    /// True when output was capped at the size ceiling and the child was killed
    /// to drain the pipe. The output is valid (just truncated), so this is not a
    /// failure. Defaults to false so existing construction sites stay compatible.
    var truncated: Bool = false

    // A truncation-kill yields a SIGTERM exit status, so exitCode != 0; treat it
    // as success since the captured output is complete up to the ceiling.
    var succeeded: Bool { (exitCode == 0 || truncated) && !timedOut }
}
