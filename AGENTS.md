# RedShelf

Native tvOS client for browsing Xiaohongshu. `RedShelf/` owns the app, `Signer/` the pinned Go signing bridge, and `RedShelfTests/` parser tests. Follow `README.md` for setup and references, and `docs/roadmap.md` for acceptance criteria and current status. The UI uses Rouge's public App Store screenshots as visual reference; do not copy its branding or media.

Use native tvOS navigation, focus and system materials. Keep text styles centralized in `AppTypography` and use semantic system fonts. Test remote navigation, focus scaling, readable contrast and large text on affected screens. Reuse the note-detail and image prefetch caches; invalidate account-scoped data on account changes and interactions.

Run `./scripts/build-signer.sh` and `./scripts/build-web-signer.sh`, then `xcodegen generate`; build with `xcodebuild -scheme RedShelf -destination 'generic/platform=tvOS' CODE_SIGNING_ALLOWED=NO build`. Test with `swift test`, `(cd Signer && go test ./...)`, and `./scripts/test-auth-flow.sh`. Run `RedShelfUITests` on the tvOS simulator when changing UI, then check focus behavior on an Apple TV.

`project.yml` and Go source are authoritative. The Xcode project, framework and tool binaries are generated and ignored. Never commit credentials, cookies, personal content or signing profiles. Store session material in Keychain, never logs. Do not claim login, feeds or playback work until validated end to end on a real device.

Regenerate the layered icon and Top Shelf assets with `swift scripts/generate-icon.swift` after changing `Artwork/pixel-top-shelf.png`; commit the source and generated assets together. Keep mock, simulator and physical-device evidence distinct.
