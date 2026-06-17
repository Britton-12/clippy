import Foundation

/// One low-level event from a provider's streamed response.
enum AIStreamEvent {
    case textDelta(String)
    case toolCalls([AIToolCall])
    case done
}

/// One high-level event from the streaming agent loop, consumed by the UI.
enum AIAgentEvent {
    case textDelta(String)
    case toolStarted(String)
    case toolFinished(String)
}

/// Streaming HTTP: POST a JSON body and yield each response line as it arrives,
/// with an overall deadline and an idle (no-bytes) timeout so a wedged
/// connection cannot hang the caller forever.
enum AIStreamingHTTP {
    static func postLines(
        url urlString: String,
        headers: [String: String],
        body: [String: Any],
        overallTimeout: TimeInterval = 120,
        idleTimeout: TimeInterval = 30
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let work = Task.detached {
                guard let url = URL(string: urlString) else {
                    continuation.finish(throwing: AIError.badURL(urlString)); return
                }
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.timeoutInterval = overallTimeout
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
                do {
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)
                } catch {
                    continuation.finish(throwing: error); return
                }

                let lastActivity = ActivityClock()
                let watchdog = Task.detached {
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(1))
                        if lastActivity.secondsSince() > idleTimeout {
                            continuation.finish(throwing: AIError.http(-1, "stream idle timeout"))
                            return
                        }
                    }
                }
                defer { watchdog.cancel() }

                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    if let http = response as? HTTPURLResponse,
                       !(200..<300).contains(http.statusCode) {
                        var errText = ""
                        for try await line in bytes.lines { errText += line; if errText.count > 2000 { break } }
                        continuation.finish(throwing: AIError.http(http.statusCode, errText)); return
                    }
                    for try await line in bytes.lines {
                        lastActivity.bump()
                        continuation.yield(line)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in work.cancel() }
        }
    }
}

/// Tiny monotonic activity marker for the idle watchdog.
final class ActivityClock: @unchecked Sendable {
    private var last = Date()
    private let lock = NSLock()
    func bump() { lock.lock(); last = Date(); lock.unlock() }
    func secondsSince() -> TimeInterval { lock.lock(); defer { lock.unlock() }; return Date().timeIntervalSince(last) }
}
