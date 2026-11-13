import XCTest
@testable import RedShelf

final class FeedParserTests: XCTestCase {
    func testParsesFeedCardAndVideoMetadata() throws {
        let html = #"<script>window.__INITIAL_STATE__={"feed":{"feeds":[{"id":"note-1","noteCard":{"type":"video","displayTitle":"示例","user":{"nickname":"作者"},"cover":{"urlDefault":"https://example.com/image.jpg"},"interactInfo":{"likedCount":"42"}}}]}};</script>"#
        let result = try FeedParser.parse(html)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.id, "note-1")
        XCTAssertEqual(result.first?.author, "作者")
        XCTAssertEqual(result.first?.likes, "42")
        XCTAssertEqual(result.first?.isVideo, true)
    }

    func testEmptyFeedIsNotInvented() throws {
        XCTAssertTrue(try FeedParser.parse(#"<script>window.__INITIAL_STATE__={"feed":{"feeds":[]}};</script>"#).isEmpty)
    }

    func testMissingStateFails() {
        XCTAssertThrowsError(try FeedParser.parse("<html></html>"))
    }

    func testUndefinedOutsideStringsDoesNotChangeText() throws {
        let html = #"<script>window.__INITIAL_STATE__={"other":undefined,"feed":{"feeds":[{"id":"1","noteCard":{"displayTitle":"value:undefined"}}]}};</script>"#
        XCTAssertEqual(try FeedParser.parse(html).first?.title, "value:undefined")
    }
}
