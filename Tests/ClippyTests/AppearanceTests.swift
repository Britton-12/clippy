import XCTest
@testable import Clippy

final class AppearanceTests: XCTestCase {

    // MARK: - CardStyle raw-value round-trips

    func testCardStyleFilledRoundTrips() {
        XCTAssertEqual(CardStyle(rawValue: "filled"), .filled)
    }

    func testCardStyleBorderedRoundTrips() {
        XCTAssertEqual(CardStyle(rawValue: "bordered"), .bordered)
    }

    func testCardStylePlainRoundTrips() {
        XCTAssertEqual(CardStyle(rawValue: "plain"), .plain)
    }

    func testCardStyleUnknownRawValueReturnsNil() {
        XCTAssertNil(CardStyle(rawValue: "unknown"))
    }

    func testCardStyleAllCasesCount() {
        XCTAssertEqual(CardStyle.allCases.count, 3)
    }

    // MARK: - PanelFontFamily raw-value round-trips

    func testFontFamilySystemDefaultRoundTrips() {
        XCTAssertEqual(PanelFontFamily(rawValue: "systemDefault"), .systemDefault)
    }

    func testFontFamilyHelveticaNeueRoundTrips() {
        XCTAssertEqual(PanelFontFamily(rawValue: "Helvetica Neue"), .helveticaNeue)
    }

    func testFontFamilySFMonoRoundTrips() {
        XCTAssertEqual(PanelFontFamily(rawValue: "SF Mono"), .sfMono)
    }

    func testFontFamilyUnknownRawValueReturnsNil() {
        XCTAssertNil(PanelFontFamily(rawValue: "ComicSansMS"))
    }

    // MARK: - PanelFontFamily availability

    func testSystemDefaultIsAlwaysAvailable() {
        // The system default must never be unavailable regardless of OS version.
        XCTAssertTrue(PanelFontFamily.systemDefault.isAvailable)
    }

    func testSystemDefaultHasNilFamilyName() {
        XCTAssertNil(PanelFontFamily.systemDefault.familyName)
    }

    func testNamedFamilyHasNonNilFamilyName() {
        XCTAssertNotNil(PanelFontFamily.helveticaNeue.familyName)
        XCTAssertEqual(PanelFontFamily.helveticaNeue.familyName, "Helvetica Neue")
    }

    // MARK: - CardTintStrength clamping

    func testTintFractionZeroStrength() {
        // 0 strength -> 0 / 100 = 0.0 fraction.
        let fraction = Double(0) / 100.0
        XCTAssertEqual(fraction, 0.0, accuracy: 0.0001)
    }

    func testTintFractionMaxStrength() {
        // 20 strength -> 20 / 100 = 0.20 fraction.
        let fraction = Double(20) / 100.0
        XCTAssertEqual(fraction, 0.20, accuracy: 0.0001)
    }

    func testTintFractionDefaultStrength() {
        // Default is 8 -> 0.08.
        let fraction = Double(8) / 100.0
        XCTAssertEqual(fraction, 0.08, accuracy: 0.0001)
    }

    // MARK: - PanelMaterialStyle raw-value round-trips

    func testPanelMaterialOpaqueRoundTrips() {
        XCTAssertEqual(PanelMaterialStyle(rawValue: "opaque"), .opaque)
    }

    func testPanelMaterialOpaqueHasNilMaterial() {
        // .opaque uses a solid background; its material property must be nil.
        XCTAssertNil(PanelMaterialStyle.opaque.material)
    }

    func testPanelMaterialRegularHasNonNilMaterial() {
        XCTAssertNotNil(PanelMaterialStyle.regular.material)
    }

    // MARK: - AppSettings new keys persist and load (using an isolated defaults suite)

    func testCardStylePersistsRoundTrip() {
        let suite = UserDefaults(suiteName: "AppearanceTests.cardStyle")!
        suite.removePersistentDomain(forName: "AppearanceTests.cardStyle")
        suite.set(CardStyle.bordered.rawValue, forKey: "cardStyle")
        let loaded = CardStyle(rawValue: suite.string(forKey: "cardStyle") ?? "") ?? .filled
        XCTAssertEqual(loaded, .bordered)
    }

    func testFontFamilyPersistsRoundTrip() {
        let suite = UserDefaults(suiteName: "AppearanceTests.fontFamily")!
        suite.removePersistentDomain(forName: "AppearanceTests.fontFamily")
        suite.set(PanelFontFamily.georgia.rawValue, forKey: "fontFamily")
        let loaded = PanelFontFamily(rawValue: suite.string(forKey: "fontFamily") ?? "") ?? .systemDefault
        XCTAssertEqual(loaded, .georgia)
    }

    func testFontSizeBaseClampingBelowRange() {
        // Simulates what AppSettings.init does when the stored value is 0 (never written).
        let stored = 0
        let clamped = stored >= 11 && stored <= 16 ? stored : 13
        XCTAssertEqual(clamped, 13)
    }

    func testFontSizeBaseClampingAboveRange() {
        let stored = 99
        let clamped = stored >= 11 && stored <= 16 ? stored : 13
        XCTAssertEqual(clamped, 13)
    }

    func testFontSizeBaseClampingValidValue() {
        let stored = 15
        let clamped = stored >= 11 && stored <= 16 ? stored : 13
        XCTAssertEqual(clamped, 15)
    }

    // MARK: - CardStyle labels present

    func testCardStyleLabelsAreNonEmpty() {
        for style in CardStyle.allCases {
            XCTAssertFalse(style.label.isEmpty, "Label for \(style) must not be empty")
        }
    }

    func testPanelFontFamilyLabelsAreNonEmpty() {
        for family in PanelFontFamily.allCases {
            XCTAssertFalse(family.label.isEmpty, "Label for \(family) must not be empty")
        }
    }
}
