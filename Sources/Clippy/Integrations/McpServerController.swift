import Foundation
import Combine
import Network

// MARK: - Status

enum McpServerStatus {
    case stopped
    case starting
    case running(port: Int)
    case portInUse(port: Int)
    case failed(String)

    var description: String {
        switch self {
        case .stopped:
            return "Stopped"
        case .starting:
            return "Starting..."
        case .running(let port):
            return "Running on http://127.0.0.1:\(port)"
        case .portInUse(let port):
            return "Port \(port) is already in use by another process"
        case .failed(let msg):
            return msg
        }
    }

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}

// MARK: - Controller

final class McpServerController: ObservableObject {
    static let shared = McpServerController()

    @Published var status: McpServerStatus = .stopped

    private var process: Process?
    private var cancellables = Set<AnyCancellable>()
    private let settings = AppSettings.shared

    private init() {}

    // MARK: - Node binary lookup

    /// Locate the node binary. GUI apps launched from Finder get a stripped PATH,
    /// so we check known Homebrew / system paths before falling back to a login shell.
    static func findNodeBinary() -> String? {
        let candidates = [
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
            "/usr/bin/node",
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        // Login-shell fallback: picks up nvm, volta, asdf, etc.
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-l", "-c", "which node"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !path.isEmpty && FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        } catch {}
        return nil
    }

    // MARK: - Script path resolution

    /// Resolve the bundled server script. Prefers the copy shipped inside the
    /// .app (Contents/Resources/clippy-mcp/index.mjs, written by make-app.sh),
    /// then falls back to the dev/SwiftPM source tree so `swift run` works
    /// without a packaged app. make-app.sh bundles a single esbuild .mjs that
    /// uses Node's built-in node:sqlite, so there is no node_modules to ship.
    static func findServerScript() -> String? {
        // Production: bundled inside the app's Resources directory.
        if let resourceURL = Bundle.main.resourceURL {
            let bundled = resourceURL.appendingPathComponent("clippy-mcp/index.mjs")
            if FileManager.default.fileExists(atPath: bundled.path) {
                return bundled.path
            }
        }

        // Dev/SwiftPM: the executable sits at .build/debug/Clippy or similar.
        // Walk up looking for the freshly built bundle in the source tree.
        let execPath = Bundle.main.executablePath ?? ""
        var candidate = URL(fileURLWithPath: execPath).deletingLastPathComponent()
        for _ in 0..<8 {
            let script = candidate.appendingPathComponent("integrations/clippy-mcp/build/index.mjs")
            if FileManager.default.fileExists(atPath: script.path) {
                return script.path
            }
            candidate = candidate.deletingLastPathComponent()
        }
        return nil
    }

    // MARK: - Port availability

    /// Returns true when nothing is bound to 127.0.0.1:\(port) yet.
    func isPortFree(_ port: Int) -> Bool {
        // If our own process is already holding it, report free so start() can no-op.
        if case .running(let p) = status, p == port { return true }

        let sock = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard sock != -1 else { return false }
        defer { Darwin.close(sock) }

        var yes: Int32 = 1
        Darwin.setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)

        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return bound == 0
    }

    // MARK: - Lifecycle

    func start() {
        if status.isRunning { return }
        if case .starting = status { return }
        _start()
    }

    private func _start() {
        let port = settings.mcpPort

        guard let nodePath = McpServerController.findNodeBinary() else {
            let msg = "Node.js not found. Install Node to run the MCP server."
            ClippyLog.error("MCP start failed: \(msg)", category: ClippyLog.mcp)
            DispatchQueue.main.async { [weak self] in
                self?.status = .failed(msg)
            }
            return
        }

        guard let scriptPath = McpServerController.findServerScript() else {
            let msg = "MCP server script not found in the app bundle. "
                + "(Dev builds: run npm run build in integrations/clippy-mcp.)"
            ClippyLog.error("MCP start failed: \(msg)", category: ClippyLog.mcp)
            DispatchQueue.main.async { [weak self] in
                self?.status = .failed(msg)
            }
            return
        }

        guard isPortFree(port) else {
            DispatchQueue.main.async { [weak self] in
                self?.status = .portInUse(port: port)
            }
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.status = .starting
        }

        let dbPath = ClipDatabase.shared.databaseURL.path

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: nodePath)
        // node:sqlite is unflagged since Node 22.13 but still emits an
        // ExperimentalWarning; silence it so a clean stderr means a clean start.
        proc.arguments = ["--disable-warning=ExperimentalWarning", scriptPath]

        var env = ProcessInfo.processInfo.environment
        env["CLIPPY_MCP_PORT"] = "\(port)"
        env["CLIPPY_DB_PATH"] = dbPath
        proc.environment = env

