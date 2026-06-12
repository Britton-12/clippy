import XCTest
@testable import Clippy

final class OnePasswordItemDetailTests: XCTestCase {

    // MARK: - parseItemDetail: top-level fields

    func testLoginWithTOTP_topLevelFieldsParsed() {
        let detail = parsed(OPFixtures.loginWithTOTP)
        XCTAssertEqual(detail.id, "login001")
        XCTAssertEqual(detail.title, "My Web Login")
        XCTAssertEqual(detail.category, "LOGIN")
        XCTAssertEqual(detail.fields.count, 3)
    }

    func testLoginWithTOTP_usernameField() {
        let fields = parsed(OPFixtures.loginWithTOTP).fields
        let username = fields.first { $0.id == "username" }
        XCTAssertNotNil(username)
        XCTAssertEqual(username?.type, .string)
        XCTAssertEqual(username?.value, "alice@example.com")
        XCTAssertEqual(username?.purpose, "USERNAME")
        XCTAssertNil(username?.section)
    }

    func testLoginWithTOTP_passwordFieldIsConcealed() {
        let fields = parsed(OPFixtures.loginWithTOTP).fields
        let pw = fields.first { $0.id == "password" }
        XCTAssertEqual(pw?.type, .concealed)
        XCTAssertTrue(pw?.type.isConcealed == true)
        XCTAssertEqual(pw?.value, "S3cr3tP@ss")
        XCTAssertEqual(pw?.purpose, "PASSWORD")
    }

    func testLoginWithTOTP_otpFieldRecognized() {
        let fields = parsed(OPFixtures.loginWithTOTP).fields
        let otp = fields.first { $0.id == "totpfield" }
        XCTAssertEqual(otp?.type, .otp)
        XCTAssertTrue(otp?.type.isOTP == true)
        // Value is present in the fixture (the otpauth URI); parser keeps it.
        XCTAssertNotNil(otp?.value)
    }

    // MARK: - parseItemDetail: multiple CONCEALED fields

    func testMultiConcealed_bothConcealedFieldsPresent() {
        let detail = parsed(OPFixtures.multiConcealed)
        let concealed = detail.fields.filter { $0.type.isConcealed }
        XCTAssertEqual(concealed.count, 2)
        let labels = concealed.map(\.label)
        XCTAssertTrue(labels.contains("secret key"))
        XCTAssertTrue(labels.contains("restricted key"))
    }

    func testMultiConcealed_valuesRetained() {
        let detail = parsed(OPFixtures.multiConcealed)
        let secretKey = detail.fields.first { $0.id == "credential" }
        XCTAssertEqual(secretKey?.value, "sk_live_YYYY")
        let restricted = detail.fields.first { $0.id == "restricted" }
        XCTAssertEqual(restricted?.value, "rk_live_ZZZZ")
    }

    // MARK: - parseItemDetail: sections

    func testCustomSections_sectionLabelsResolved() {
        let detail = parsed(OPFixtures.customSections)
        let sshFields = detail.fields.filter { $0.section?.id == "ssh_section" }
        let dbFields  = detail.fields.filter { $0.section?.id == "db_section" }
        XCTAssertEqual(sshFields.count, 2)
        XCTAssertEqual(dbFields.count, 2)
        XCTAssertEqual(sshFields.first?.section?.label, "SSH")
        XCTAssertEqual(dbFields.first?.section?.label, "Database")
    }

    func testCustomSections_unsectionedFieldHasNilSection() {
        let detail = parsed(OPFixtures.customSections)
        let hostname = detail.fields.first { $0.id == "hostname" }
        XCTAssertNil(hostname?.section)
    }

    func testCustomSections_sectionedFieldsOrder() {
        let detail = parsed(OPFixtures.customSections)
        // sectionedFields must produce: nil-section bucket, ssh_section, db_section.
        let buckets = detail.sectionedFields
        XCTAssertEqual(buckets.count, 3)
        XCTAssertNil(buckets[0].section)
        XCTAssertEqual(buckets[1].section?.id, "ssh_section")
        XCTAssertEqual(buckets[2].section?.id, "db_section")
    }

    func testCustomSections_concealedFieldInSection() {
        let detail = parsed(OPFixtures.customSections)
        let sshPass = detail.fields.first { $0.id == "ssh_pass" }
        XCTAssertEqual(sshPass?.type, .concealed)
        XCTAssertEqual(sshPass?.section?.label, "SSH")
        XCTAssertEqual(sshPass?.value, "kP@ssphrase")
    }

    // MARK: - parseItemDetail: API credential without sections

