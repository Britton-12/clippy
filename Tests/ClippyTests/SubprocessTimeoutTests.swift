import XCTest
@testable import Clippy

final class SubprocessTimeoutTests: XCTestCase {

    // MARK: - Subprocess.run

    func testSubprocessTimedOutFalseOnFastCommand() async {
        let output = await Subprocess.run("/bin/echo", ["hello"], timeout: 5)
        XCTAssertFalse(output.timedOut, "fast command should not time out")
        XCTAssertTrue(output.succeeded)
    }

    func testSubprocessTimedOutTrueWhenExceedsTimeout() async {
        // /bin/sleep 5 given a 0.5 s budget must time out.
        let output = await Subprocess.run("/bin/sleep", ["5"], timeout: 0.5)
        XCTAssertTrue(output.timedOut, "slow command should be marked timed out")
        XCTAssertFalse(output.succeeded, "timed-out run is not a success")
    }

    func testSubprocessTimedOutSetsStderrFallback() async {
        // A process that produces no stderr — on timeout stderr should fall
        // back to "Timed out" so callers that surface stderr still get a string.
        let output = await Subprocess.run("/bin/sleep", ["5"], timeout: 0.5)
        XCTAssertTrue(output.timedOut)
        XCTAssertEqual(output.stderr, "Timed out",
                       "empty-stderr timeout should surface the 'Timed out' fallback")
    }

    // MARK: - ScriptRunner (via Subprocess.run)

    func testScriptRunnerTimedOutTrueForSlowScript() async {
        // A shell script that sleeps longer than the given timeout.
        let script = Script(name: "slow", interpreter: .zsh, body: "sleep 5")
        let result = await ScriptRunner.run(script, timeout: 0.5)
        XCTAssertTrue(result.timedOut, "slow script should be marked timed out")
        XCTAssertFalse(result.succeeded)
    }

    func testScriptRunnerTimedOutFalseForFastScript() async {
        let script = Script(name: "fast", interpreter: .zsh, body: "echo ok")
        let result = await ScriptRunner.run(script, timeout: 5)
        XCTAssertFalse(result.timedOut, "fast script should not time out")
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "ok")
    }
}
