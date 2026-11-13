import SwiftUI
import AVKit
import CoreImage.CIFilterBuiltins

private enum UIEnvironment {
    static var useFixtures: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--ui-testing")
        #else
        false
        #endif
    }
    static var useLoginFixture: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--ui-testing-login")
        #else
        false
        #endif
    }
}

private enum Page: String, CaseIterable {
    case recommendations = "推荐", video = "视频", live = "直播", search = "搜索", profile = "我的", settings = "设置"
    var symbol: String {
        switch self {
        case .recommendations: return "rectangle.badge.plus"
        case .video: return "play.rectangle.fill"
        case .live: return "dot.radiowaves.left.and.right"
        case .search: return "magnifyingglass"
        case .profile: return "person.crop.circle"
        case .settings: return "gearshape"
        }
    }
}

@MainActor
private final class FeedModel: ObservableObject {
    struct Account: Identifiable { let id: String; let name: String; let isActive: Bool }
    enum SessionState { case checking, signedOut, signedIn }
    @Published private(set) var sessionState: SessionState = .checking
    @Published var notes: [FeedNote] = []
    @Published var error: String?
    @Published var loading = false
    @Published private(set) var loadingMore = false
    @Published private(set) var paginationError: String?
    @Published var accountError: String?
    @Published private(set) var accounts: [Account] = []
    private var cursor = ""
    var hasMore: Bool { !cursor.isEmpty }
    private var generation = 0
    private let service = FeedService()

    func restoreSession() async {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing-reset-settings") {
            UserDefaults.standard.set(true, forKey: "autoplayNoteVideos")
        }
        #endif
        if UIEnvironment.useLoginFixture {
            sessionState = .signedOut
            return
        }
        if UIEnvironment.useFixtures {
            sessionState = .signedIn
            accounts = [Account(id: "fixture-a", name: "测试账号一", isActive: true), Account(id: "fixture-b", name: "测试账号二", isActive: false)]
            notes = (0..<12).map { index in
                let longTitle = ProcessInfo.processInfo.arguments.contains("--ui-testing-masonry") && index < 2
                let title = longTitle ? "测试笔记 \(index + 1)：这里是一段用于验证不同列排版的较长标题" : "测试笔记 \(index + 1)"
                return FeedNote(id: "fixture-\(index)", title: title, author: "测试作者", cover: nil,
                                avatar: nil, likes: "24", isVideo: index < 3, accessToken: "", source: "pc_feed")
            }
            return
        }
        guard let client = SignedClient.shared else {
            sessionState = .signedOut
            return
        }
        sessionState = await client.isLoggedIn ? .signedIn : .signedOut
        await reloadAccounts()
        if sessionState == .signedIn { await refresh() }
    }

    func didLogIn() async {
        await reloadAccounts()
        sessionState = .signedIn
        await refresh()
    }

    func reloadAccounts() async {
        guard !UIEnvironment.useFixtures, let client = SignedClient.shared else { return }
        accounts = await client.accounts.map { Account(id: $0.id, name: $0.name, isActive: $0.isActive) }
    }

    private func clearFeed() {
        generation += 1
        notes = []
        cursor = ""
        error = nil
        paginationError = nil
        loading = false
        loadingMore = false
    }

    func addAccount() async -> Bool {
        guard sessionState != .checking else { return false }
        let previous = sessionState
        sessionState = .checking
        accountError = nil
        do {
            if !UIEnvironment.useFixtures {
                guard let client = SignedClient.shared else { throw FeedError.unavailable }
                try await client.beginAddingAccount()
            } else {
                accounts = accounts.map { Account(id: $0.id, name: $0.name, isActive: false) }
            }
            clearFeed()
            await reloadAccounts()
            sessionState = .signedOut
            return true
        } catch {
            accountError = error.localizedDescription
            sessionState = previous
            return false
        }
    }

    func switchAccount(_ id: String) async -> Bool {
        guard sessionState != .checking else { return false }
        let previous = sessionState
        sessionState = .checking
        accountError = nil
        do {
            if UIEnvironment.useFixtures {
                guard accounts.contains(where: { $0.id == id }) else { throw FeedError.unavailable }
                accounts = accounts.map { Account(id: $0.id, name: $0.name, isActive: $0.id == id) }
            } else {
                guard let client = SignedClient.shared else { throw FeedError.unavailable }
                try await client.switchAccount(id: id)
            }
            clearFeed()
            await reloadAccounts()
            sessionState = .signedIn
            if UIEnvironment.useFixtures {
                notes = [FeedNote(id: "switched-fixture", title: "已切换账号", author: "测试用户", cover: nil, avatar: nil, likes: "", isVideo: false, accessToken: "", source: "pc_feed")]
            } else { await refresh() }
            return true
        } catch {
            accountError = error.localizedDescription
            sessionState = previous
            return false
        }
    }

    func refresh() async {
        guard !loading else { return }
        generation += 1
        let current = generation
        loadingMore = false
        paginationError = nil
        loading = true
        error = nil
        defer { if current == generation { loading = false } }
        do {
            if let client = SignedClient.shared, await client.isLoggedIn {
                let page = try await client.homeFeed()
                guard !page.notes.isEmpty else { throw FeedError.unavailable }
                guard current == generation else { return }
                notes = page.notes
                cursor = page.cursor
            } else {
                let result = try await service.fetch()
                guard current == generation else { return }
                notes = result
                cursor = ""
            }
        }
        catch { if current == generation { self.error = error.localizedDescription } }
    }

    func signOut() async {
        guard sessionState == .signedIn else { return }
        accountError = nil
        do {
            if !UIEnvironment.useFixtures {
                guard let client = SignedClient.shared else { throw FeedError.unavailable }
                try await client.signOut()
            } else {
                accounts = accounts.filter { !$0.isActive }.map { Account(id: $0.id, name: $0.name, isActive: false) }
            }
            clearFeed()
            await reloadAccounts()
            sessionState = .signedOut
        } catch { accountError = error.localizedDescription }
    }

    func loadMore() async {
        guard !loading, !loadingMore, !cursor.isEmpty, paginationError == nil,
              !UIEnvironment.useFixtures, let client = SignedClient.shared else { return }
        let current = generation
        let previousCursor = cursor
        loadingMore = true
        defer { if current == generation { loadingMore = false } }
        do {
            let page = try await client.homeFeed(cursor: previousCursor, noteIndex: notes.count)
            guard current == generation else { return }
            var seen = Set(notes.map(\.id))
            let fresh = page.notes.filter { seen.insert($0.id).inserted }
            notes.append(contentsOf: fresh)
            cursor = fresh.isEmpty || page.cursor == previousCursor ? "" : page.cursor
        } catch {
            guard current == generation else { return }
            paginationError = error.localizedDescription
        }
    }

    func retryLoadMore() async {
        paginationError = nil
        await loadMore()
    }
}

