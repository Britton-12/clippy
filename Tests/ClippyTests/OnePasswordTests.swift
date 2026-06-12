import XCTest
@testable import Clippy

final class OnePasswordTests: XCTestCase {

    func testParseItemsSortsByTitleAndReadsFields() {
        let json = """
        [
          {"id":"b2","title":"Zeta API Key","category":"API_CREDENTIAL","updated_at":"2026-01-02T00:00:00Z"},
          {"id":"a1","title":"alpha login","category":"LOGIN","last_edited_at":"2026-01-01T00:00:00Z"}
        ]
        """
        let items = OnePasswordService.parseItems(Data(json.utf8))
        XCTAssertEqual(items.count, 2)
        // Case-insensitive title sort puts "alpha login" before "Zeta API Key".
        XCTAssertEqual(items.first?.id, "a1")
        XCTAssertEqual(items.first?.title, "alpha login")
        XCTAssertEqual(items.first?.category, "LOGIN")
        XCTAssertEqual(items.last?.updatedAt, "2026-01-02T00:00:00Z")
    }

    func testParseItemsIgnoresMalformedEntries() {
        let json = """
        [ {"title":"no id"}, {"id":"ok","title":"Good"} ]
        """
        let items = OnePasswordService.parseItems(Data(json.utf8))
        XCTAssertEqual(items.map(\.id), ["ok"])
    }

    func testParsePrimaryValuePrefersPasswordConcealedField() {
        let json = """
        {"id":"x","fields":[
          {"id":"username","type":"STRING","label":"username","value":"alice"},
          {"id":"password","type":"CONCEALED","label":"password","value":"s3cr3t"}
        ]}
        """
        XCTAssertEqual(OnePasswordService.parsePrimaryValue(Data(json.utf8)), "s3cr3t")
    }

    func testParsePrimaryValueFallsBackToAnyConcealed() {
        let json = """
        {"fields":[
          {"id":"username","type":"STRING","value":"alice"},
          {"id":"credential","type":"CONCEALED","label":"token","value":"tok_123"}
        ]}
        """
        XCTAssertEqual(OnePasswordService.parsePrimaryValue(Data(json.utf8)), "tok_123")
    }

    func testParsePrimaryValueNilWhenNoValues() {
        let json = """
        {"fields":[ {"id":"username","type":"STRING","value":""} ]}
        """
        XCTAssertNil(OnePasswordService.parsePrimaryValue(Data(json.utf8)))
    }
}
