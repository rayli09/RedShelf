# RedShelf

Native tvOS client for browsing Xiaohongshu. `RedShelf/` owns the app, `Signer/` the pinned Go signing bridge, and `RedShelfTests/` parser tests. Follow `README.md` for setup and references, and `docs/roadmap.md` for acceptance criteria and current status. The UI uses Rouge's public App Store screenshots as visual reference; do not copy its branding or media.

Run `./scripts/build-signer.sh` and `./scripts/build-web-signer.sh`, then `xcodegen generate`; build with `xcodebuild -scheme RedShelf -destination 'generic/platform=tvOS' CODE_SIGNING_ALLOWED=NO build`. Test with `swift test`, `(cd Signer && go test ./...)`, and `./scripts/test-auth-flow.sh`. Check focus behavior on an Apple TV when changing UI.

`project.yml` and Go source are authoritative. The Xcode project, framework and tool binaries are generated and ignored. Never commit credentials, cookies, personal content or signing profiles. Store session material in Keychain, never logs. Do not claim login, feeds or playback work until validated end to end on a real device.