@MainActor
private final class LoginModel: ObservableObject {
    @Published private(set) var image: UIImage?
    @Published private(set) var message = "正在生成二维码…"
    @Published private(set) var failed = false
    private var task: Task<Void, Never>?
    private var generation = 0
    private var hasStarted = false

    func startIfNeeded(onSuccess: @escaping () -> Void) {
        guard !hasStarted else { return }
        hasStarted = true
        start(onSuccess: onSuccess)
    }

    func retry(onSuccess: @escaping () -> Void) {
        task?.cancel()
        start(onSuccess: onSuccess)
    }

    func reset() {
        task?.cancel()
        task = nil
        generation += 1
        hasStarted = false
        image = nil
        failed = false
        message = "正在生成二维码…"
    }

    private func start(onSuccess: @escaping () -> Void) {
        generation += 1
        let current = generation
        image = nil
        failed = false
        message = "正在生成二维码…"
        if UIEnvironment.useLoginFixture || UIEnvironment.useFixtures {
            image = UIImage(systemName: "qrcode")
            message = "测试二维码"
            return
        }
        task = Task { [weak self] in
            guard let self else { return }
            var stage = "生成二维码"
            do {
                guard let client = SignedClient.shared else { throw FeedError.invalidResponse }
                let challenge = try await client.beginLogin()
                try Task.checkCancellation()
                guard self.generation == current else { return }
                let filter = CIFilter.qrCodeGenerator()
                filter.message = Data(challenge.url.absoluteString.utf8)
                filter.correctionLevel = "M"
                guard let output = filter.outputImage, let cg = CIContext().createCGImage(output, from: output.extent) else { throw FeedError.invalidResponse }
                self.image = UIImage(cgImage: cg)
                self.message = "请使用小红书 App 扫码并确认"
                stage = "检查登录状态"
                for _ in 0..<90 {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                    let progress = try await client.checkLogin(challenge)
                    try Task.checkCancellation()
                    guard self.generation == current else { return }
                    switch progress {
                    case .waiting: break
                    case .scanned: self.message = "已扫码，请在手机上确认登录"
                    case .authenticated:
                        self.task = nil
                        onSuccess()
                        return
                    }
                }
                self.image = nil
                self.failed = true
                self.message = "等待超时，请重新生成二维码"
            } catch is CancellationError {
                return
            } catch {
                guard self.generation == current else { return }
                self.image = nil
                self.failed = true
                self.message = "\(stage)失败：\(error.localizedDescription)"
            }
            if self.generation == current { self.task = nil }
        }
    }
}

struct RootView: View {
    @State private var page: Page = .recommendations
    @State private var selectedNote: FeedNote?
    @State private var selectedLive: LiveRoom?
    @State private var showAccounts = false
    @StateObject private var model = FeedModel()
    @StateObject private var loginModel = LoginModel()

    var body: some View {
        ZStack {
            Color(red: 0.08, green: 0.08, blue: 0.08).ignoresSafeArea()
            TabView(selection: $page) {
                ForEach(Page.allCases, id: \.self) { item in
                    content(for: item)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .focusSection()
                        .tabItem { Label(item.rawValue, systemImage: item.symbol) }
                        .tag(item)
                }
            }
        }
        .preferredColorScheme(.dark)
        .task { await model.restoreSession() }
        .fullScreenCover(item: $selectedNote) { NoteDetailView(note: $0) }
        .fullScreenCover(item: $selectedLive) { LivePlayerView(room: $0) }
        .sheet(isPresented: $showAccounts) {
            AccountPicker(model: model, dismiss: { showAccounts = false }, select: { id in
                Task {
                    let wasSignedOut = model.sessionState == .signedOut
                    if wasSignedOut { loginModel.reset() }
                    if await model.switchAccount(id) {
                        loginModel.reset()
                        showAccounts = false
                        page = .recommendations
                    } else if wasSignedOut {
                        loginModel.retry(onSuccess: loginSucceeded)
                    }
                }
            }, add: {
                Task {
                    if await model.addAccount() {
                        loginModel.reset()
                        showAccounts = false
                        page = .recommendations
                    }
                }
            })
        }
    }

    private var login: some View {
        LoginView(model: loginModel, showAccounts: model.accounts.isEmpty ? nil : { showAccounts = true }, onSuccess: loginSucceeded)
    }

    private func loginSucceeded() {
        page = .recommendations
        Task { await model.didLogIn() }
    }

    @ViewBuilder
    private func content(for page: Page) -> some View {
        switch page {
        case .recommendations:
            switch model.sessionState {
            case .checking: ProgressView()
            case .signedOut: login
            case .signedIn: feed
            }
        case .video:
            switch model.sessionState {
            case .checking: ProgressView()
            case .signedOut: login
            case .signedIn:
                VideoFeedView(model: model, selectedNote: $selectedNote,
                              isActive: self.page == .video && selectedNote == nil)
            }
        case .live:
            switch model.sessionState {
            case .checking: ProgressView()
            case .signedOut: login
            case .signedIn: LiveFeedView(selectedLive: $selectedLive)
            }
        case .search:
            switch model.sessionState {
            case .checking: ProgressView()
            case .signedOut: login
            case .signedIn: SearchView(selectedNote: $selectedNote)
            }
        case .profile:
            switch model.sessionState {
            case .checking: ProgressView()
            case .signedOut: login
            case .signedIn:
                ProfileView(model: model, selectedNote: $selectedNote, showAccounts: { showAccounts = true }) {
                    Task {
                        await model.signOut()
                        if model.sessionState == .signedOut { loginModel.reset() }
                    }
                }
            }
        case .settings: SettingsView()
        }
    }

