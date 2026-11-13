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

    func testAuthenticatedFeedHandlesCurrentWebResponseShape() throws {
        let data: [String: Any] = ["items": [["id": "note-1", "xsec_token": "token-1",
                                              "note_card": ["title": "真实标题", "type": "video",
                                                            "user": ["nickname": "作者"],
                                                            "cover": ["url_default": "https://example.com/cover.jpg"],
                                                            "interact_info": ["liked_count": 42]]]]]
        let note = try XCTUnwrap(FeedParser.parseHomeFeed(data).first)
        XCTAssertEqual(note.title, "真实标题")
        XCTAssertEqual(note.accessToken, "token-1")
        XCTAssertEqual(note.likes, "42")
        XCTAssertTrue(note.isVideo)
    }

    func testAuthenticatedNoteDetailReadsImagesAndVideo() throws {
        let result: [String: Any] = ["items": [["note_card": ["title": "测试",
            "desc": "内容", "user": ["nickname": "作者"], "interact_info": ["liked": true, "collected": false, "comment_count": "8"],
            "image_list": [["url_default": "https://example.com/image.jpg"]],
            "video": ["media": ["stream": ["h264": [["master_url": "https://example.com/video.mp4"]]]]]]]]]
        let detail = try FeedParser.parseAPIDetail(result)
        XCTAssertEqual(detail.title, "测试")
        XCTAssertEqual(detail.author, "作者")
        XCTAssertEqual(detail.images.count, 1)
        XCTAssertEqual(detail.video?.absoluteString, "https://example.com/video.mp4")
        XCTAssertEqual(detail.liked, true)
        XCTAssertEqual(detail.collected, false)
        XCTAssertEqual(detail.commentCount, "8")
    }

    func testCommentPageAndPaginationMetadata() throws {
        let response: [String: Any] = ["comments": [["id": "comment-1", "content": "很好看",
                                                     "user_info": ["nickname": "读者"], "like_count": 9]],
                                      "cursor": "next", "has_more": true]
        let page = try FeedParser.parseComments(response)
        XCTAssertEqual(page.comments.first?.author, "读者")
        XCTAssertEqual(page.comments.first?.likes, "9")
        XCTAssertEqual(page.cursor, "next")
        XCTAssertTrue(page.hasMore)
        XCTAssertThrowsError(try FeedParser.parseComments([:]))
    }
}
