import XCTest

final class RedShelfUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments.append("--ui-testing")
        app.launch()
    }

    private func focusRecommendation() {
        let cards = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "note.fixture-"))
        for _ in 0..<3 where !cards.allElementsBoundByIndex.contains(where: { $0.hasFocus }) {
            XCUIRemote.shared.press(.down)
        }
    }

    private func openProfileFromSettings() {
        let settings = app.buttons["设置"]
        XCTAssertTrue(settings.waitForExistence(timeout: 15))
        XCUIRemote.shared.press(.up)
        for _ in 0..<6 where !settings.hasFocus { XCUIRemote.shared.press(.right) }
        XCTAssertTrue(settings.hasFocus)
        XCUIRemote.shared.press(.select)
        let account = app.buttons["settings.account"]
        XCTAssertTrue(account.waitForExistence(timeout: 10))
        let accountRow = app.cells["我的账号"]
        if !accountRow.hasFocus { XCUIRemote.shared.press(.down) }
        for _ in 0..<4 where !accountRow.hasFocus { XCUIRemote.shared.press(.up) }
        XCTAssertTrue(accountRow.hasFocus)
        XCUIRemote.shared.press(.select)
    }

    private func openAccountSwitcher() {
        let account = app.buttons["账号"]
        XCTAssertTrue(account.waitForExistence(timeout: 15))
        XCUIRemote.shared.press(.up)
        for _ in 0..<8 where !account.hasFocus { XCUIRemote.shared.press(.right) }
        XCTAssertTrue(account.hasFocus)
        XCUIRemote.shared.press(.select)
    }

    func testRecommendationGridOpensAndReturnsFromDetail() {
        let first = app.buttons["note.fixture-0"]
        XCTAssertTrue(first.waitForExistence(timeout: 15), "Recommendation grid did not appear")
        focusRecommendation()
        let cards = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "note.fixture-"))
        XCTAssertTrue(cards.allElementsBoundByIndex.contains { $0.hasFocus }, "A recommendation should be reachable with the remote")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["用于界面验证的测试内容。"].waitForExistence(timeout: 10))
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(cards.firstMatch.waitForExistence(timeout: 10), "Returning should show the recommendation grid")
    }

    func testHomeRefreshIsReachableWithRemote() {
        let refresh = app.buttons["feed.refresh"]
        XCTAssertTrue(refresh.waitForExistence(timeout: 15))
        XCUIRemote.shared.press(.down)
        for _ in 0..<3 where !refresh.hasFocus { XCUIRemote.shared.press(.up) }
        XCTAssertTrue(refresh.hasFocus, "Refresh should be reachable with the remote")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.buttons["note.fixture-0"].waitForExistence(timeout: 10))
    }

    func testFocusedCoverDoesNotOverlapCaption() throws {
        XCTAssertTrue(app.buttons["note.fixture-0"].waitForExistence(timeout: 15))
        focusRecommendation()
        let cards = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "note.fixture-"))
        let focused = try XCTUnwrap(cards.allElementsBoundByIndex.first { $0.hasFocus })
        let index = try XCTUnwrap(Int(focused.identifier.replacingOccurrences(of: "note.fixture-", with: "")))
        let title = app.staticTexts["测试笔记 \(index + 1)"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        XCTAssertLessThanOrEqual(focused.frame.maxY, title.frame.minY, "The focused cover must not cover its title")
    }

    func testDetailBackButtonReturnsToFeed() {
        XCTAssertTrue(app.buttons["note.fixture-0"].waitForExistence(timeout: 15))
        focusRecommendation()
        XCUIRemote.shared.press(.select)
        let back = app.buttons["detail.back"]
        XCTAssertTrue(back.waitForExistence(timeout: 10))
        for _ in 0..<4 where !back.hasFocus { XCUIRemote.shared.press(.right) }
        for _ in 0..<4 where !back.hasFocus { XCUIRemote.shared.press(.up) }
        XCTAssertTrue(back.hasFocus, "Back should be reachable with the remote")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.buttons["note.fixture-0"].waitForExistence(timeout: 10))
    }

    func testLongDetailStartsExpanded() {
        app.terminate()
        app.launchArguments = ["--ui-testing", "--ui-testing-long-description"]
        app.launch()
        XCTAssertTrue(app.buttons["note.fixture-0"].waitForExistence(timeout: 15))
        focusRecommendation()
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.buttons["收起"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["展开全文"].exists)
    }

    func testRecommendationRowsStayAlignedWithDifferentTitleHeights() {
        app.terminate()
        app.launchArguments = ["--ui-testing", "--ui-testing-masonry"]
        app.launch()
        let first = app.buttons["note.fixture-0"]
        let secondRowLong = app.buttons["note.fixture-4"]
        let secondRowShort = app.buttons["note.fixture-5"]
        XCTAssertTrue(first.waitForExistence(timeout: 15))
        focusRecommendation()
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(secondRowLong.waitForExistence(timeout: 10))
        XCTAssertTrue(secondRowShort.waitForExistence(timeout: 10))
        XCTAssertEqual(secondRowLong.frame.minY, secondRowShort.frame.minY, accuracy: 2, "Covers in each row should align")
        let cards = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "note.fixture-"))
        let before = cards.allElementsBoundByIndex.first { $0.hasFocus }?.identifier
        XCTAssertNotNil(before)
        XCUIRemote.shared.press(.right)
        let after = cards.allElementsBoundByIndex.first { $0.hasFocus }?.identifier
        XCTAssertNotNil(after)
        XCTAssertNotEqual(before, after, "Remote should move across columns")
    }

    func testDetailImagesAndCommentsAreReachable() {
        app.terminate()
        app.launchArguments = ["--ui-testing", "--ui-testing-detail-images"]
        app.launch()
        let first = app.buttons["note.fixture-0"]
        XCTAssertTrue(first.waitForExistence(timeout: 15))
        focusRecommendation()
        XCUIRemote.shared.press(.select)
        let image = app.descendants(matching: .any).matching(identifier: "detail.mainImage").firstMatch
        XCTAssertTrue(image.waitForExistence(timeout: 10))
        let second = app.buttons["detail.image.1"]
        XCTAssertTrue(second.waitForExistence(timeout: 10))
        for _ in 0..<3 where !second.hasFocus { XCUIRemote.shared.press(.right) }
        XCTAssertTrue(second.hasFocus)
        XCTAssertEqual(image.label, "图片 2/3")
        let showText = app.buttons["detail.showText"]
        XCTAssertTrue(showText.waitForExistence(timeout: 10))
        for _ in 0..<5 where !showText.hasFocus { XCUIRemote.shared.press(.right) }
        XCTAssertTrue(showText.hasFocus)
        XCUIRemote.shared.press(.select)
        let comment = app.buttons["comment.fixture-comment"]
        XCTAssertTrue(comment.waitForExistence(timeout: 10))
        for _ in 0..<6 where !comment.hasFocus { XCUIRemote.shared.press(.down) }
        XCTAssertTrue(comment.hasFocus, "Comments should be reachable using the remote")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["测试回复"].waitForExistence(timeout: 10))
        let thumbnails = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "detail.image."))
        XCUIRemote.shared.press(.left)
        XCTAssertTrue(thumbnails.allElementsBoundByIndex.contains { $0.hasFocus }, "Left should return directly from comments to the thumbnails")
    }

    func testPlayingNoteVideoCanReachComments() {
        app.terminate()
        app.launchArguments = ["--ui-testing", "--ui-testing-reset-settings", "--ui-testing-detail-video"]
        app.launch()
        XCTAssertTrue(app.buttons["note.fixture-0"].waitForExistence(timeout: 15))
        focusRecommendation()
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["detail.video.playing"].waitForExistence(timeout: 10))
        let comment = app.descendants(matching: .any).matching(identifier: "comment.fixture-comment").firstMatch
        XCTAssertTrue(comment.waitForExistence(timeout: 10))
        for _ in 0..<5 where !comment.hasFocus { XCUIRemote.shared.press(.right) }
        for _ in 0..<5 where !comment.hasFocus { XCUIRemote.shared.press(.down) }
        XCTAssertTrue(comment.hasFocus, "Comments must be reachable while a note video is playing")
        XCUIRemote.shared.press(.left)
        XCTAssertFalse(comment.hasFocus, "Remote should be able to leave comments for the player")
        XCTAssertTrue(app.otherElements["Media Controls"].waitForExistence(timeout: 10))
        XCUIRemote.shared.press(.playPause)
        for _ in 0..<5 where !comment.hasFocus { XCUIRemote.shared.press(.right) }
        for _ in 0..<5 where !comment.hasFocus { XCUIRemote.shared.press(.down) }
        XCTAssertTrue(comment.hasFocus, "Remote should return from the player to comments")
    }

    func testSearchTabShowsNativeSearchField() {
        let searchTab = app.buttons["搜索"]
        XCTAssertTrue(searchTab.waitForExistence(timeout: 15), "Search tab did not appear")
        XCUIRemote.shared.press(.up)
        for _ in 0..<6 where !searchTab.hasFocus { XCUIRemote.shared.press(.right) }
        XCTAssertTrue(searchTab.hasFocus, "The search tab should be reachable with the remote")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.textFields["search.field"].waitForExistence(timeout: 10), "Search field did not appear")
    }

    func testUserSearchOpensCreatorNotes() {
        app.terminate()
        app.launchArguments = ["--ui-testing", "--ui-testing-search-users"]
        app.launch()
        let searchTab = app.buttons["搜索"]
        XCTAssertTrue(searchTab.waitForExistence(timeout: 15))
        XCUIRemote.shared.press(.up)
        for _ in 0..<6 where !searchTab.hasFocus { XCUIRemote.shared.press(.right) }
        XCTAssertTrue(searchTab.hasFocus)
        XCUIRemote.shared.press(.select)
        let user = app.buttons["search.user.fixture-user"]
        XCTAssertTrue(user.waitForExistence(timeout: 10))
        for _ in 0..<5 where !user.hasFocus { XCUIRemote.shared.press(.down) }
        XCTAssertTrue(user.hasFocus)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["创作者测试笔记"].waitForExistence(timeout: 10))
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["用于界面验证的测试内容。"].waitForExistence(timeout: 10))
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(app.staticTexts["创作者测试笔记"].waitForExistence(timeout: 10))
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(user.waitForExistence(timeout: 10))
    }

    func testSignedOutHomeShowsQRAndRetryIsReachable() {
        app.terminate()
        app.launchArguments = ["--ui-testing-login"]
        app.launch()
        XCTAssertTrue(app.images["login.qr"].waitForExistence(timeout: 15), "Signed-out home must show the QR")
        let retry = app.buttons["login.retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 10))
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(retry.hasFocus, "The login retry action should be reachable directly from the tab bar")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.images["login.qr"].waitForExistence(timeout: 10))
    }

    func testExpiredSessionReturnsToLoginWithExplanation() {
        app.terminate()
        app.launchArguments = ["--ui-testing", "--ui-testing-expired-session"]
        app.launch()
        XCTAssertTrue(app.images["login.qr"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["登录已过期，请重新扫码登录。"].waitForExistence(timeout: 10))
    }

    func testLocalSignOutReturnsToReusableLogin() {
        openProfileFromSettings()
        let signOut = app.buttons["profile.signout"]
        XCTAssertTrue(signOut.waitForExistence(timeout: 10))
        let actions = [app.buttons["我的笔记"], app.buttons["我的点赞"], app.buttons["我的收藏"], app.buttons["profile.accounts"], signOut]
        if !actions.contains(where: { $0.hasFocus }) { XCUIRemote.shared.press(.down) }
        for _ in 0..<5 where !signOut.hasFocus { XCUIRemote.shared.press(.right) }
        if !signOut.hasFocus { XCUIRemote.shared.press(.up) }
        XCTAssertTrue(signOut.hasFocus)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.images["login.qr"].waitForExistence(timeout: 10))
    }

    func testVideoFeedMovesToNextRecommendation() {
        let videoTab = app.buttons["视频"]
        XCTAssertTrue(videoTab.waitForExistence(timeout: 15))
        XCUIRemote.shared.press(.up)
        for _ in 0..<6 where !videoTab.hasFocus { XCUIRemote.shared.press(.right) }
        for _ in 0..<6 where !videoTab.hasFocus { XCUIRemote.shared.press(.left) }
        XCTAssertTrue(videoTab.hasFocus)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["测试笔记 1"].waitForExistence(timeout: 10))
        let next = app.buttons["video.next"]
        XCTAssertTrue(next.waitForExistence(timeout: 10))
        if !next.hasFocus { XCUIRemote.shared.press(.down) }
        for _ in 0..<3 where !next.hasFocus { XCUIRemote.shared.press(.right) }
        XCTAssertTrue(next.hasFocus)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["测试笔记 2"].waitForExistence(timeout: 10))
    }

    func testPlayingVideoCanMoveToNextVideo() {
        app.terminate()
        app.launchArguments = ["--ui-testing", "--ui-testing-reset-settings", "--ui-testing-playback-success"]
        app.launch()
        let videoTab = app.buttons["视频"]
        XCTAssertTrue(videoTab.waitForExistence(timeout: 15))
        XCUIRemote.shared.press(.up)
        for _ in 0..<6 where !videoTab.hasFocus { XCUIRemote.shared.press(.right) }
        for _ in 0..<6 where !videoTab.hasFocus { XCUIRemote.shared.press(.left) }
        XCTAssertTrue(videoTab.hasFocus)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["video.fixture.playing"].waitForExistence(timeout: 10))
        let next = app.buttons["video.next"]
        XCTAssertTrue(next.waitForExistence(timeout: 10))
        for _ in 0..<3 where !next.hasFocus { XCUIRemote.shared.press(.down) }
        for _ in 0..<4 where !next.hasFocus { XCUIRemote.shared.press(.right) }
        XCTAssertTrue(next.hasFocus, "Next video must be reachable while playback is active")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["测试笔记 2"].waitForExistence(timeout: 10))
        let instance = app.staticTexts["video.fixture.instance"]
        XCTAssertTrue(instance.waitForExistence(timeout: 10))
        let instanceBeforeControls = instance.label
        let controls = app.buttons["video.controls"]
        XCTAssertTrue(controls.waitForExistence(timeout: 10))
        for _ in 0..<5 where !controls.hasFocus { XCUIRemote.shared.press(.right) }
        XCTAssertTrue(controls.hasFocus, "Native playback controls should be reachable")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.otherElements["Media Controls"].waitForExistence(timeout: 10))
        let overlay = app.staticTexts["video.controls.open"]
        XCTAssertTrue(overlay.waitForExistence(timeout: 10))
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(overlay.waitForNonExistence(timeout: 10), "Menu should return to the video feed")
        XCTAssertEqual(instance.label, instanceBeforeControls, "Closing controls should not restart the video")
        XCTAssertTrue(next.waitForExistence(timeout: 10))
        let recommendations = app.buttons["推荐"]
        XCUIRemote.shared.press(.up)
        for _ in 0..<6 where !recommendations.hasFocus { XCUIRemote.shared.press(.left) }
        XCTAssertTrue(recommendations.hasFocus, "Remote should leave the video tab")
    }

    func testProfileChangesPersonalCollection() {
        openProfileFromSettings()
        XCTAssertTrue(app.staticTexts["测试我的笔记"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["测试简介"].exists)
        XCTAssertTrue(app.staticTexts["227"].exists)
        let liked = app.buttons["我的点赞"]
        XCTAssertTrue(liked.waitForExistence(timeout: 10))
        let actions = [app.buttons["我的笔记"], liked, app.buttons["我的收藏"], app.buttons["profile.signout"]]
        if !actions.contains(where: { $0.hasFocus }) { XCUIRemote.shared.press(.down) }
        for _ in 0..<4 where !liked.hasFocus { XCUIRemote.shared.press(.left) }
        for _ in 0..<4 where !liked.hasFocus { XCUIRemote.shared.press(.right) }
        XCTAssertTrue(liked.hasFocus)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["测试我的点赞"].waitForExistence(timeout: 10))
    }

    func testSwitchSavedAccount() {
        openAccountSwitcher()
        let second = app.buttons["account.fixture-b"]
        XCTAssertTrue(second.waitForExistence(timeout: 10))
        for _ in 0..<4 where !second.hasFocus { XCUIRemote.shared.press(.down) }
        XCTAssertTrue(second.hasFocus)
        XCUIRemote.shared.press(.select)
        let active = expectation(for: NSPredicate(format: "value == %@", "当前账号"), evaluatedWith: second)
        wait(for: [active], timeout: 10)
        XCTAssertTrue(app.buttons["account.add"].exists, "Account page should remain open after switching")
    }

    func testAddAccountCanReturnToSavedAccount() {
        openAccountSwitcher()
        let add = app.buttons["account.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        for _ in 0..<5 where !add.hasFocus { XCUIRemote.shared.press(.down) }
        XCTAssertTrue(add.hasFocus)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.images["login.qr"].waitForExistence(timeout: 10))
        openAccountSwitcher()
        let first = app.buttons["account.fixture-a"]
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        for _ in 0..<5 where !first.hasFocus { XCUIRemote.shared.press(.up) }
        XCTAssertTrue(first.hasFocus)
        XCUIRemote.shared.press(.select)
        let active = expectation(for: NSPredicate(format: "value == %@", "当前账号"), evaluatedWith: first)
        wait(for: [active], timeout: 10)
    }

    func testPlaybackFailureShowsRetry() {
        app.terminate()
        app.launchArguments = ["--ui-testing", "--ui-testing-playback-error"]
        app.launch()
        let videoTab = app.buttons["视频"]
        XCTAssertTrue(videoTab.waitForExistence(timeout: 15))
        XCUIRemote.shared.press(.up)
        for _ in 0..<6 where !videoTab.hasFocus { XCUIRemote.shared.press(.right) }
        for _ in 0..<6 where !videoTab.hasFocus { XCUIRemote.shared.press(.left) }
        XCTAssertTrue(videoTab.hasFocus)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["视频播放失败，请重试或查看下一个"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["重试播放"].waitForExistence(timeout: 5))
    }

    func testVideoActuallyAdvances() {
        app.terminate()
        app.launchArguments = ["--ui-testing", "--ui-testing-playback-success"]
        app.launch()
        let videoTab = app.buttons["视频"]
        XCTAssertTrue(videoTab.waitForExistence(timeout: 15))
        XCUIRemote.shared.press(.up)
        for _ in 0..<6 where !videoTab.hasFocus { XCUIRemote.shared.press(.right) }
        for _ in 0..<6 where !videoTab.hasFocus { XCUIRemote.shared.press(.left) }
        XCTAssertTrue(videoTab.hasFocus)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["video.fixture.playing"].waitForExistence(timeout: 15), "Player did not advance")
    }

    func testAutoplaySettingPersistsAndAllowsManualPlayback() {
        app.terminate()
        app.launchArguments = ["--ui-testing", "--ui-testing-reset-settings", "--ui-testing-playback-success"]
        app.launch()
        defer {
            app.terminate()
            app.launchArguments = ["--ui-testing", "--ui-testing-reset-settings"]
            app.launch()
        }
        let settingsTab = app.buttons["设置"]
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 15))
        XCUIRemote.shared.press(.up)
        for _ in 0..<6 where !settingsTab.hasFocus { XCUIRemote.shared.press(.right) }
        XCTAssertTrue(settingsTab.hasFocus)
        XCUIRemote.shared.press(.select)
        let toggle = app.descendants(matching: .any).matching(identifier: "settings.autoplay").firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        let row = app.cells["自动播放笔记视频"]
        for _ in 0..<4 where !row.hasFocus { XCUIRemote.shared.press(.down) }
        XCTAssertTrue(row.hasFocus)
        XCUIRemote.shared.press(.select)
        app.terminate()
        app.launchArguments = ["--ui-testing", "--ui-testing-playback-success"]
        app.launch()
        let videoTab = app.buttons["视频"]
        XCTAssertTrue(videoTab.waitForExistence(timeout: 15))
        XCUIRemote.shared.press(.up)
        for _ in 0..<6 where !videoTab.hasFocus { XCUIRemote.shared.press(.right) }
        for _ in 0..<6 where !videoTab.hasFocus { XCUIRemote.shared.press(.left) }
        XCTAssertTrue(videoTab.hasFocus)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["video.fixture.autoplayOff"].waitForExistence(timeout: 10), "Autoplay setting was not retained")
        XCTAssertFalse(app.staticTexts["video.fixture.playing"].exists, "Video started before manual playback")
        XCUIRemote.shared.press(.playPause)
        XCTAssertTrue(app.staticTexts["video.fixture.playing"].waitForExistence(timeout: 10))
    }

    func testTopNavigationOmitsLiveAndProfile() {
        XCTAssertTrue(app.buttons["推荐"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["直播"].exists)
        XCTAssertFalse(app.buttons["我的"].exists)
        XCTAssertTrue(app.buttons["设置"].exists)
    }
}
