// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RedShelf",
    platforms: [.macOS(.v13), .tvOS(.v16)],
    targets: [
        .target(name: "RedShelf", path: "RedShelf", exclude: ["RedShelfApp.swift", "RootView.swift", "SignedClient.swift", "WebSigner.swift", "SessionKeyExchange.swift", "DebugPlaybackFixture.swift", "ThirdParty", "Assets.xcassets"], sources: ["Feed.swift", "AccountVault.swift"]),
        .testTarget(name: "RedShelfTests", dependencies: ["RedShelf"], path: "RedShelfTests"),
    ]
)