    private var feed: some View {
        Group {
            if model.notes.isEmpty {
                VStack(spacing: 24) {
                    if model.loading { ProgressView() }
                    else {
                        Image(systemName: "rectangle.stack.badge.questionmark").font(.system(size: 60)).foregroundStyle(.secondary)
                        Text(model.error ?? "暂无推荐内容").font(.title3)
                        Button("重试") { Task { await model.refresh() } }
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    NoteGrid(notes: model.notes, select: { selectedNote = $0 }, onLastAppear: { Task { await model.loadMore() } })
                        .padding(.horizontal, 48).padding(.top, 20).padding(.bottom, 90)
                    if model.loadingMore { ProgressView().padding() }
                    if let error = model.paginationError {
                        VStack {
                            Text(error).foregroundStyle(.secondary)
                            Button("重试加载更多") { Task { await model.retryLoadMore() } }
                        }.padding()
                    }
                }
            }
        }
    }

    private func unavailable(_ title: String, _ description: String) -> some View {
        VStack(spacing: 16) {
            Text(title).font(.title2.weight(.semibold))
            Text(description).font(.body).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ProfileView: View {
    @ObservedObject var model: FeedModel
    @Binding var selectedNote: FeedNote?
    let showAccounts: () -> Void
    let signOut: () -> Void
    @State private var profile: UserProfile?
    @State private var collection: UserNoteCollection = .posted
    @State private var notes: [FeedNote] = []
    @State private var cursor = ""
    @State private var hasMore = false
    @State private var loading = false
    @State private var error: String?
    @State private var requestGeneration = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                HStack(spacing: 24) {
                    AsyncImage(url: profile?.avatar) { image in image.resizable().scaledToFill() } placeholder: { Image(systemName: "person.crop.circle").resizable().foregroundStyle(.secondary) }
                        .frame(width: 120, height: 120).clipShape(Circle())
                    VStack(alignment: .leading) {
                        Text(profile?.name ?? "我的账号").font(.title2.weight(.semibold))
                        if let redID = profile?.redID, !redID.isEmpty { Text("小红书号：\(redID)").foregroundStyle(.secondary) }
                        if let bio = profile?.biography, !bio.isEmpty { Text(bio).font(.callout).lineLimit(2) }
                    }
                    Spacer()
                    if let profile {
                        HStack(spacing: 45) {
                            if let count = profile.following { metric(count, "关注") }
                            if let count = profile.followers { metric(count, "粉丝") }
                            if let count = profile.likes { metric(count, "获赞与收藏") }
                        }
                    }
                }
                if let error = model.accountError { Text(error).foregroundStyle(.secondary) }
                HStack {
                    ForEach(UserNoteCollection.allCases, id: \.self) { item in
                        Button(item.rawValue) { collection = item; Task { await load(reset: true) } }
                            .buttonStyle(.bordered)
                            .frame(maxWidth: .infinity)
                    }
                    Button("切换账号", action: showAccounts)
                        .accessibilityIdentifier("profile.accounts")
                        .frame(maxWidth: .infinity)
                    Button("退出此设备", action: signOut)
                        .accessibilityIdentifier("profile.signout")
                        .frame(maxWidth: .infinity)
                }.frame(maxWidth: .infinity, alignment: .leading).focusSection()
                if let error {
                    Text(error).foregroundStyle(.secondary)
                    Button("重试") { Task { await load(reset: notes.isEmpty) } }
                } else if notes.isEmpty && !loading {
                    Text("暂无内容").foregroundStyle(.secondary)
                }
                NoteGrid(notes: notes, select: { selectedNote = $0 })
                if loading { ProgressView() }
                if hasMore && !loading && error == nil { Button("加载更多") { Task { await load(reset: false) } } }
            }.padding(.horizontal, 48).padding(.bottom, 80)
        }
        .task {
            if UIEnvironment.useFixtures {
                profile = UserProfile(id: "fixture", name: "测试用户", redID: "test", biography: "测试简介", following: "34", followers: "227", likes: "1264")
                await load(reset: true)
                return
            }
            await load(reset: true)
        }
        .task(id: profile?.id) {
            guard !UIEnvironment.useFixtures, let base = profile, let client = SignedClient.shared else { return }
            do {
                let details = try await client.profileDetails(base)
                try Task.checkCancellation()
                guard profile?.id == base.id else { return }
                profile = details
            } catch { }
        }
    }

    private func metric(_ count: String, _ label: String) -> some View {
        VStack(spacing: 6) {
            Text(count).font(.system(size: 28, weight: .semibold))
            Text(label).font(.system(size: 18)).foregroundStyle(.secondary)
        }
    }

    @MainActor
    private func load(reset: Bool) async {
        if UIEnvironment.useFixtures {
            notes = [FeedNote(id: "profile-fixture", title: "测试\(collection.rawValue)", author: "测试用户", cover: nil,
                              avatar: nil, likes: "", isVideo: false, accessToken: "", source: "pc_user")]
            return
        }
        guard reset || !loading else { return }
        requestGeneration += 1
        let current = requestGeneration
        let target = collection
        if reset { notes = []; cursor = ""; hasMore = false }
        let requestedCursor = cursor
        loading = true
        error = nil
        defer { if current == requestGeneration { loading = false } }
        do {
            guard let client = SignedClient.shared else { throw FeedError.unavailable }
            let user: UserProfile
            if let profile { user = profile } else {
                user = try await client.profile()
                await model.reloadAccounts()
            }
            guard current == requestGeneration else { return }
            profile = user
            let result = try await client.userNotes(target, userID: user.id, cursor: requestedCursor)
            try Task.checkCancellation()
            guard current == requestGeneration else { return }
            var seen = Set(notes.map(\.id))
            let fresh = result.notes.filter { seen.insert($0.id).inserted }
            notes.append(contentsOf: fresh)
            hasMore = result.hasMore && !result.cursor.isEmpty && result.cursor != requestedCursor && !fresh.isEmpty
            cursor = result.cursor
        } catch is CancellationError { return }
        catch { if current == requestGeneration { self.error = "无法加载个人内容，请重试" } }
    }
}

@MainActor
private final class PlaybackModel: ObservableObject {
    @Published private(set) var player: AVPlayer?
    @Published private(set) var failed = false
    private var observation: NSKeyValueObservation?
    private var failureObserver: NSObjectProtocol?
    #if DEBUG
    @Published private(set) var hasAdvanced = false
    @Published private(set) var generation = 0
    private var timeObserver: Any?
    #endif

    func play(_ url: URL, automatically: Bool = true) {
        stop()
        failed = false
        #if DEBUG
        generation += 1
        #endif
        let item = AVPlayerItem(url: url)
        let nextPlayer = AVPlayer(playerItem: item)
        player = nextPlayer
        observation = item.observe(\.status, options: [.initial, .new]) { [weak self, weak item] _, _ in
            Task { @MainActor in
                guard let self, let item, self.player?.currentItem === item, item.status == .failed else { return }
                self.failed = true
                self.player?.pause()
            }
        }
        failureObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self, weak item] _ in
            Task { @MainActor in
                guard let self, let item, self.player?.currentItem === item else { return }
                self.failed = true
                self.player?.pause()
            }
        }
        #if DEBUG
        timeObserver = nextPlayer.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { [weak self, weak nextPlayer] time in
            Task { @MainActor in
                guard let self, let nextPlayer, self.player === nextPlayer, !self.hasAdvanced, time.seconds > 0.1 else { return }
                self.hasAdvanced = true
            }
        }
        #endif
        if automatically { nextPlayer.play() }
    }

    func pause() { player?.pause() }

    func stop() {
        observation?.invalidate()
        observation = nil
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        failureObserver = nil
        #if DEBUG
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        hasAdvanced = false
        #endif
        player?.pause()
        player = nil
        failed = false
    }
}

