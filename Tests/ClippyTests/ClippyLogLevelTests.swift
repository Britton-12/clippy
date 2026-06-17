import Foundation
import XCTest
import os
@testable import Clippy

// MARK: - ClippyLog.LogLevel tests
//
// Covers two things:
//   1. The Comparable ordering of LogLevel (pure value logic, no I/O).
//   2. The threshold gate driving the file sink: below-threshold messages
//      never reach the file, at/above-threshold messages do.
//
// The file sink writes to a fixed path on a serial queue. To stay
// deterministic and not flaky we (a) tag every test message with a fresh
// UUID so we never collide with prior content, (b) flush the serial queue
// via ClippyLog.flushForTesting() before reading, and (c) restore the
// global threshold in tearDown so test order cannot leak state.

final class ClippyLogLevelTests: XCTestCase {

    private var savedThreshold: ClippyLog.LogLevel!

    override func setUp() {
        super.setUp()
        savedThreshold = ClippyLog.threshold
    }

    override func tearDown() {
        ClippyLog.threshold = savedThreshold
        super.tearDown()
    }

    // MARK: - Comparable ordering

    func testLogLevelOrdering() {
        XCTAssertLessThan(ClippyLog.LogLevel.verbose, .debug)
        XCTAssertLessThan(ClippyLog.LogLevel.debug, .info)
        XCTAssertLessThan(ClippyLog.LogLevel.info, .warning)
        XCTAssertLessThan(ClippyLog.LogLevel.warning, .error)

        // allCases is declared in ascending severity; confirm sort is a no-op.
        XCTAssertEqual(ClippyLog.LogLevel.allCases,
                       ClippyLog.LogLevel.allCases.sorted())

        // rawValue-derived comparison, both directions.
        XCTAssertGreaterThan(ClippyLog.LogLevel.error, .verbose)
    }

    // MARK: - File-sink gating

    func testThresholdGatesFileSink() throws {
        ClippyLog.threshold = .warning

        // A message that must be dropped, and one that must be written.
        let belowMarker = "test-below-\(UUID().uuidString)"
        let aboveMarker = "test-above-\(UUID().uuidString)"

        ClippyLog.debug(belowMarker, category: ClippyLog.storage)
        ClippyLog.info(belowMarker, category: ClippyLog.storage)
        ClippyLog.warning(aboveMarker, category: ClippyLog.storage)
        ClippyLog.error(aboveMarker, category: ClippyLog.storage)

        // Drain the serial queue so every append has landed before we read.
        ClippyLog.flushForTesting()

        let contents = (try? String(contentsOf: ClippyLog.logFileURL, encoding: .utf8)) ?? ""

        XCTAssertFalse(contents.contains(belowMarker),
                       "debug/info must not reach the file when threshold is .warning")
        XCTAssertTrue(contents.contains(aboveMarker),
                      "warning/error must reach the file when threshold is .warning")
    }
}
