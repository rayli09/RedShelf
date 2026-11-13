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

struct RootView: View {
    @State private var page: Page = .recommendations
    @State private var selectedNote: FeedNote?
    @StateObject private var model = FeedModel()

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
        LoginView {
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
        case .search: unavailable("搜索", "搜索正在开发中")
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

private struct LoginView: View {
    let onSuccess: () -> Void
    @State private var image: UIImage?
    @State private var message = "正在生成二维码…"
    @State private var failed = false
    @State private var attempt = 0

    var body: some View {
        VStack(spacing: 24) {
            Text("登录小红书").font(.title.bold())
            if let image {
                Image(uiImage: image).interpolation(.none).resizable().frame(width: 380, height: 380).padding(20).background(.white)
            } else if failed {
                Image(systemName: "exclamationmark.circle").font(.system(size: 80)).foregroundStyle(.secondary).frame(width: 420, height: 420)
            } else { ProgressView().frame(width: 420, height: 420) }
            Text(message).font(.title3).foregroundStyle(.secondary)
            Button("重新生成") { attempt += 1 }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(white: 0.08))
        .task(id: attempt) { await login() }
    }

    @MainActor
    private func login() async {
        image = nil
        failed = false
        message = "正在生成二维码…"
        var stage = "生成二维码"
        do {
            guard let client = SignedClient.shared else { throw FeedError.invalidResponse }
            let challenge = try await client.beginLogin()
            let filter = CIFilter.qrCodeGenerator()
            filter.message = Data(challenge.url.absoluteString.utf8)
            filter.correctionLevel = "M"
            guard let output = filter.outputImage, let cg = CIContext().createCGImage(output, from: output.extent) else { throw FeedError.invalidResponse }
            image = UIImage(cgImage: cg)
            message = "请使用小红书 App 扫码并确认"
            stage = "检查登录状态"
            for _ in 0..<90 {
                try await Task.sleep(nanoseconds: 2_000_000_000)
                switch try await client.checkLogin(challenge) {
                case .waiting: break
                case .scanned: message = "已扫码，请在手机上确认登录"
                case .authenticated: onSuccess(); return
                }
            }
            message = "二维码已过期，请重新生成"
        } catch is CancellationError {
            return
        } catch {
            image = nil
            failed = true
            message = "\(stage)失败：\(error.localizedDescription)"
        }
    }
}

private struct NoteDetailView: View {
    let note: FeedNote
    @Environment(\.dismiss) private var dismiss
    @State private var detail: NoteDetail?
    @State private var error: String?
    @State private var selectedImage = 0
    @State private var player: AVPlayer?

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
                    if let url = detail?.video, player == nil {
                        Button("播放视频") { player = AVPlayer(url: url) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(32)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 24))
                .padding(28)
            }
            .frame(width: 600)
            .background(Color(white: 0.12))
        }
        .background(.black)
        .onExitCommand { dismiss() }
        .task {
            do {
                let result = try await FeedService().detail(for: note)
                detail = result
                if let video = result.video { player = AVPlayer(url: video) }
            } catch { self.error = error.localizedDescription }
        }
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