private struct VideoFeedView: View {
    @ObservedObject var model: FeedModel
    @Binding var selectedNote: FeedNote?
    let isActive: Bool
    @State private var index = 0
    @StateObject private var playback = PlaybackModel()
    @State private var error: String?
    @State private var loading = false
    @State private var retryGeneration = 0
    @State private var showPlaybackControls = false
    @AppStorage("autoplayNoteVideos") private var autoplay = true

    private var videos: [FeedNote] { model.notes.filter(\.isVideo) }
    private var current: FeedNote? { videos.indices.contains(index) ? videos[index] : nil }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color.black
            if let player = playback.player {
                VideoPlayer(player: player)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
            } else if loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let current {
                AsyncImage(url: current.cover) { image in image.resizable().scaledToFit() } placeholder: { Color.black }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            VStack(alignment: .leading, spacing: 16) {
                if let current {
                    Text(current.author).font(.headline)
                    Text(current.title).font(.title3).lineLimit(2)
                } else {
                    Text(model.loading ? "正在加载视频…" : "当前推荐中没有视频")
                }
                if let error { Text(error).font(.callout).foregroundStyle(.secondary) }
                if playback.failed { Text("视频播放失败，请重试或查看下一个").font(.callout).foregroundStyle(.secondary) }
                #if DEBUG
                if UIEnvironment.useFixtures && playback.hasAdvanced {
                    Text("测试视频正在播放").accessibilityIdentifier("video.fixture.playing")
                }
                if UIEnvironment.useFixtures && !autoplay {
                    Text("测试自动播放关闭").accessibilityIdentifier("video.fixture.autoplayOff")
                }
                if UIEnvironment.useFixtures {
                    Text("测试播放实例 \(playback.generation)").accessibilityIdentifier("video.fixture.instance")
                }
                #endif
                if let error = model.paginationError { Text(error).font(.callout).foregroundStyle(.secondary) }
                HStack {
                    Button("上一个") { index -= 1 }.disabled(index == 0)
                    Button("下一个") {
                        if index + 1 < videos.count { index += 1 }
                        else {
                            let previousIndex = index
                            Task {
                                await model.loadMore()
                                if index == previousIndex && index + 1 < videos.count { index += 1 }
                            }
                        }
                    }.disabled(model.loadingMore || (index + 1 >= videos.count && !model.hasMore))
                        .accessibilityIdentifier("video.next")
                    if let current {
                        Button("笔记详情") { selectedNote = current }
                    }
                    if playback.player != nil && !playback.failed {
                        Button("播放控制") { showPlaybackControls = true }
                            .accessibilityIdentifier("video.controls")
                    }
                    if error != nil || playback.failed {
                        Button("重试播放") { retryGeneration += 1 }
                    }
                    if model.paginationError != nil {
                        Button("重试加载") { Task { await model.retryLoadMore() } }
                    }
                    if let error = model.error, videos.isEmpty {
                        Text(error).font(.callout).foregroundStyle(.secondary)
                        Button("重试推荐") { Task { await model.refresh() } }
                    }
                    if model.loadingMore { ProgressView() }
                }
            }
            .padding(32)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22))
            .padding(48)
        }
        .fullScreenCover(isPresented: $showPlaybackControls) {
            if let player = playback.player {
                ZStack {
                    VideoPlayer(player: player).ignoresSafeArea()
                    #if DEBUG
                    if UIEnvironment.useFixtures {
                        Text("测试播放控制").accessibilityIdentifier("video.controls.open")
                    }
                    #endif
                }.onExitCommand { showPlaybackControls = false }
            }
        }
        .task(id: "\(current?.id ?? ""):\(isActive):\(retryGeneration)") {
            if isActive { await loadCurrent() } else { playback.stop() }
        }
        .onPlayPauseCommand {
            guard !showPlaybackControls, let player = playback.player else { return }
            if player.rate == 0 { player.play() } else { player.pause() }
        }
        .onChange(of: videos.count) { count in if index >= count { index = max(0, count - 1) } }
        .onDisappear { if !showPlaybackControls { playback.stop() } }
    }

    @MainActor
    private func loadCurrent() async {
        showPlaybackControls = false
        playback.stop()
        error = nil
        guard let note = current else { return }
        if UIEnvironment.useFixtures {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--ui-testing-playback-error") {
                playback.play(URL(fileURLWithPath: "/nonexistent-redshelf-test-video.mp4"))
            } else if ProcessInfo.processInfo.arguments.contains("--ui-testing-playback-success") {
                do { playback.play(try DebugPlaybackFixture.url(), automatically: autoplay) }
                catch { self.error = "无法加载测试视频" }
            }
            #endif
            return
        }
        loading = true
        defer { loading = false }
        do {
            guard let client = SignedClient.shared else { throw FeedError.unavailable }
            let detail = try await client.noteDetail(for: note)
            try Task.checkCancellation()
            guard let url = detail.video else { throw FeedError.unavailable }
            playback.play(url, automatically: autoplay)
        } catch is CancellationError { return }
        catch { if !Task.isCancelled { self.error = "无法播放此视频，请打开笔记或查看下一个" } }
    }
}

private struct SettingsView: View {
    @AppStorage("autoplayNoteVideos") private var autoplay = true

