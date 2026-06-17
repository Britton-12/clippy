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

    // Serial queue that owns the child-process reference. Every read and write of
    // `process` and `startInFlight` happens here, so the node process can never be
    // terminated, leaked, or double-launched by two queues racing. `status` stays
    // on the main queue (SwiftUI observes it), so we never mutate it from here.
    private let lifecycleQueue = DispatchQueue(label: "com.bytesavvy.clippy.mcp.lifecycle")
    private var process: Process?
    // Atomic "a start is already underway" sentinel, guarded by lifecycleQueue.
    // Set the instant a launch is committed; cleared when the start resolves
    // (running, failed, port-in-use, or the child exits). This is the real guard
    // against double-launch, not the async `.starting` status flip.
    private var startInFlight = false
    private var cancellables = Set<AnyCancellable>()
    private let settings = AppSettings.shared

    private init() {}

    // MARK: - Node binary lookup

    /// Locate the node binary. GUI apps launched from Finder get a stripped PATH,
    /// so we check known Homebrew / system paths before falling back to a login shell
    /// (which picks up nvm, volta, asdf, etc.).
    static func findNodeBinary() -> String? {
        Subprocess.findBinary(named: "node", candidates: [
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
            "/usr/bin/node",
        ])
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

        // Out-of-range ports cannot be bound; report not-free rather than letting
        // UInt16(port) below trap on an integer overflow and crash the app.
        guard (1...65535).contains(port) else { return false }

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

    /// Release the in-flight start claim on the owning queue. Called from every
    /// early-return failure path in _start() so a failed launch never wedges the
    /// sentinel and blocks a later start.
    private func clearStartInFlight() {
        lifecycleQueue.async { [weak self] in
            self?.startInFlight = false
        }
    }

    func start() {
        if status.isRunning { return }
        if case .starting = status { return }
        _start()
    }

    private func _start() {
        // Atomically claim the start so two near-simultaneous triggers cannot both
        // launch. The async `.starting` status flip below happens too late to act
        // as a guard; the synchronous sentinel on lifecycleQueue is the real gate.
        let claimed = lifecycleQueue.sync { () -> Bool in
            if startInFlight || process != nil { return false }
            startInFlight = true
            return true
        }
        guard claimed else { return }

        let port = settings.mcpPort

        guard let nodePath = McpServerController.findNodeBinary() else {
            let msg = "Node.js not found. Install Node to run the MCP server."
            ClippyLog.error("MCP start failed: \(msg)", category: ClippyLog.mcp)
            clearStartInFlight()
            DispatchQueue.main.async { [weak self] in
                self?.status = .failed(msg)
            }
            return
        }

        guard let scriptPath = McpServerController.findServerScript() else {
            let msg = "MCP server script not found in the app bundle. "
                + "(Dev builds: run npm run build in integrations/clippy-mcp.)"
            ClippyLog.error("MCP start failed: \(msg)", category: ClippyLog.mcp)
            clearStartInFlight()
            DispatchQueue.main.async { [weak self] in
                self?.status = .failed(msg)
            }
            return
        }

        guard isPortFree(port) else {
            clearStartInFlight()
            DispatchQueue.main.async { [weak self] in
                self?.status = .portInUse(port: port)
            }
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.status = .starting
        }

        let dbPath = ClipDatabase.shared.databaseURL.path

        var env = ProcessInfo.processInfo.environment
        env["CLIPPY_MCP_PORT"] = "\(port)"
        env["CLIPPY_DB_PATH"] = dbPath

        // Collect stderr lines for the failure diagnostic; the health poll snapshot
        // closure captures this array and reads it at failure time. stderr arrives on
        // launch's background drain thread while the poll reads from a URLSession
        // callback thread, so guard both sides with a lock.
        let stderrLock = NSLock()
        var stderrLines: [String] = []

        // node:sqlite is unflagged since Node 22.13 but still emits an
        // ExperimentalWarning; silence it so a clean stderr means a clean start.
        let proc = Subprocess.launch(
            executable: nodePath,
            arguments: ["--disable-warning=ExperimentalWarning", scriptPath],
            environment: env,
            onStderrLine: { line in
                stderrLock.lock()
                stderrLines.append(line)
                stderrLock.unlock()
            },
            onExit: { [weak self] _ in
                guard let self else { return }
                // The child is gone: release the process slot and the in-flight
                // claim on the owning queue so a later start can proceed cleanly.
                self.lifecycleQueue.async {
                    self.process = nil
                    self.startInFlight = false
                }
                DispatchQueue.main.async {
                    // Only flip to stopped if we were the one running (not already restarted)
                    if case .running = self.status {
                        self.status = .stopped
                    }
                }
            }
        )

        // Publish the live reference and clear the in-flight claim on the owning
        // queue. The launch above already started the child; pollHealth only reads
        // status, so it is safe to dispatch this asynchronously.
        lifecycleQueue.async { [weak self] in
            self?.process = proc
            self?.startInFlight = false
        }

        // Poll /health until the server is up (max ~2.5s with 5 retries).
        // The closure captures stderrLines by reference so the failure diagnostic
        // sees all lines that arrived by the time we give up.
        pollHealth(port: port, retriesLeft: 5, stderrSnapshot: {
            stderrLock.lock()
            defer { stderrLock.unlock() }
            return stderrLines
        })
    }

    private func pollHealth(port: Int, retriesLeft: Int, stderrSnapshot: @escaping () -> [String]) {
        let url = URL(string: "http://127.0.0.1:\(port)/health")!
        let task = URLSession.shared.dataTask(with: url) { [weak self] data, response, _ in
            guard let self else { return }
            let ok = (response as? HTTPURLResponse)?.statusCode == 200
            if ok {
                // Capture any startup warnings that arrived before /health responded.
                // Logging here preserves diagnostics without delaying the .running transition.
                let startupStderr = stderrSnapshot()
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !startupStderr.isEmpty {
                    ClippyLog.info("MCP server startup stderr: \(startupStderr)", category: ClippyLog.mcp)
                }
                ClippyLog.info("MCP server running on port \(port)", category: ClippyLog.mcp)
                DispatchQueue.main.async { self.status = .running(port: port) }
            } else if retriesLeft > 0 {
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                    self.pollHealth(port: port, retriesLeft: retriesLeft - 1, stderrSnapshot: stderrSnapshot)
                }
            } else {
                // Snapshot the stderr lines collected so far for the diagnostic message.
                let detail = stderrSnapshot()
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let msg = detail.isEmpty ? "Server did not respond to /health after launch." : detail
                ClippyLog.error("MCP server failed to start: \(msg)", category: ClippyLog.mcp)
                DispatchQueue.main.async { self.status = .failed(msg) }
            }
        }
        task.resume()
    }

    func stop() {
        ClippyLog.info("MCP server stopping", category: ClippyLog.mcp)
        // Terminate and release the child on its owning queue. Clear any pending
        // start claim too, so a stop during startup cannot wedge the sentinel.
        lifecycleQueue.sync {
            process?.terminate()
            process = nil
            startInFlight = false
        }
        DispatchQueue.main.async { [weak self] in
            self?.status = .stopped
        }
    }

    func restart() {
        // Capture the live process reference on the owning queue before stop()
        // nils it out, so we can wait on the exact child we are replacing.
        let dying = lifecycleQueue.sync { process }
        stop()
        DispatchQueue.global().async { [weak self] in
            // Wait for the old process to actually exit so the OS reclaims the
            // bound port before _start() tries to bind again. A fixed delay is
            // not reliable because SIGTERM delivery and teardown time vary.
            // waitUntilExit() blocks the background thread (never the main thread).
            // We bound the wait to 2s so a stuck child cannot stall the restart
            // indefinitely; if it times out we proceed and let _start() handle
            // any portInUse outcome normally.
            if let dying {
                let exited = DispatchSemaphore(value: 0)
                DispatchQueue.global().async {
                    dying.waitUntilExit()
                    exited.signal()
                }
                _ = exited.wait(timeout: .now() + 2.0)
            }
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
