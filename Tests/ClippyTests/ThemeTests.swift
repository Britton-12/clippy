import XCTest
import AppKit
@testable import Clippy

final class ThemeTests: XCTestCase {

    // MARK: - Hex round-trip

    func testHexRoundTrip() {
        for hex in ["#0D1117", "#FFFFFF", "#1F2328", "#03DAC6", "#BD93F9"] {
            let color = NSColor(themeHex: hex)
            XCTAssertNotNil(color, "\(hex) should parse")
            XCTAssertEqual(color?.themeHexString, hex, "\(hex) should round-trip")
        }
    }

    func testShortHexParses() {
        XCTAssertNotNil(NSColor(themeHex: "#0F0"))
        XCTAssertNotNil(NSColor(themeHex: "0F0"))  // leading # optional
    }

    func testEightDigitHexParsesAlpha() {
        XCTAssertNotNil(NSColor(themeHex: "#11223344"))
    }

    func testInvalidHexReturnsNil() {
        XCTAssertNil(NSColor(themeHex: "nothex"))
        XCTAssertNil(NSColor(themeHex: "#12"))
    }

    // MARK: - Preset token tables

    func testNamedPresetsHaveFixedTokens() {
        let named: [ThemePreset] = [.cleanLight, .githubDark, .dracula, .materialDarkPlus, .nord, .oneDark, .solarizedDark]
        for preset in named {
            XCTAssertNotNil(preset.fixedTokens, "\(preset.label) must define a token table")
        }
    }

    func testDynamicPresetsHaveNoFixedTokens() {
        XCTAssertNil(ThemePreset.system.fixedTokens)
        XCTAssertNil(ThemePreset.custom.fixedTokens)
    }

    func testDarkPresetsMarkedDark() {
        XCTAssertTrue(ThemePreset.githubDark.fixedTokens!.isDark)
        XCTAssertTrue(ThemePreset.dracula.fixedTokens!.isDark)
        XCTAssertFalse(ThemePreset.cleanLight.fixedTokens!.isDark)
    }

    func testCustomSeedIsCleanLight() {
        XCTAssertEqual(Theme.customSeed.panel.themeHexString, "#FFFFFF")
        XCTAssertEqual(Theme.customSeed.accent.themeHexString, "#0969DA")
    }

    func testSelectableIncludesSystemAndCustom() {
        XCTAssertTrue(ThemePreset.selectable.contains(.system))
        XCTAssertTrue(ThemePreset.selectable.contains(.custom))
        XCTAssertEqual(ThemePreset.selectable.count, ThemePreset.allCases.count)
    }
}