    var body: some View {
        Form {
            Section("播放") {
                Toggle("自动播放笔记视频", isOn: $autoplay)
                    .accessibilityIdentifier("settings.autoplay")
                Text("关闭后，打开视频时可用遥控器手动播放。直播不受此设置影响。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("关于") {
                LabeledContent("版本", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "开发版")
                Text("RedShelf 是独立客户端，与小红书无关联。")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

private struct LiveFeedView: View {
    @Binding var selectedLive: LiveRoom?
    @State private var rooms: [LiveRoom] = []
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if loading { ProgressView() }
                if let error {
                    Text(error).foregroundStyle(.secondary)
                    Button("重试") { Task { await load() } }
                } else if rooms.isEmpty && !loading { Text("暂无直播").foregroundStyle(.secondary) }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 48, alignment: .top), count: 4), spacing: 60) {
                    ForEach(rooms) { room in
                        Button { selectedLive = room } label: {
                            VStack(alignment: .leading, spacing: 12) {
                                AsyncImage(url: room.cover) { image in image.resizable().scaledToFill() } placeholder: { Color.white.opacity(0.08) }
                                    .frame(height: 438).frame(maxWidth: .infinity).clipped()
                                    .overlay(alignment: .topTrailing) {
                                        Label("直播中", systemImage: "dot.radiowaves.left.and.right")
                                            .font(.system(size: 16, weight: .semibold)).padding(6).background(.thinMaterial, in: Capsule()).padding(10)
                                    }
                                Text(room.title).font(.system(size: 24, weight: .semibold)).lineLimit(1)
                                HStack { Text(room.host); Spacer(); if !room.viewers.isEmpty { Label(room.viewers, systemImage: "person.2") } }
                                    .font(.system(size: 18)).foregroundStyle(.secondary)
                            }
                        }.buttonStyle(.card).accessibilityIdentifier("live.\(room.id)")
                    }
                }
                Button("刷新") { Task { await load() } }.disabled(loading)
            }.padding(.horizontal, 48).padding(.top, 20).padding(.bottom, 80)
        }.task { await load() }
    }

    @MainActor private func load() async {
        guard !loading else { return }
        if UIEnvironment.useFixtures {
            rooms = (0..<8).map { index in
                LiveRoom(id: "\(123 + index)", title: "测试直播 \(index + 1)", host: "测试主播", cover: nil, viewers: "")
            }
            return
        }
        loading = true
        error = nil
        defer { loading = false }
        do {
            guard let client = SignedClient.shared else { throw FeedError.unavailable }
            let result = try await client.liveRooms()
            try Task.checkCancellation()
            rooms = result
        } catch is CancellationError { return }
        catch { if !Task.isCancelled { self.error = "无法加载直播，请重试" } }
    }
}

private struct LivePlayerView: View {
    let room: LiveRoom
    @Environment(\.dismiss) private var dismiss
    @StateObject private var playback = PlaybackModel()
    @State private var error: String?
    @State private var retry = 0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let player = playback.player { VideoPlayer(player: player) }
            else if let error {
                VStack(spacing: 20) {
                    Text(error).foregroundStyle(.secondary)
                    Button("重试") { retry += 1 }
                }
            } else { ProgressView() }
            if playback.failed {
                VStack(spacing: 20) {
                    Text("直播播放失败").foregroundStyle(.secondary)
                    Button("重试") { retry += 1 }
                }.padding(30).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
            }
            #if DEBUG
            if UIEnvironment.useFixtures && playback.hasAdvanced {
                Text("测试直播正在播放").accessibilityIdentifier("live.fixture.playing")
            }
            #endif
        }
        .onExitCommand { dismiss() }
        .onDisappear { playback.stop() }
        .task(id: retry) {
            playback.stop()
            error = nil
            if UIEnvironment.useFixtures {
                #if DEBUG
                if let url = try? DebugPlaybackFixture.url() { playback.play(url) }
                #endif
                return
            }
            do {
                guard let client = SignedClient.shared else { throw FeedError.unavailable }
                let url = try await client.liveStream(roomID: room.id)
                try Task.checkCancellation()
                playback.play(url)
            } catch is CancellationError { return }
            catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
}

private enum SearchFilter: String, CaseIterable {
    case all = "全部", images = "图文", video = "视频", users = "用户"
    var noteType: Int {
        switch self { case .all, .users: return 0; case .images: return 2; case .video: return 1 }
    }
}

@MainActor
private final class SearchModel: ObservableObject {
    @Published var notes: [FeedNote] = []
    @Published var users: [SearchUser] = []
    @Published var loading = false
    @Published var error: String?
    @Published var searched = false
    @Published var hasMore = false
    private var searchTask: Task<Void, Never>?
    private var generation = 0
    private var page = 0
    private var searchID = ""
    private var activeKeyword = ""
    private var activeFilter = SearchFilter.all

    func search(keyword: String, filter: SearchFilter) {
        let query = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        searchTask?.cancel()
        generation += 1
        let current = generation
        activeKeyword = query
        activeFilter = filter
        page = 0
        searchID = ""
        hasMore = false
        notes = []
        users = []
        searched = true
        loading = true
        error = nil
        if UIEnvironment.useFixtures {
            if filter == .users { users = [SearchUser(id: "fixture-user", name: "测试创作者", redID: "test", avatar: nil, token: "")] }
            loading = false
            return
        }
        searchTask = Task { [weak self] in
            guard let self else { return }
            do {
                guard let client = SignedClient.shared else { throw FeedError.invalidResponse }
                let id = try await client.newSearchID()
                if filter == .users {
                    let result = try await client.searchUsers(keyword: query, page: 1, searchID: id)
                    try Task.checkCancellation()
                    guard self.generation == current else { return }
                    self.searchID = id
                    self.page = 1
                    self.users = result.users
                    self.hasMore = result.hasMore && !result.users.isEmpty
                    self.loading = false
                    return
                }
                let result = try await client.searchNotes(keyword: query, type: filter.noteType, page: 1, searchID: id)
                try Task.checkCancellation()
                guard self.generation == current else { return }
                self.searchID = id
                self.page = 1
                self.notes = result.notes
                self.hasMore = result.hasMore && !result.notes.isEmpty
            } catch is CancellationError { return }
            catch { if self.generation == current { self.error = "搜索失败，请重试" } }
            if self.generation == current { self.loading = false }
        }
    }

    func loadMore() {
        guard !loading, hasMore, !searchID.isEmpty else { return }
        let current = generation
        let next = page + 1
        let query = activeKeyword, filter = activeFilter, id = searchID
        loading = true
        error = nil
        searchTask = Task { [weak self] in
            guard let self else { return }
            do {
                guard let client = SignedClient.shared else { throw FeedError.invalidResponse }
                if filter == .users {
                    let result = try await client.searchUsers(keyword: query, page: next, searchID: id)
                    try Task.checkCancellation()
                    guard self.generation == current else { return }
                    var seen = Set(self.users.map(\.id))
                    let fresh = result.users.filter { seen.insert($0.id).inserted }
                    self.users.append(contentsOf: fresh)
                    self.page = next
                    self.hasMore = result.hasMore && !fresh.isEmpty
                    self.loading = false
                    return
                }
                let result = try await client.searchNotes(keyword: query, type: filter.noteType, page: next, searchID: id)
                try Task.checkCancellation()
                guard self.generation == current else { return }
                var seen = Set(self.notes.map(\.id))
                let fresh = result.notes.filter { seen.insert($0.id).inserted }
                self.notes.append(contentsOf: fresh)
                self.page = next
                self.hasMore = result.hasMore && !fresh.isEmpty
            } catch is CancellationError { return }
            catch { if self.generation == current { self.error = "加载更多失败，请重试" } }
            if self.generation == current { self.loading = false }
        }
    }
}

