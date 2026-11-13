import SwiftUI
import AVKit
import CoreImage.CIFilterBuiltins

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
    enum SessionState { case checking, signedOut, signedIn }
    @Published private(set) var sessionState: SessionState = .checking
    @Published var notes: [FeedNote] = []
    @Published var error: String?
    @Published var loading = false
    private let service = FeedService()

    func restoreSession() async {
        guard let client = SignedClient.shared else {
            sessionState = .signedOut
            return
        }
        sessionState = await client.isLoggedIn ? .signedIn : .signedOut
        if sessionState == .signedIn { await refresh() }
    }

    func didLogIn() async {
        sessionState = .signedIn
        await refresh()
    }

    func refresh() async {
        guard !loading else { return }
        loading = true
        error = nil
        defer { loading = false }
        do {
            if let client = SignedClient.shared, await client.isLoggedIn {
                notes = try await client.homeFeed()
                if notes.isEmpty { throw FeedError.unavailable }
            } else {
                notes = try await service.fetch()
            }
        }
        catch { self.error = error.localizedDescription }
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

    private func start(onSuccess: @escaping () -> Void) {
        generation += 1
        let current = generation
        image = nil
        failed = false
        message = "正在生成二维码…"
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
    }

    private var login: some View {
        LoginView(model: loginModel) {
            page = .recommendations
            Task { await model.didLogIn() }
        }
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
        case .video: unavailable("视频", "视频流正在开发中")
        case .live: unavailable("直播", "直播正在开发中")
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
            case .signedIn: unavailable("我的", "个人资料正在开发中")
            }
        case .settings: unavailable("设置", "暂无可用设置")
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
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 48, alignment: .top), count: 4), spacing: 52) {
                        ForEach(model.notes) { note in
                            Button { selectedNote = note } label: { NoteCard(note: note) }
                                .buttonStyle(.card)
                        }
                    }.padding(.horizontal, 120).padding(.bottom, 90)
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

private enum SearchFilter: String, CaseIterable {
    case all = "全部", images = "图文", video = "视频"
    var noteType: Int {
        switch self { case .all: return 0; case .images: return 2; case .video: return 1 }
    }
}

@MainActor
private final class SearchModel: ObservableObject {
    @Published var notes: [FeedNote] = []
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
        searched = true
        loading = true
        error = nil
        searchTask = Task { [weak self] in
            guard let self else { return }
            do {
                guard let client = SignedClient.shared else { throw FeedError.invalidResponse }
                let id = try await client.newSearchID()
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text("搜索").font(.title2.bold())
                TextField("搜索笔记", text: $keyword)
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
                        if model.notes.isEmpty { model.search(keyword: keyword, filter: filter) }
                        else { model.loadMore() }
                    }
                } else if model.searched && model.notes.isEmpty && !model.loading {
                    Text("没有找到相关笔记").foregroundStyle(.secondary)
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 48, alignment: .top), count: 4), spacing: 52) {
                    ForEach(model.notes) { note in
                        Button { selectedNote = note } label: { NoteCard(note: note) }.buttonStyle(.card)
                    }
                }
                if model.loading { ProgressView() }
                if model.hasMore && !model.loading && model.error == nil {
                    Button("加载更多") { model.loadMore() }
                }
            }.padding(.horizontal, 120).padding(.bottom, 80)
        }
    }
}

private struct LoginView: View {
    @ObservedObject var model: LoginModel
    let onSuccess: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Text("登录小红书").font(.title.bold())
            if let image = model.image {
                Image(uiImage: image).interpolation(.none).resizable().frame(width: 380, height: 380).padding(20).background(.white)
            } else if model.failed {
                Image(systemName: "exclamationmark.circle").font(.system(size: 80)).foregroundStyle(.secondary).frame(width: 420, height: 420)
            } else { ProgressView().frame(width: 420, height: 420) }
            Text(model.message).font(.title3).foregroundStyle(.secondary)
            Button("重新生成") { model.retry(onSuccess: onSuccess) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(white: 0.08))
        .onAppear { model.startIfNeeded(onSuccess: onSuccess) }
    }
}

