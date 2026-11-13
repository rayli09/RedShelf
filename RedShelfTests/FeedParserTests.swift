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

    func testNoteDetailContainsImagesAndPlayableStream() throws {
        let html = #"<script>window.__INITIAL_STATE__={"note":{"noteDetailMap":{"1":{"note":{"title":"标题","desc":"内容","user":{"nickname":"作者"},"imageList":[{"urlDefault":"https://example.com/image.jpg"}],"video":{"media":{"stream":{"h264":[{"masterUrl":"https://example.com/video.mp4"}]}}}}}}}};</script>"#
        let detail = try FeedParser.parseDetail(html, id: "1")
        XCTAssertEqual(detail.title, "标题")
        XCTAssertEqual(detail.images.count, 1)
        XCTAssertEqual(detail.video?.absoluteString, "https://example.com/video.mp4")
    }

    func testQRLoginStatesRequireConfirmation() throws {
        XCTAssertEqual(try QRLoginStatus(code: 0), .waiting)
        XCTAssertEqual(try QRLoginStatus(code: 1), .scanned)
        XCTAssertEqual(try QRLoginStatus(code: 2), .confirmed)
        XCTAssertEqual(try QRLoginStatus(code: 3), .expired)
        XCTAssertThrowsError(try QRLoginStatus(code: 99))
    }
}