private struct SearchView: View {
    @Binding var selectedNote: FeedNote?
    @StateObject private var model = SearchModel()
    @State private var keyword = ""
    @State private var filter = SearchFilter.all
    @State private var selectedUser: SearchUser?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text("搜索").font(.title2.bold())
                TextField("搜索笔记或用户", text: $keyword)
                    .accessibilityIdentifier("search.field")
                    .onSubmit { model.search(keyword: keyword, filter: filter) }
                HStack(spacing: 20) {
                    ForEach(SearchFilter.allCases, id: \.self) { item in
                        Button(item.rawValue) {
                            filter = item
                            if model.searched { model.search(keyword: keyword, filter: item) }
                        }.buttonStyle(.bordered)
                    }
                }
                if let error = model.error {
                    Text(error).foregroundStyle(.secondary)
                    Button("重试") {
                        if model.notes.isEmpty && model.users.isEmpty { model.search(keyword: keyword, filter: filter) }
                        else { model.loadMore() }
                    }
                } else if model.searched && model.notes.isEmpty && model.users.isEmpty && !model.loading {
                    Text(filter == .users ? "没有找到相关用户" : "没有找到相关笔记").foregroundStyle(.secondary)
                }
                if filter == .users {
                    ForEach(model.users) { user in
                        Button { selectedUser = user } label: {
                            HStack(spacing: 24) {
                                AsyncImage(url: user.avatar) { image in image.resizable().scaledToFill() } placeholder: { Image(systemName: "person.crop.circle").resizable().foregroundStyle(.secondary) }
                                    .frame(width: 80, height: 80).clipShape(Circle())
                                VStack(alignment: .leading) { Text(user.name); if !user.redID.isEmpty { Text("小红书号：\(user.redID)").font(.caption).foregroundStyle(.secondary) } }
                                Spacer()
                            }
                        }.accessibilityIdentifier("search.user.\(user.id)")
                    }
                }
                NoteGrid(notes: model.notes, select: { selectedNote = $0 })
                if model.loading { ProgressView() }
                if model.hasMore && !model.loading && model.error == nil {
                    Button("加载更多") { model.loadMore() }
                }
            }.padding(.horizontal, 48).padding(.bottom, 80)
        }
        .fullScreenCover(item: $selectedUser) { user in UserSearchProfileView(user: user) }
        .task {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--ui-testing-search-users") {
                keyword = "测试"; filter = .users; model.search(keyword: keyword, filter: filter)
            }
            #endif
        }
    }
}

private struct UserSearchProfileView: View {
    let user: SearchUser
    @Environment(\.dismiss) private var dismiss
    @State private var selectedNote: FeedNote?
    @State private var notes: [FeedNote] = []
    @State private var cursor = ""
    @State private var hasMore = false
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(spacing: 24) {
                    AsyncImage(url: user.avatar) { image in image.resizable().scaledToFill() } placeholder: { Image(systemName: "person.crop.circle").resizable().foregroundStyle(.secondary) }
                        .frame(width: 100, height: 100).clipShape(Circle())
                    VStack(alignment: .leading) { Text(user.name).font(.title2.bold()); if !user.redID.isEmpty { Text("小红书号：\(user.redID)").foregroundStyle(.secondary) } }
                }
                Text("笔记").font(.title3.bold())
                if let error { Text(error).foregroundStyle(.secondary); Button("重试") { Task { await load() } } }
                else if notes.isEmpty && !loading { Text("暂无公开笔记").foregroundStyle(.secondary) }
                NoteGrid(notes: notes, select: { selectedNote = $0 })
                if loading { ProgressView() }
                if hasMore && !loading && error == nil { Button("加载更多") { Task { await load() } } }
            }.padding(48)
        }
        .onExitCommand { dismiss() }
        .fullScreenCover(item: $selectedNote) { NoteDetailView(note: $0) }
        .task { await load() }
    }

    @MainActor private func load() async {
        guard !loading else { return }
        if UIEnvironment.useFixtures {
            notes = [FeedNote(id: "user-note", title: "创作者测试笔记", author: user.name, cover: nil, avatar: nil, likes: "", isVideo: false, accessToken: "", source: "pc_user")]
            return
        }
        loading = true
        error = nil
        defer { loading = false }
        do {
            guard let client = SignedClient.shared else { throw FeedError.unavailable }
            let result = try await client.publicUserNotes(user: user, cursor: cursor)
            try Task.checkCancellation()
            var seen = Set(notes.map(\.id))
            let fresh = result.notes.filter { seen.insert($0.id).inserted }
            notes.append(contentsOf: fresh)
            hasMore = result.hasMore && !result.cursor.isEmpty && result.cursor != cursor && !fresh.isEmpty
            cursor = result.cursor
        } catch is CancellationError { return }
        catch { if !Task.isCancelled { self.error = "无法加载用户笔记，请重试" } }
    }
}

private struct LoginView: View {
    @ObservedObject var model: LoginModel
    let showAccounts: (() -> Void)?
    let onSuccess: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Text("登录小红书").font(.title.bold())
            if let image = model.image {
                Image(uiImage: image).interpolation(.none).resizable().frame(width: 380, height: 380).padding(20).background(.white)
                    .accessibilityIdentifier("login.qr")
            } else if model.failed {
                Image(systemName: "exclamationmark.circle").font(.system(size: 80)).foregroundStyle(.secondary).frame(width: 420, height: 420)
            } else { ProgressView().frame(width: 420, height: 420) }
            Text(model.message).font(.title3).foregroundStyle(.secondary)
            Button("重新生成") { model.retry(onSuccess: onSuccess) }
                .accessibilityIdentifier("login.retry")
            if let showAccounts {
                Button("选择已保存账号", action: showAccounts).accessibilityIdentifier("login.accounts")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(white: 0.08))
        .onAppear { model.startIfNeeded(onSuccess: onSuccess) }
    }
}

