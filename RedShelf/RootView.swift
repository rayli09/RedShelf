import SwiftUI

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
    @Published var notes: [FeedNote] = []
    @Published var error: String?
    @Published var loading = false
    private let service = FeedService()

    func refresh() async {
        guard !loading else { return }
        loading = true
        error = nil
        defer { loading = false }
        do { notes = try await service.fetch() }
        catch { self.error = error.localizedDescription }
    }
}

struct RootView: View {
    @State private var page: Page = .recommendations
    @StateObject private var model = FeedModel()

    var body: some View {
        ZStack(alignment: .top) {
            Color(red: 0.08, green: 0.08, blue: 0.08).ignoresSafeArea()
            VStack(spacing: 0) {
                navigation.padding(.top, 24).padding(.bottom, 28)
                Group {
                    switch page {
                    case .recommendations: feed
                    case .video: unavailable("视频", "视频流正在开发中")
                    case .live: unavailable("直播", "直播正在开发中")
                    case .search: unavailable("搜索", "搜索正在开发中")
                    case .profile: unavailable("我的", "账号登录正在开发中")
                    case .settings: unavailable("设置", "暂无可用设置")
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .preferredColorScheme(.dark)
        .task { await model.refresh() }
    }

    private var navigation: some View {
        HStack(spacing: 4) {
            ForEach(Page.allCases, id: \.self) { item in
                Button { page = item } label: {
                    Label(item.rawValue, systemImage: item.symbol)
                        .font(.system(size: 23, weight: .semibold))
                        .padding(.horizontal, 18).padding(.vertical, 10)
                        .foregroundStyle(page == item ? .black : .white)
                        .background(page == item ? Color.white : Color.clear, in: Capsule())
                }.buttonStyle(.plain)
            }
        }
        .padding(5)
        .background(Color.white.opacity(0.07), in: Capsule())
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
                            Button {} label: { NoteCard(note: note) }
                                .buttonStyle(.card)
                                .disabled(true)
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