private struct NoteDetailView: View {
    let note: FeedNote
    @Environment(\.dismiss) private var dismiss
    @State private var detail: NoteDetail?
    @State private var error: String?
    @State private var selectedImage = 0
    @State private var player: AVPlayer?
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
                if let player {
                    VideoPlayer(player: player).onAppear { player.play() }.onDisappear { player.pause() }
                } else if let images = detail?.images, !images.isEmpty {
                    VStack(spacing: 20) {
                        AsyncImage(url: images[min(selectedImage, images.count - 1)]) { image in
                            image.resizable().scaledToFit()
                        } placeholder: { ProgressView() }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        if images.count > 1 {
                            ScrollView(.horizontal) {
                                HStack {
                                    ForEach(images.indices, id: \.self) { index in
                                        Button { selectedImage = index } label: {
                                            AsyncImage(url: images[index]) { image in image.resizable().scaledToFill() } placeholder: { Color.gray }
                                                .frame(width: 68, height: 92).clipped().clipShape(RoundedRectangle(cornerRadius: 8))
                                        }.buttonStyle(.card)
                                    }
                                }
                            }.frame(height: 110).padding(.horizontal, 36)
                        }
                    }.padding(.vertical, 30)
                } else if let error {
                    Text(error).foregroundStyle(.secondary).padding(50)
                } else { ProgressView() }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(detail?.author ?? note.author).font(.headline)
                    Text(detail?.title ?? note.title).font(.title3.bold())
                    Text(detail?.description ?? "").font(.body)
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
                    if let url = detail?.video, player == nil {
                        Button("播放视频") { player = AVPlayer(url: url) }
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
                        HStack(alignment: .top, spacing: 14) {
                            AsyncImage(url: comment.avatar) { image in image.resizable().scaledToFill() } placeholder: { Color.white.opacity(0.1) }
                                .frame(width: 46, height: 46).clipShape(Circle())
                            VStack(alignment: .leading, spacing: 8) {
                                Text(comment.author).font(.callout).foregroundStyle(.secondary)
                                Text(comment.content).font(.body)
                                if !comment.likes.isEmpty { Label(comment.likes, systemImage: "heart").font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(20)
                        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18))
                    }
                    if commentsLoading { ProgressView() }
                    if commentsHaveMore && !commentsLoading && commentsError == nil {
                        Button("加载更多") { Task { await loadComments() } }
                    }
                }.padding(.horizontal, 28).padding(.bottom, 50)
            }
            .frame(width: 600)
            .background(Color(white: 0.12))
        }
        .background(.black)
        .onExitCommand { dismiss() }
        .task {
            do {
                let result: NoteDetail
                if let client = SignedClient.shared, await client.isLoggedIn {
                    result = try await client.noteDetail(for: note)
                } else {
                    result = try await FeedService().detail(for: note)
                }
                detail = result
                liked = result.liked
                collected = result.collected
                if let video = result.video { player = AVPlayer(url: video) }
            } catch { self.error = error.localizedDescription }
        }
        .task { await loadComments() }
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
            let existingIDs = Set(comments.map(\.id))
            comments.append(contentsOf: page.comments.filter { !existingIDs.contains($0.id) })
            commentsHaveMore = page.hasMore && !page.cursor.isEmpty && page.cursor != commentCursor
            commentCursor = page.cursor
            commentsLoaded = true
        } catch is CancellationError {
            return
        } catch { commentsError = "暂时无法加载评论" }
    }
}

private struct NoteCard: View {
    let note: FeedNote
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AsyncImage(url: note.cover) { image in image.resizable().scaledToFill() } placeholder: { Color.white.opacity(0.08) }
                .frame(height: 440).frame(maxWidth: .infinity).clipped().clipShape(RoundedRectangle(cornerRadius: 18))
                .overlay(alignment: .topTrailing) {
                    if note.isVideo { Image(systemName: "play.circle.fill").padding(14) }
                }
            Text(note.title).font(.system(size: 24, weight: .semibold)).lineLimit(2)
            HStack {
                AsyncImage(url: note.avatar) { image in image.resizable().scaledToFill() } placeholder: { Color.white.opacity(0.1) }
                    .frame(width: 28, height: 28).clipShape(Circle())
                Text(note.author).lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "heart")
                Text(note.likes)
            }.font(.system(size: 20)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
