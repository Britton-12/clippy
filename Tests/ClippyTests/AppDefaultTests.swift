import Combine
import Foundation
import XCTest
@testable import Clippy

// MARK: - AppDefault property wrapper tests
//
// These tests use throwaway UserDefaults keys (unique per test) cleaned up
// in tearDown. All tests run against UserDefaults.standard because
// @AppDefault is hardwired to .standard (no injection point by design).

// MARK: - Test fixture types

private enum FixtureColor: String, Equatable {
    case red
    case green
    case blue
}

private class FixtureSettings: ObservableObject {
    init() {}
    // Unique key prefixes chosen to avoid colliding with live app keys.
    @AppDefault("_test.appdefault.label", default: "hello")
    var label: String

    @AppDefault("_test.appdefault.enabled", default: false)
    var enabled: Bool

    @AppDefault("_test.appdefault.color", default: FixtureColor.red)
    var color: FixtureColor
}

// MARK: - Tests

final class AppDefaultTests: XCTestCase {
    private var fixture: FixtureSettings!
    private var cancellables: Set<AnyCancellable> = []

    private let labelKey   = "_test.appdefault.label"
    private let enabledKey = "_test.appdefault.enabled"
    private let colorKey   = "_test.appdefault.color"

    override func setUp() {
        super.setUp()
        // Clean slate before each test.
        UserDefaults.standard.removeObject(forKey: labelKey)
        UserDefaults.standard.removeObject(forKey: enabledKey)
        UserDefaults.standard.removeObject(forKey: colorKey)
        fixture = FixtureSettings()
        cancellables = []
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: labelKey)
        UserDefaults.standard.removeObject(forKey: enabledKey)
        UserDefaults.standard.removeObject(forKey: colorKey)
        fixture = nil
        cancellables = []
        super.tearDown()
    }

    // MARK: String (plist)

    func testStringDefaultReturnedWhenKeyAbsent() {
        XCTAssertEqual(fixture.label, "hello")
    }

    func testStringSetsValueInUserDefaults() {
        fixture.label = "world"
        XCTAssertEqual(UserDefaults.standard.string(forKey: labelKey), "world")
    }

    func testStringReflectsExternallyStoredValue() {
        UserDefaults.standard.set("external", forKey: labelKey)
        // Re-create fixture so it reads fresh (wrapper reads on each access).
        let fresh = FixtureSettings()
        XCTAssertEqual(fresh.label, "external")
    }

    // MARK: Bool (plist)

    func testBoolDefaultReturnedWhenKeyAbsent() {
        XCTAssertFalse(fixture.enabled)
    }

    func testBoolSetsValueInUserDefaults() {
        fixture.enabled = true
        XCTAssertTrue(UserDefaults.standard.bool(forKey: enabledKey))
    }

    func testBoolReflectsExternallyStoredValue() {
        UserDefaults.standard.set(true, forKey: enabledKey)
        let fresh = FixtureSettings()
        XCTAssertTrue(fresh.enabled)
    }

    // MARK: RawRepresentable enum

    func testEnumDefaultReturnedWhenKeyAbsent() {
        XCTAssertEqual(fixture.color, .red)
    }

    func testEnumSetsRawValueInUserDefaults() {
        fixture.color = .green
        XCTAssertEqual(UserDefaults.standard.string(forKey: colorKey), "green")
    }

    func testEnumReadsRawValueFromUserDefaults() {
        UserDefaults.standard.set("blue", forKey: colorKey)
        let fresh = FixtureSettings()
        XCTAssertEqual(fresh.color, .blue)
    }

    func testEnumFallsBackToDefaultOnBogusStoredValue() {
        // Store a string that has no matching case.
        UserDefaults.standard.set("ultraviolet", forKey: colorKey)
        let fresh = FixtureSettings()
        // Should fall back to the declared default (.red), not crash.
        XCTAssertEqual(fresh.color, .red)
    }

    // MARK: objectWillChange fires on set

    func testObjectWillChangeFiredOnStringSet() {
        var callCount = 0
        fixture.objectWillChange
            .sink { callCount += 1 }
            .store(in: &cancellables)

        fixture.label = "trigger"
        // objectWillChange fires synchronously before the value is written.
        XCTAssertEqual(callCount, 1)
    }

    func testObjectWillChangeFiredOnBoolSet() {
        var callCount = 0
        fixture.objectWillChange
            .sink { callCount += 1 }
            .store(in: &cancellables)

        fixture.enabled = true
        XCTAssertEqual(callCount, 1)
    }

    func testObjectWillChangeFiredOnEnumSet() {
        var callCount = 0
        fixture.objectWillChange
            .sink { callCount += 1 }
            .store(in: &cancellables)

        fixture.color = .blue
        XCTAssertEqual(callCount, 1)
    }

    func testObjectWillChangeNotFiredWithoutSet() {
        var callCount = 0
        fixture.objectWillChange
            .sink { callCount += 1 }
            .store(in: &cancellables)

        // Read-only access must not trigger the publisher.
        _ = fixture.label
        _ = fixture.enabled
        _ = fixture.color
        XCTAssertEqual(callCount, 0)
    }

    // MARK: Notification-mechanism safeguard

    // AppDefault's enclosing-instance subscript constrains
    // EnclosingSelf.ObjectWillChangePublisher == ObservableObjectPublisher,
    // making a silent-no-notification regression impossible at compile time
    // for any type that the wrapper is used on. The tests below document
    // that this constraint holds for the test fixture and that the publisher
    // is the concrete ObservableObjectPublisher, not a custom type.

    func testFixturePublisherIsObservableObjectPublisher() {
        // If FixtureSettings.objectWillChange were ever changed to a custom
        // publisher type, @AppDefault inside it would stop compiling (the
        // where clause in the static subscript would not be satisfied). This
        // test explicitly checks the concrete type as an early-warning
        // canary at the Swift runtime level.
        let publisher = fixture.objectWillChange
        XCTAssertNotNil(
            publisher as? ObservableObjectPublisher,
            "FixtureSettings.objectWillChange must be ObservableObjectPublisher; " +
            "a custom publisher type would break the @AppDefault where-clause constraint."
        )
    }

    func testObjectWillChangeFiredExactlyOncePerSetNotPerGet() {
        // Guards against a regression where the subscript getter accidentally
        // triggers the publisher, or the setter fires it more than once.
        var callCount = 0
        fixture.objectWillChange
            .sink { callCount += 1 }
            .store(in: &cancellables)

        _ = fixture.label    // get -- must not fire
        fixture.label = "a"  // set -- fires once
        _ = fixture.label    // get -- must not fire again
        XCTAssertEqual(callCount, 1)
    }
}