private struct AccountPicker: View {
    @ObservedObject var model: FeedModel
    let dismiss: () -> Void
    let select: (String) -> Void
    let add: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Text("切换账号").font(.title.bold())
            ForEach(model.accounts) { account in
                Button { select(account.id) } label: {
                    HStack {
                        Text(account.name)
                        Spacer()
                        if account.isActive { Image(systemName: "checkmark") }
                    }.frame(width: 500)
                }.accessibilityIdentifier("account.\(account.id)")
            }
            Button("添加账号", action: add).accessibilityIdentifier("account.add")
            Button("取消", action: dismiss)
            if model.sessionState == .checking { ProgressView() }
            if let error = model.accountError { Text(error).foregroundStyle(.secondary) }
        }.padding(60)
    }
}

private struct DetailImage: View {
    let url: URL
    let contentMode: ContentMode

    var body: some View {
        Group {
            #if DEBUG
            if url.isFileURL, let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image).resizable().aspectRatio(contentMode: contentMode).clipShape(RoundedRectangle(cornerRadius: 22))
            } else {
                AsyncImage(url: url) { image in image.resizable().aspectRatio(contentMode: contentMode).clipShape(RoundedRectangle(cornerRadius: 22)) } placeholder: { Color.white.opacity(0.08) }
            }
            #else
            AsyncImage(url: url) { image in image.resizable().aspectRatio(contentMode: contentMode).clipShape(RoundedRectangle(cornerRadius: 22)) } placeholder: { Color.white.opacity(0.08) }
            #endif
        }
    }
}

private struct NoteDetailView: View {
    let note: FeedNote
    @Environment(\.dismiss) private var dismiss
    @State private var detail: NoteDetail?
    @State private var error: String?
    @State private var selectedImage = 0
    @State private var descriptionExpanded = false
    @FocusState private var descriptionFocused: Bool
    @StateObject private var playback = PlaybackModel()
    @AppStorage("autoplayNoteVideos") private var autoplay = true
    @State private var comments: [NoteComment] = []
    @State private var commentCursor = ""
    @State private var commentsHaveMore = false
    @State private var commentsLoading = false
    @State private var commentsLoaded = false
    @State private var commentsError: String?
    @State private var liked: Bool?
    @State private var collected: Bool?
    @State private var interactionPending = false
    @State private var interactionError: String?

    var body: some View {
        HStack(spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                Color.black
                if let player = playback.player {
                    VideoPlayer(player: player)
                    if playback.failed {
                        VStack {
                            Text("视频播放失败").foregroundStyle(.secondary)
                            if let url = detail?.video { Button("重试播放") { playback.play(url) } }
                        }.padding(30).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
                    }
                } else if let images = detail?.images, !images.isEmpty {
                    VStack(spacing: 20) {
                        DetailImage(url: images[min(selectedImage, images.count - 1)], contentMode: .fit)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 22))
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("图片 \(selectedImage + 1)/\(images.count)")
                            .accessibilityIdentifier("detail.mainImage")
                        if images.count > 1 {
                            ScrollView(.horizontal) {
                                HStack {
                                    ForEach(images.indices, id: \.self) { index in
                                        Button { selectedImage = index } label: {
                                            DetailImage(url: images[index], contentMode: .fill)
                                                .frame(width: 68, height: 92).clipped().clipShape(RoundedRectangle(cornerRadius: 8))
                                        }.buttonStyle(.card).accessibilityIdentifier("detail.image.\(index)")
                                    }
                                }
                            }.frame(height: 110).padding(.horizontal, 36)
                            Button { descriptionFocused = true } label: {
                                Label("查看正文和评论", systemImage: "arrow.down")
                            }.buttonStyle(.plain).font(.system(size: 18)).foregroundStyle(.secondary)
                                .accessibilityIdentifier("detail.showText")
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 36)
                        }
                    }.padding(.vertical, 30)
                } else if let error {
                    Text(error).foregroundStyle(.secondary).padding(50)
                } else if detail != nil {
                    Text("暂无可显示的媒体").foregroundStyle(.secondary)
                } else { ProgressView() }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 14) {
                        AsyncImage(url: note.avatar) { image in image.resizable().scaledToFill() } placeholder: { Image(systemName: "person.crop.circle.fill").resizable().foregroundStyle(.secondary) }
                            .frame(width: 52, height: 52).clipShape(Circle())
                        Text(detail?.author ?? note.author).font(.system(size: 24, weight: .semibold))
                    }
                    Text(detail?.title ?? note.title).font(.system(size: 26, weight: .bold))
                    Text(detail?.description ?? "").font(.system(size: 24)).lineLimit(descriptionExpanded ? nil : 10)
                        .focusable().focused($descriptionFocused)
                    if (detail?.description.count ?? 0) > 200 {
                        Button(descriptionExpanded ? "收起" : "展开全文") { descriptionExpanded.toggle() }
                    }
                    if liked != nil || collected != nil {
                        HStack {
                            if let liked {
                                Button { Task { await setLiked(!liked) } } label: {
                                    Label(liked ? "已点赞" : "点赞", systemImage: liked ? "heart.fill" : "heart")
                                }.disabled(interactionPending)
                            }
                            if let collected {
                                Button { Task { await setCollected(!collected) } } label: {
                                    Label(collected ? "已收藏" : "收藏", systemImage: collected ? "star.fill" : "star")
                                }.disabled(interactionPending)
                            }
                        }
                    }
                    if let interactionError { Text(interactionError).font(.callout).foregroundStyle(.secondary) }
                    if let url = detail?.video, playback.player == nil {
                        Button("播放视频") { playback.play(url) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(32)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 24))
                .padding(28)
                VStack(alignment: .leading, spacing: 20) {
                    Text(detail?.commentCount.isEmpty == false ? "评论 \(detail?.commentCount ?? "")" : "评论").font(.title3.bold())
                    if let commentsError {
                        Text(commentsError).font(.callout).foregroundStyle(.secondary)
                        Button("重试") { Task { await loadComments() } }
                    } else if commentsLoaded && comments.isEmpty {
                        Text("暂无评论").font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(comments) { comment in
                        CommentThreadView(comment: comment, note: note)
                    }
                    if commentsLoading { ProgressView() }
                    if commentsHaveMore && !commentsLoading && commentsError == nil {
                        Button("加载更多") { Task { await loadComments() } }
                    }
                }.padding(.horizontal, 28).padding(.bottom, 50)
            }
            .frame(width: 712)
            .background(Color(white: 0.12))
        }
        .background(.black)
        .ignoresSafeArea()
        .onExitCommand { dismiss() }
        .onDisappear { playback.stop() }
        .task {
            if UIEnvironment.useFixtures {
                #if DEBUG
                let images = ProcessInfo.processInfo.arguments.contains("--ui-testing-detail-images") ? ((try? DebugPlaybackFixture.images()) ?? []) : []
                #else
                let images: [URL] = []
                #endif
                detail = NoteDetail(title: note.title, description: "用于界面验证的测试内容。", author: note.author,
                                    images: images, video: nil, liked: nil, collected: nil, likeCount: "", commentCount: "")
                return
            }
            do {
                let result: NoteDetail
                if let client = SignedClient.shared, await client.isLoggedIn {
                    result = try await client.noteDetail(for: note)
                } else {
                    result = try await FeedService().detail(for: note)
                }
                try Task.checkCancellation()
                detail = result
                liked = result.liked
                collected = result.collected
                if let video = result.video { playback.play(video, automatically: autoplay) }
            } catch is CancellationError { return }
            catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
        .task {
            if UIEnvironment.useFixtures {
                if ProcessInfo.processInfo.arguments.contains("--ui-testing-detail-images") {
                    comments = [NoteComment(id: "fixture-comment", author: "测试读者", avatar: nil, content: "测试评论", likes: "1", replyCount: "2")]
                }
                commentsLoaded = true
                return
            }
            await loadComments()
        }
    }

    @MainActor
    private func setLiked(_ value: Bool) async {
        guard !interactionPending, let client = SignedClient.shared else { return }
        interactionPending = true
        interactionError = nil
        defer { interactionPending = false }
        do { try await client.setLiked(value, noteID: note.id); liked = value }
        catch { interactionError = "点赞操作失败，请重试" }
    }

    @MainActor
    private func setCollected(_ value: Bool) async {
        guard !interactionPending, let client = SignedClient.shared else { return }
        interactionPending = true
        interactionError = nil
        defer { interactionPending = false }
        do { try await client.setCollected(value, noteID: note.id); collected = value }
        catch { interactionError = "收藏操作失败，请重试" }
    }

    @MainActor
    private func loadComments() async {
        guard !commentsLoading else { return }
        guard let client = SignedClient.shared, await client.isLoggedIn else {
            commentsError = "登录后可查看评论"
            return
        }
        commentsLoading = true
        commentsError = nil
        defer { commentsLoading = false }
        do {
            let page = try await client.comments(for: note, cursor: commentCursor)
            let merged = page.merging(with: comments, previousCursor: commentCursor)
            comments = merged.comments
            commentsHaveMore = merged.hasMore
            commentCursor = page.cursor
            commentsLoaded = true
        } catch is CancellationError {
            return
        } catch { commentsError = "暂时无法加载评论" }
    }
}