    func testAPICredential_fieldsWithoutSections() {
        let detail = parsed(OPFixtures.apiCredentialNoSections)
        XCTAssertEqual(detail.category, "API_CREDENTIAL")
        XCTAssertEqual(detail.fields.count, 2)
        XCTAssertTrue(detail.fields.allSatisfy { $0.section == nil })
    }

    func testAPICredential_sectionedFieldsHasOneBucket() {
        let detail = parsed(OPFixtures.apiCredentialNoSections)
        XCTAssertEqual(detail.sectionedFields.count, 1)
        XCTAssertNil(detail.sectionedFields[0].section)
        XCTAssertEqual(detail.sectionedFields[0].fields.count, 2)
    }

    // MARK: - parseItemDetail: empty / nil values

    func testEmptyValueFields_emptyStringBecomesNil() {
        let detail = parsed(OPFixtures.emptyValueFields)
        let username = detail.fields.first { $0.id == "username" }
        // Empty string value is normalized to nil.
        XCTAssertNil(username?.value)
    }

    func testEmptyValueFields_missingValueKeyBecomesNil() {
        let detail = parsed(OPFixtures.emptyValueFields)
        let notes = detail.fields.first { $0.id == "notes" }
        XCTAssertNil(notes?.value)
    }

    func testEmptyValueFields_realConcealedValueRetained() {
        let detail = parsed(OPFixtures.emptyValueFields)
        let pw = detail.fields.first { $0.id == "password" }
        XCTAssertEqual(pw?.value, "real_pass")
    }

    // MARK: - parseItemDetail: inline section label fallback

    func testInlineSectionLabel_usedWhenNoTopLevelSections() {
        let detail = parsed(OPFixtures.inlineSectionLabel)
        let field = detail.fields.first
        XCTAssertEqual(field?.section?.id, "sec_abc")
        XCTAssertEqual(field?.section?.label, "My Custom Section")
    }

    // MARK: - parseItemDetail: malformed input

    func testNilOnMissingID() {
        let json = """
        {"title":"No ID","category":"LOGIN","fields":[]}
        """
        XCTAssertNil(OnePasswordService.parseItemDetail(Data(json.utf8)))
    }

    func testNilOnMissingTitle() {
        let json = """
        {"id":"x","category":"LOGIN","fields":[]}
        """
        XCTAssertNil(OnePasswordService.parseItemDetail(Data(json.utf8)))
    }

    func testEmptyFieldsArray() {
        let json = """
        {"id":"x","title":"Empty","category":"LOGIN","fields":[]}
        """
        let detail = parsed(json)
        XCTAssertEqual(detail.fields.count, 0)
        XCTAssertEqual(detail.sectionedFields.count, 0)
    }

    func testUnknownFieldTypePreserved() {
        let json = """
        {"id":"x","title":"T","category":"LOGIN","fields":[
          {"id":"f1","label":"weird","type":"FUTURE_TYPE","value":"val"}
        ]}
        """
        let detail = parsed(json)
        XCTAssertEqual(detail.fields.first?.type, .unknown)
        XCTAssertEqual(detail.fields.first?.value, "val")
    }

    // MARK: - OPFieldType helpers

    func testFieldTypeIsConcealed() {
        XCTAssertTrue(OPFieldType.concealed.isConcealed)
        XCTAssertFalse(OPFieldType.string.isConcealed)
        XCTAssertFalse(OPFieldType.otp.isConcealed)
    }

    func testFieldTypeIsOTP() {
        XCTAssertTrue(OPFieldType.otp.isOTP)
        XCTAssertFalse(OPFieldType.concealed.isOTP)
        XCTAssertFalse(OPFieldType.string.isOTP)
    }

    func testFieldTypeInitCaseInsensitive() {
        XCTAssertEqual(OPFieldType(raw: "concealed"), .concealed)
        XCTAssertEqual(OPFieldType(raw: "Concealed"), .concealed)
        XCTAssertEqual(OPFieldType(raw: "otp"), .otp)
        XCTAssertEqual(OPFieldType(raw: "STRING"), .string)
        XCTAssertEqual(OPFieldType(raw: "nonsense"), .unknown)
    }

    // MARK: - Existing parseItems tests remain unaffected (regression guard)

    func testParseItemsStillWorksAfterModelChanges() {
        let json = """
        [{"id":"a1","title":"alpha","category":"LOGIN"}]
        """
        let items = OnePasswordService.parseItems(Data(json.utf8))
        XCTAssertEqual(items.first?.id, "a1")
    }

    // MARK: - Helpers

    private func parsed(_ json: String) -> OPItemDetail {
        let detail = OnePasswordService.parseItemDetail(Data(json.utf8))
        XCTAssertNotNil(detail, "parseItemDetail returned nil for fixture")
        return detail ?? OPItemDetail(id: "", title: "", category: "", fields: [])
    }
}
