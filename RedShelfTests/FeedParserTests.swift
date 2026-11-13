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

    func testEmptySetInHydrationDoesNotChangeStringsOrExecuteCode() throws {
        let html = #"<script>window.__INITIAL_STATE__={"other":new Set([]),"feed":{"feeds":[{"id":"1","noteCard":{"displayTitle":"new Set([])"}}]}};</script>"#
        XCTAssertEqual(try FeedParser.parse(html).first?.title, "new Set([])")
        let executable = #"<script>window.__INITIAL_STATE__={"other":alert(1),"feed":{"feeds":[]}};</script>"#
        XCTAssertThrowsError(try FeedParser.parse(executable))
    }

    func testUnavailableNoteInValidHydrationReportsMissingContent() throws {
        let html = #"<script>window.__INITIAL_STATE__={"other":new Set([]),"note":{"noteDetailMap":{"undefined":{"note":{}}}}};</script>"#
        XCTAssertThrowsError(try FeedParser.parseDetail(html, id: "requested")) { error in
            guard case FeedError.noteUnavailable = error else { return XCTFail("Expected unavailable note") }
        }
        XCTAssertThrowsError(try FeedParser.parseAPIDetail(["items": []])) { error in
            guard case FeedError.noteUnavailable = error else { return XCTFail("Expected unavailable note") }
        }
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

    func testFeedUsesCardIdentifierWhenOuterIdentifierIsEmpty() throws {
        let data: [String: Any] = ["items": [["id": "", "note_card": ["note_id": "card-id", "title": "标题"]]]]
        XCTAssertEqual(try FeedParser.parseHomeFeed(data).first?.id, "card-id")
    }

    func testProfileRejectsGuestAndParsesPersonalNotes() throws {
        XCTAssertThrowsError(try FeedParser.parseUserProfile(["guest": true, "user_id": "guest"]))
        let profile = try FeedParser.parseUserProfile(["guest": false, "user_id": "u1", "nickname": "作者", "red_id": "red"])
        XCTAssertEqual(profile.name, "作者")
        let page = try FeedParser.parseUserNotes(["notes": [["note_id": "n1", "display_title": "标题", "xsec_token": "token"]], "cursor": "next", "has_more": true])
        XCTAssertEqual(page.notes.first?.id, "n1")
        XCTAssertEqual(page.notes.first?.accessToken, "token")
        XCTAssertEqual(page.cursor, "next")
        XCTAssertTrue(page.hasMore)
    }

    func testProfileDetailsUseReturnedCountsAndRejectWrongIdentity() throws {
        let base = UserProfile(id: "u1", name: "原名", redID: "red")
        let result: [String: Any] = ["basic_info": ["user_id": "u1", "nickname": "作者", "desc": "简介", "imageb": "https://example.com/avatar.jpg"],
                                     "interactions": [["type": "follows", "count": "34"], ["type": "fans", "count": 227], ["type": "interaction", "count": "1.2万"]]]
        let profile = try FeedParser.parseProfileDetails(result, base: base)
        XCTAssertEqual(profile.name, "作者")
        XCTAssertEqual(profile.biography, "简介")
        XCTAssertEqual(profile.following, "34")
        XCTAssertEqual(profile.followers, "227")
        XCTAssertEqual(profile.likes, "1.2万")
        XCTAssertEqual(profile.avatar?.host, "example.com")
        XCTAssertThrowsError(try FeedParser.parseProfileDetails(["basic_info": ["user_id": "other"]], base: base))
        XCTAssertNil(try FeedParser.parseProfileDetails(["basic_info": [:]], base: base).followers)
    }

    func testSearchUsersKeepsTokenAndUsesNonemptyIdentifier() throws {
        let result = try FeedParser.parseUserSearch(["users": [["id": "", "user_id": "u1", "nickname": "作者", "xsec_token": "token"]], "has_more": true])
        XCTAssertEqual(result.users.first?.id, "u1")
        XCTAssertEqual(result.users.first?.token, "token")
        XCTAssertTrue(result.hasMore)
    }

    func testLiveRoomsAndPublicHLS() throws {
        let list: [String: Any] = ["feeds": [["live": ["t_room_info": ["room_id_str": "123", "name": "直播标题"], "t_live_host_info": ["nickname": "主播"]]]]]
        let room = try XCTUnwrap(FeedParser.parseLiveList(list).first)
        XCTAssertEqual(room.id, "123")
        XCTAssertEqual(room.host, "主播")
        let html = #"<script>window.__INITIAL_STATE__={"liveStream":{"pageStatus":"success","liveStatus":"success","roomData":{"roomInfo":{"roomId":"123","status":2,"monetizeType":0,"joinLimitTypes":[0],"pullConfig":{"h264":[{"master_url":"https://v.xhscdn.com/live/123.m3u8"}]}}}}};</script>"#
        XCTAssertEqual(try FeedParser.parseLiveStream(html, roomID: "123").host, "v.xhscdn.com")
        XCTAssertThrowsError(try FeedParser.parseLiveStream(html, roomID: "456"))
        XCTAssertThrowsError(try FeedParser.parseLiveStream(html.replacingOccurrences(of: "\"monetizeType\":0", with: "\"monetizeType\":1"), roomID: "123"))
        XCTAssertThrowsError(try FeedParser.parseLiveStream(html.replacingOccurrences(of: "\"joinLimitTypes\":[0]", with: "\"joinLimitTypes\":[4]"), roomID: "123"))
        XCTAssertThrowsError(try FeedParser.parseLiveStream(html.replacingOccurrences(of: "\"joinLimitTypes\":[0]", with: "\"joinLimitTypes\":[false]"), roomID: "123"))
        XCTAssertThrowsError(try FeedParser.parseLiveStream(html.replacingOccurrences(of: "\"monetizeType\":0", with: "\"monetizeType\":false"), roomID: "123"))
        XCTAssertThrowsError(try FeedParser.parseLiveStream(html.replacingOccurrences(of: "v.xhscdn.com", with: "evil.example"), roomID: "123"))
        XCTAssertThrowsError(try FeedParser.parseLiveStream(html.replacingOccurrences(of: "v.xhscdn.com", with: "v.xhscdn.com:8080"), roomID: "123"))
    }

    func testVideoSkipsMissingAndInvalidStreamURLs() throws {
        let streams: [String: Any] = [
            "h264": [["master_url": ""], ["master_url": "not-a-url"]],
            "h265": [["master_url": "https://example.com/video.mp4"]]
        ]
        let card: [String: Any] = ["video": ["media": ["stream": streams]]]
        let data: [String: Any] = ["items": [["note_card": card]]]
        XCTAssertEqual(try FeedParser.parseAPIDetail(data).video?.absoluteString, "https://example.com/video.mp4")
    }

    func testDetailPrefersDefaultImageFromInfoList() throws {
        let images: [[String: Any]] = [["info_list": [
            ["image_scene": "WB_PRV", "url": "https://example.com/preview.jpg"],
            ["image_scene": "WB_DFT", "url": "https://example.com/full.jpg"]
        ]]]
        let data: [String: Any] = ["items": [["note_card": ["image_list": images]]]]
        XCTAssertEqual(try FeedParser.parseAPIDetail(data).images.first?.absoluteString, "https://example.com/full.jpg")
    }

    func testNewVideoCodecNamesAndBackupURLsArePlayable() throws {
        let streams: [String: Any] = ["EF4": [["master_url": "", "backup_urls": ["https://example.com/stream.mp4"]]]]
        let card: [String: Any] = ["video": ["media": ["stream": streams]]]
        let data: [String: Any] = ["items": [["note_card": card]]]
        XCTAssertEqual(try FeedParser.parseAPIDetail(data).video?.absoluteString, "https://example.com/stream.mp4")
    }

    func testFeedCoverCanUseInfoList() throws {
        let data: [String: Any] = ["items": [["id": "n1", "note_card": ["cover": ["info_list": [["url": "https://example.com/cover.jpg"]]]]]]]
        XCTAssertEqual(try FeedParser.parseHomeFeed(data).first?.cover?.absoluteString, "https://example.com/cover.jpg")
    }

    func testFeedIgnoresEmptyOuterTokenAndEmptyTitle() throws {
        let data: [String: Any] = ["items": [["id": "n1", "xsec_token": "", "note_card": ["title": "", "display_title": "标题", "xsec_token": "inner-token"]]]]
        let note = try XCTUnwrap(FeedParser.parseHomeFeed(data).first)
        XCTAssertEqual(note.title, "标题")
        XCTAssertEqual(note.accessToken, "inner-token")
    }

    func testFeedDropsDuplicateIdentifiersWithinPage() throws {
        let item: [String: Any] = ["id": "n1", "note_card": ["title": "标题"]]
        let notes = try FeedParser.parseHomeFeed(["items": [item, item]])
        XCTAssertEqual(notes.map(\.id), ["n1"])
    }

    func testCommentPaginationDeduplicatesAndStopsOnNoProgress() throws {
        let raw: [String: Any] = ["comments": [["id": "a", "content": "评论", "sub_comment_count": "2"], ["id": "a", "content": "重复"], ["id": "b"]], "cursor": "next", "has_more": true]
        let page = try FeedParser.parseComments(raw)
        XCTAssertEqual(page.comments.first?.replyCount, "2")
        let first = page.merging(with: [], previousCursor: "")
        XCTAssertEqual(first.comments.map(\.id), ["a", "b"])
        XCTAssertTrue(first.hasMore)
        let duplicate = page.merging(with: first.comments, previousCursor: "next")
        XCTAssertEqual(duplicate.comments.count, 2)
        XCTAssertFalse(duplicate.hasMore)
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
