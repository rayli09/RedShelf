import XCTest

final class RedShelfUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments.append("--ui-testing")
        app.launch()
    }

    func testRecommendationGridOpensAndReturnsFromDetail() {
        let first = app.buttons["note.fixture-0"]
        XCTAssertTrue(first.waitForExistence(timeout: 15), "Recommendation grid did not appear")
        XCUIRemote.shared.press(.down)
        let cards = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "note.fixture-"))
        XCTAssertTrue(cards.allElementsBoundByIndex.contains { $0.hasFocus }, "A recommendation should be reachable with the remote")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["用于界面验证的测试内容。"].waitForExistence(timeout: 10))
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(cards.firstMatch.waitForExistence(timeout: 10), "Returning should show the recommendation grid")
    }

    func testDetailImagesAndCommentsAreReachable() {
        app.terminate()
        app.launchArguments = ["--ui-testing", "--ui-testing-detail-images"]
        app.launch()
        let first = app.buttons["note.fixture-0"]
        XCTAssertTrue(first.waitForExistence(timeout: 15))
        XCUIRemote.shared.press(.down)
        XCUIRemote.shared.press(.select)
        let image = app.descendants(matching: .any).matching(identifier: "detail.mainImage").firstMatch
        XCTAssertTrue(image.waitForExistence(timeout: 10))
        let second = app.buttons["detail.image.1"]
        XCTAssertTrue(second.waitForExistence(timeout: 10))
        for _ in 0..<3 where !second.hasFocus { XCUIRemote.shared.press(.right) }
        XCTAssertTrue(second.hasFocus)
        XCUIRemote.shared.press(.select)
        XCTAssertEqual(image.label, "图片 2/3")
        let showText = app.buttons["detail.showText"]
        XCTAssertTrue(showText.waitForExistence(timeout: 10))
        for _ in 0..<3 where !showText.hasFocus { XCUIRemote.shared.press(.down) }
        XCTAssertTrue(showText.hasFocus)
        XCUIRemote.shared.press(.select)
        let comment = app.descendants(matching: .any).matching(identifier: "comment.fixture-comment").firstMatch
        XCTAssertTrue(comment.waitForExistence(timeout: 10))
        for _ in 0..<6 where !comment.hasFocus { XCUIRemote.shared.press(.down) }
        XCTAssertTrue(comment.hasFocus, "Comments should be reachable using the remote")
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

    func testLocalSignOutReturnsToReusableLogin() {
        let profileTab = app.buttons["我的"]
        XCTAssertTrue(profileTab.waitForExistence(timeout: 15))
        XCUIRemote.shared.press(.up)
        for _ in 0..<6 where !profileTab.hasFocus { XCUIRemote.shared.press(.right) }
        XCTAssertTrue(profileTab.hasFocus)
        XCUIRemote.shared.press(.select)
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

    func testProfileChangesPersonalCollection() {
        let profileTab = app.buttons["我的"]
        XCTAssertTrue(profileTab.waitForExistence(timeout: 15))
        XCUIRemote.shared.press(.up)
        for _ in 0..<6 where !profileTab.hasFocus { XCUIRemote.shared.press(.right) }
        XCTAssertTrue(profileTab.hasFocus)
        XCUIRemote.shared.press(.select)
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
        let profileTab = app.buttons["我的"]
        XCTAssertTrue(profileTab.waitForExistence(timeout: 15))
        XCUIRemote.shared.press(.up)
        for _ in 0..<6 where !profileTab.hasFocus { XCUIRemote.shared.press(.right) }
        XCTAssertTrue(profileTab.hasFocus)
        XCUIRemote.shared.press(.select)
        let accounts = app.buttons["profile.accounts"]
        XCTAssertTrue(accounts.waitForExistence(timeout: 10))
        let actions = [app.buttons["我的笔记"], app.buttons["我的点赞"], app.buttons["我的收藏"], accounts, app.buttons["profile.signout"]]
        if !actions.contains(where: { $0.hasFocus }) { XCUIRemote.shared.press(.down) }
        for _ in 0..<5 where !accounts.hasFocus { XCUIRemote.shared.press(.right) }
        for _ in 0..<5 where !accounts.hasFocus { XCUIRemote.shared.press(.left) }
        XCTAssertTrue(accounts.hasFocus)
        XCUIRemote.shared.press(.select)
        let second = app.buttons["account.fixture-b"]
        XCTAssertTrue(second.waitForExistence(timeout: 10))
        for _ in 0..<4 where !second.hasFocus { XCUIRemote.shared.press(.down) }
        XCTAssertTrue(second.hasFocus)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["已切换账号"].waitForExistence(timeout: 10))
    }

    func testAddAccountCanReturnToSavedAccount() {
        let profileTab = app.buttons["我的"]
        XCTAssertTrue(profileTab.waitForExistence(timeout: 15))
        XCUIRemote.shared.press(.up)
        for _ in 0..<6 where !profileTab.hasFocus { XCUIRemote.shared.press(.right) }
        XCTAssertTrue(profileTab.hasFocus)
        XCUIRemote.shared.press(.select)
        let accounts = app.buttons["profile.accounts"]
        XCTAssertTrue(accounts.waitForExistence(timeout: 10))
        let actions = [app.buttons["我的笔记"], app.buttons["我的点赞"], app.buttons["我的收藏"], accounts, app.buttons["profile.signout"]]
        if !actions.contains(where: { $0.hasFocus }) { XCUIRemote.shared.press(.down) }
        for _ in 0..<5 where !accounts.hasFocus { XCUIRemote.shared.press(.right) }
        for _ in 0..<5 where !accounts.hasFocus { XCUIRemote.shared.press(.left) }
        XCTAssertTrue(accounts.hasFocus)
        XCUIRemote.shared.press(.select)
        let add = app.buttons["account.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        for _ in 0..<5 where !add.hasFocus { XCUIRemote.shared.press(.down) }
        XCTAssertTrue(add.hasFocus)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.images["login.qr"].waitForExistence(timeout: 10))
        let saved = app.buttons["login.accounts"]
        XCTAssertTrue(saved.waitForExistence(timeout: 10))
        for _ in 0..<5 where !saved.hasFocus { XCUIRemote.shared.press(.down) }
        XCTAssertTrue(saved.hasFocus)
        XCUIRemote.shared.press(.select)
        let first = app.buttons["account.fixture-a"]
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        for _ in 0..<5 where !first.hasFocus { XCUIRemote.shared.press(.up) }
        XCTAssertTrue(first.hasFocus)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["已切换账号"].waitForExistence(timeout: 10))
    }

    func testPlaybackFailureShowsRetry() {
        app.terminate()
        app.launchArguments = ["--ui-testing", "--ui-testing-playback-error"]
        app.launch()
        let videoTab = app.buttons["视频"]
        XCTAssertTrue(videoTab.waitForExistence(timeout: 15))
        XCUIRemote.shared.press(.up)
        for _ in 0..<6 where !videoTab.hasFocus { XCUIRemote.shared.press(.right) }
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
        if !row.hasFocus { XCUIRemote.shared.press(.down) }
        XCTAssertTrue(row.hasFocus)
        XCUIRemote.shared.press(.select)
        app.terminate()
        app.launchArguments = ["--ui-testing", "--ui-testing-playback-success"]
        app.launch()
        let videoTab = app.buttons["视频"]
        XCTAssertTrue(videoTab.waitForExistence(timeout: 15))
        XCUIRemote.shared.press(.up)
        for _ in 0..<6 where !videoTab.hasFocus { XCUIRemote.shared.press(.right) }
        XCTAssertTrue(videoTab.hasFocus)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["video.fixture.autoplayOff"].waitForExistence(timeout: 10), "Autoplay setting was not retained")
        XCTAssertFalse(app.staticTexts["video.fixture.playing"].exists, "Video started before manual playback")
        XCUIRemote.shared.press(.playPause)
        XCTAssertTrue(app.staticTexts["video.fixture.playing"].waitForExistence(timeout: 10))
    }

    func testLiveRoomOpensAndPlaysFixture() {
        let tab = app.buttons["直播"]
        XCTAssertTrue(tab.waitForExistence(timeout: 15))
        XCUIRemote.shared.press(.up)
        for _ in 0..<6 where !tab.hasFocus { XCUIRemote.shared.press(.right) }
        XCTAssertTrue(tab.hasFocus)
        XCUIRemote.shared.press(.select)
        let room = app.buttons["live.123"]
        XCTAssertTrue(room.waitForExistence(timeout: 10))
        if !room.hasFocus { XCUIRemote.shared.press(.down) }
        if !room.hasFocus { XCUIRemote.shared.press(.down) }
        XCTAssertTrue(room.hasFocus)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["live.fixture.playing"].waitForExistence(timeout: 15))
    }
}
