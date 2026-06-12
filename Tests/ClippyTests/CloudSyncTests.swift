import XCTest
import CloudKit
@testable import Clippy

final class CloudRecordMapperTests: XCTestCase {
    private let mapper = CloudRecordMapper()

    private func textClip(_ text: String, title: String? = nil) -> Clip {
        Clip(id: 5, contentText: text, contentRTF: nil, contentHTML: nil,
             typeIdentifier: "public.utf8-plain-text", sourceAppBundleID: "com.app",
             sourceAppName: "App", createdAt: Date(timeIntervalSince1970: 1000),
             contentKind: .text, mediaFilename: nil, thumbFilename: nil,
             pixelWidth: nil, pixelHeight: nil, byteSize: nil, userTitle: title)
    }

    func testTextClipRoundTrip() {
        let clip = textClip("hello world", title: "Greeting")
        let record = mapper.record(for: clip)
        XCTAssertEqual(record.recordType, CloudSchema.clipType)

        let back = mapper.clip(from: record)
        XCTAssertEqual(back?.contentText, "hello world")
        XCTAssertEqual(back?.userTitle, "Greeting")
        XCTAssertEqual(back?.sourceAppName, "App")
        XCTAssertEqual(back?.sourceAppBundleID, "com.app")
        XCTAssertEqual(back?.contentKind, .text)
        XCTAssertEqual(back?.createdAt, Date(timeIntervalSince1970: 1000))
    }

    func testImageClipRoundTripAndStableName() {
        let clip = Clip(id: 1, contentText: "", contentRTF: nil, contentHTML: nil,
                        typeIdentifier: "public.png", sourceAppBundleID: nil, sourceAppName: nil,
                        createdAt: Date(timeIntervalSince1970: 2000), contentKind: .image,
                        mediaFilename: "abc.png", thumbFilename: "abc-thumb.jpg",
                        pixelWidth: 120, pixelHeight: 80, byteSize: 4096, userTitle: nil)
        XCTAssertEqual(mapper.recordName(for: clip), "clip-img-abc.png")

        let back = mapper.clip(from: mapper.record(for: clip))
        XCTAssertEqual(back?.contentKind, .image)
        XCTAssertEqual(back?.mediaFilename, "abc.png")
        XCTAssertEqual(back?.pixelWidth, 120)
        XCTAssertEqual(back?.byteSize, 4096)
    }

    func testTextRecordNameIsContentStableAcrossIDs() {
        let a = textClip("same text")
        var b = textClip("same text")
        b.id = 99
        XCTAssertEqual(mapper.recordName(for: a), mapper.recordName(for: b),
                       "same content must map to the same record name on any device")
    }

    func testCategoryRoundTrip() {
        let category = Category(id: 2, name: "Work", colorHex: "#007AFF", iconKind: .symbol,
                                iconValue: "briefcase", sortOrder: 3, isStarter: false,
                                createdAt: Date(timeIntervalSince1970: 500))
        let record = mapper.record(for: category)
        XCTAssertEqual(record.recordType, CloudSchema.categoryType)

        let back = mapper.category(from: record)
        XCTAssertEqual(back?.name, "Work")
        XCTAssertEqual(back?.colorHex, "#007AFF")
        XCTAssertEqual(back?.iconKind, .symbol)
        XCTAssertEqual(back?.iconValue, "briefcase")
        XCTAssertEqual(back?.sortOrder, 3)
        XCTAssertEqual(back?.isStarter, false)
    }

    func testWrongRecordTypeReturnsNil() {
        let record = CKRecord(recordType: "Something",
                              recordID: CKRecord.ID(recordName: "x", zoneID: mapper.zoneID))
        XCTAssertNil(mapper.clip(from: record))
        XCTAssertNil(mapper.category(from: record))
    }
}