private struct CommentThreadView: View {
    let comment: NoteComment
    let note: FeedNote
    @State private var replies: [NoteComment] = []
    @State private var cursor = ""
    @State private var hasMore = false
    @State private var loaded = false
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            commentRow(comment)
                .focusable().accessibilityElement(children: .combine)
                .accessibilityIdentifier("comment.\(comment.id)")
            ForEach(replies) { reply in
                commentRow(reply).padding(.leading, 42).focusable().accessibilityElement(children: .combine)
            }
            if loaded && replies.isEmpty && !loading && error == nil { Text("暂无回复").font(.callout).foregroundStyle(.secondary) }
            if let error { Text(error).font(.callout).foregroundStyle(.secondary) }
            if loading { ProgressView() }
            else if error != nil || hasMore || (!loaded && !comment.replyCount.isEmpty && comment.replyCount != "0") {
                Button(error != nil ? "重试回复" : (loaded ? "加载更多回复" : "查看回复 \(comment.replyCount)")) {
                    Task { await loadReplies() }
                }.accessibilityIdentifier("comment.replies.\(comment.id)")
            }
        }
    }

    private func commentRow(_ item: NoteComment) -> some View {
        HStack(alignment: .top, spacing: 14) {
            AsyncImage(url: item.avatar) { image in image.resizable().scaledToFill() } placeholder: { Color.white.opacity(0.1) }
                .frame(width: 46, height: 46).clipShape(Circle())
            VStack(alignment: .leading, spacing: 8) {
                Text(item.author).font(.callout).foregroundStyle(.secondary)
                Text(item.content).font(.body)
                if !item.likes.isEmpty { Label(item.likes, systemImage: "heart").font(.caption).foregroundStyle(.secondary) }
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18))
    }

    @MainActor private func loadReplies() async {
        guard !loading else { return }
        if UIEnvironment.useFixtures {
            replies = [NoteComment(id: "fixture-reply", author: "测试回复者", avatar: nil, content: "测试回复", likes: "")]
            loaded = true
            return
        }
        loading = true
        error = nil
        defer { loading = false }
        do {
            guard let client = SignedClient.shared else { throw FeedError.unavailable }
            let page = try await client.replies(for: note, rootID: comment.id, cursor: cursor)
            try Task.checkCancellation()
            let merged = page.merging(with: replies, previousCursor: cursor)
            replies = merged.comments
            hasMore = merged.hasMore
            cursor = page.cursor
            loaded = true
        } catch is CancellationError { return }
        catch { if !Task.isCancelled { self.error = "暂时无法加载回复" } }
    }
}

private struct NoteGrid: View {
    let notes: [FeedNote]
    let select: (FeedNote) -> Void
    var onLastAppear: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 48) {
            ForEach(0..<4, id: \.self) { column in
                LazyVStack(spacing: 80) {
                    ForEach(Array(notes.enumerated()).filter { $0.offset % 4 == column }, id: \.element.id) { entry in
                        Button { select(entry.element) } label: { NoteCard(note: entry.element) }
                            .buttonStyle(.card)
                            .accessibilityIdentifier("note.\(entry.element.id)")
                            .onAppear { if entry.offset == notes.count - 1 { onLastAppear?() } }
                    }
                }.frame(maxWidth: .infinity, alignment: .top)
            }
        }
    }
}

private struct NoteCard: View {
    let note: FeedNote
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AsyncImage(url: note.cover) { image in image.resizable().scaledToFill() } placeholder: { Color.white.opacity(0.08) }
                .frame(height: 500).frame(maxWidth: .infinity).clipped().clipShape(RoundedRectangle(cornerRadius: 18))
                .overlay(alignment: .topTrailing) {
                    if note.isVideo { Image(systemName: "play.circle.fill").padding(14) }
                }
            Text(note.title).font(.system(size: 24, weight: .semibold)).lineLimit(2)
            HStack(spacing: 8) {
                AsyncImage(url: note.avatar) { image in image.resizable().scaledToFill() } placeholder: { Color.white.opacity(0.1) }
                    .frame(width: 28, height: 28).clipShape(Circle())
                Text(note.author).lineLimit(1)
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    Image(systemName: "heart")
                    Text(note.likes)
                }
            }.font(.system(size: 20)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
