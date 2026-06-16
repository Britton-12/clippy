import XCTest
@testable import Clippy

// Tests for StreamParser / SSEStreamParser protocol conformances.
// Each test feeds canned wire bytes and asserts the emitted text deltas and
// final AIToolCall list match expectations exactly (id, toolName, arguments).

final class StreamParserTests: XCTestCase {

    // MARK: - OpenAI (SSEStreamParser)

    func testOpenAITextOnlyStream() {
        var acc = OpenAIStreamAccumulator()
        let lines = [
            "data: {\"choices\":[{\"delta\":{\"content\":\"Hello\"}}]}",
            "data: {\"choices\":[{\"delta\":{\"content\":\", world\"}}]}",
            "data: [DONE]",
        ]
        var deltas: [String] = []
        for line in lines {
            if let t = acc.consume(line: line) { deltas.append(t) }
        }
        XCTAssertEqual(deltas, ["Hello", ", world"])
        XCTAssertTrue(acc.finishToolCalls().isEmpty)
    }

    func testOpenAIToolCallStream() {
        // Simulates two SSE chunks that together form one tool call:
        // chunk 1 carries id + name, chunk 2 carries the argument fragment.
        var acc = OpenAIStreamAccumulator()
        let lines = [
            // First chunk: index 0, id + function name, no arguments yet
            "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_abc\",\"function\":{\"name\":\"get_weather\",\"arguments\":\"\"}}]}}]}",
            // Second chunk: argument fragment arrives
            "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"{\\\"location\\\":\\\"NYC\\\"}\"}}]}}]}",
            "data: [DONE]",
        ]
        for line in lines { _ = acc.consume(line: line) }
        let calls = acc.finishToolCalls()
        XCTAssertEqual(calls.count, 1)
        let call = calls[0]
        XCTAssertEqual(call.id, "call_abc")
        XCTAssertEqual(call.toolName, "get_weather")
        XCTAssertEqual(call.arguments["location"] as? String, "NYC")
    }

    func testOpenAIIgnoresNonDataLines() {
        var acc = OpenAIStreamAccumulator()
        // event: lines and blank lines must be silently ignored
        let lines = [
            "event: message_start",
            "",
            "data: {\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}",
        ]
        var deltas: [String] = []
        for line in lines {
            if let t = acc.consume(line: line) { deltas.append(t) }
        }
        XCTAssertEqual(deltas, ["ok"])
    }

    func testOpenAIFallbackIdWhenMissing() {
        // When no id is present in the stream, a synthetic "openai-<name>" id is used.
        var acc = OpenAIStreamAccumulator()
        let lines = [
            "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"name\":\"search\",\"arguments\":\"{\\\"q\\\":\\\"swift\\\"}\"}}]}}]}",
            "data: [DONE]",
        ]
        for line in lines { _ = acc.consume(line: line) }
        let calls = acc.finishToolCalls()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].id, "openai-search")
        XCTAssertEqual(calls[0].toolName, "search")
        XCTAssertEqual(calls[0].arguments["q"] as? String, "swift")
    }

    // MARK: - Anthropic (SSEStreamParser)

    func testAnthropicToolUseStream() {
        // Simulates the Anthropic SSE event sequence for a tool_use block:
        //   content_block_start  -- declares the block type, id, name
        //   content_block_delta  -- input_json_delta carries partial_json
        //   content_block_delta  -- second fragment (tests += accumulation)
        //   message_delta        -- stop_reason = "tool_use"
        var acc = AnthropicStreamAccumulator()
        let lines = [
            "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_01\",\"name\":\"calculator\"}}",
            "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"a\\\":\"}}",
            "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"42}\"}}",
            "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"}}",
        ]
        var deltas: [String] = []
        for line in lines {
            if let t = acc.consume(line: line) { deltas.append(t) }
        }
        XCTAssertTrue(deltas.isEmpty, "tool_use stream should emit no text deltas")
        let calls = acc.finishToolCalls()
        XCTAssertEqual(calls.count, 1)
        let call = calls[0]
        XCTAssertEqual(call.id, "toolu_01")
        XCTAssertEqual(call.toolName, "calculator")
        XCTAssertEqual(call.arguments["a"] as? Int, 42)
    }

    func testAnthropicTextDeltaStream() {
        var acc = AnthropicStreamAccumulator()
        let lines = [
            "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\"}}",
            "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Hi\"}}",
            "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\" there\"}}",
            "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"}}",
        ]
        var deltas: [String] = []
        for line in lines {
            if let t = acc.consume(line: line) { deltas.append(t) }
        }
        XCTAssertEqual(deltas, ["Hi", " there"])
        XCTAssertTrue(acc.finishToolCalls().isEmpty, "end_turn should yield no tool calls")
    }

    func testAnthropicIgnoresNonDataLines() {
        var acc = AnthropicStreamAccumulator()
        let lines = [
            "event: content_block_delta",
            "",
            "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"x\"}}",
        ]
        var deltas: [String] = []
        for line in lines {
            if let t = acc.consume(line: line) { deltas.append(t) }
        }
        XCTAssertEqual(deltas, ["x"])
    }

    // MARK: - Ollama (StreamParser, plain JSONL)

    func testOllamaToolCallStream() {
        // Ollama sends plain JSON objects, not SSE. arguments may be a dict or a
        // JSON string -- test the dict form here.
        var acc = OllamaStreamAccumulator()
        let lines = [
            "{\"message\":{\"role\":\"assistant\",\"content\":\"\",\"tool_calls\":[{\"function\":{\"name\":\"get_time\",\"arguments\":{\"tz\":\"UTC\"}}}]}}",
            "{\"message\":{\"role\":\"assistant\",\"content\":\"\"},\"done\":true}",
        ]
        for line in lines { _ = acc.consume(line: line) }
        let calls = acc.finishToolCalls()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].id, "ollama-1")
        XCTAssertEqual(calls[0].toolName, "get_time")
        XCTAssertEqual(calls[0].arguments["tz"] as? String, "UTC")
    }

    func testOllamaTextStream() {
        var acc = OllamaStreamAccumulator()
        let lines = [
            "{\"message\":{\"role\":\"assistant\",\"content\":\"Hello\"}}",
            "{\"message\":{\"role\":\"assistant\",\"content\":\"!\"}}",
            "{\"message\":{\"role\":\"assistant\",\"content\":\"\"},\"done\":true}",
        ]
        var deltas: [String] = []
        for line in lines {
            if let t = acc.consume(line: line) { deltas.append(t) }
        }
        XCTAssertEqual(deltas, ["Hello", "!"])
        XCTAssertTrue(acc.finishToolCalls().isEmpty)
    }

    func testOllamaArgumentsAsJsonString() {
        // Ollama sometimes sends arguments as a JSON-encoded string rather than a dict.
        var acc = OllamaStreamAccumulator()
        let argsJson = "{\"city\":\"Paris\"}"
            .replacingOccurrences(of: "\"", with: "\\\"")
        let line = "{\"message\":{\"tool_calls\":[{\"function\":{\"name\":\"weather\",\"arguments\":\"\(argsJson)\"}}]}}"
        _ = acc.consume(line: line)
        let calls = acc.finishToolCalls()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].arguments["city"] as? String, "Paris")
    }

    // MARK: - Protocol conformance

    func testAllConformToStreamParser() {
        // Compile-time proof that all three types satisfy StreamParser.
        // If any conformance is missing this test won't compile.
        var parsers: [any StreamParser] = [
            OpenAIStreamAccumulator(),
            AnthropicStreamAccumulator(),
            OllamaStreamAccumulator(),
        ]
        for i in parsers.indices {
            _ = parsers[i].consume(line: "")
            _ = parsers[i].finishToolCalls()
        }
    }
}