        let stderrPipe = Pipe()
        proc.standardOutput = Pipe()
        proc.standardError = stderrPipe

        proc.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                // Only flip to stopped if we were the one running (not already restarted)
                if let self, case .running = self.status {
                    self.status = .stopped
                }
            }
        }

        do {
            try proc.run()
        } catch {
            let msg = "Failed to launch node: \(error.localizedDescription)"
            ClippyLog.error("MCP launch error: \(msg)", category: ClippyLog.mcp)
            DispatchQueue.main.async { [weak self] in
                self?.status = .failed(msg)
            }
            return
        }

        self.process = proc

        // Poll /health until the server is up (max ~2.5s with 5 retries).
        pollHealth(port: port, retriesLeft: 5, stderrPipe: stderrPipe)
    }

    private func pollHealth(port: Int, retriesLeft: Int, stderrPipe: Pipe) {
        let url = URL(string: "http://127.0.0.1:\(port)/health")!
        let task = URLSession.shared.dataTask(with: url) { [weak self] data, response, _ in
            guard let self else { return }
            let ok = (response as? HTTPURLResponse)?.statusCode == 200
            if ok {
                ClippyLog.info("MCP server running on port \(port)", category: ClippyLog.mcp)
                DispatchQueue.main.async { self.status = .running(port: port) }
            } else if retriesLeft > 0 {
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                    self.pollHealth(port: port, retriesLeft: retriesLeft - 1, stderrPipe: stderrPipe)
                }
            } else {
                // Read stderr for a diagnostic message
                let errData = stderrPipe.fileHandleForReading.availableData
                let errMsg = String(data: errData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let detail = errMsg.isEmpty ? "Server did not respond to /health after launch." : errMsg
                ClippyLog.error("MCP server failed to start: \(detail)", category: ClippyLog.mcp)
                DispatchQueue.main.async { self.status = .failed(detail) }
            }
        }
        task.resume()
    }

    func stop() {
        ClippyLog.info("MCP server stopping", category: ClippyLog.mcp)
        process?.terminate()
        process = nil
        DispatchQueue.main.async { [weak self] in
            self?.status = .stopped
        }
    }

    func restart() {
        stop()
        // Small delay so the port is released before we try to bind again.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?._start()
        }
    }

    // MARK: - Settings observation

    /// Call once from AppDelegate after launch. Starts the server if enabled,
    /// and wires up Combine sinks so future settings changes take effect live.
    func syncWithSettings() {
        if settings.mcpEnabled {
            _start()
        }

        settings.$mcpEnabled
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                if enabled { self?._start() } else { self?.stop() }
            }
            .store(in: &cancellables)

        settings.$mcpPort
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.settings.mcpEnabled else { return }
                self.restart()
            }
            .store(in: &cancellables)
    }

    // MARK: - Test connection

    /// Hits /health (and optionally /mcp for a tools/list) to verify the server
    /// is reachable. Calls completion on the main thread.
    func testConnection(completion: @escaping (Result<Int, Error>) -> Void) {
        guard case .running(let port) = status else {
            completion(.failure(McpError.serverNotRunning))
            return
        }

        let healthURL = URL(string: "http://127.0.0.1:\(port)/health")!
        URLSession.shared.dataTask(with: healthURL) { [weak self] _, response, error in
            guard let self else { return }
            if let error {
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                DispatchQueue.main.async {
                    completion(.failure(McpError.healthCheckFailed))
                }
                return
            }
            // Attempt an MCP tools/list to get the tool count
            self.fetchToolCount(port: port, completion: completion)
        }.resume()
    }

    private func fetchToolCount(port: Int, completion: @escaping (Result<Int, Error>) -> Void) {
        guard let url = URL(string: "http://127.0.0.1:\(port)/mcp") else {
            DispatchQueue.main.async { completion(.success(0)) }
            return
        }

        // MCP JSON-RPC: initialize then tools/list
        // We send tools/list directly; the HTTP MCP transport accepts it without
        // a preceding initialize when the server supports stateless requests.
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/list",
            "params": [:]
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }
            let count = McpServerController.parseToolCount(from: data)
            DispatchQueue.main.async { completion(.success(count)) }
        }.resume()
    }

    private static func parseToolCount(from data: Data?) -> Int {
        guard let data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? [String: Any],
              let tools = result["tools"] as? [[String: Any]] else { return 0 }
        return tools.count
    }
}

// MARK: - Errors

enum McpError: LocalizedError {
    case serverNotRunning
    case healthCheckFailed

    var errorDescription: String? {
        switch self {
        case .serverNotRunning:
            return "MCP server is not running. Enable it in Settings first."
        case .healthCheckFailed:
            return "Server responded but /health returned an unexpected status."
        }
    }
}
