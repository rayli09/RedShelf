# RedShelf

Native tvOS client for browsing Xiaohongshu. The `RedShelf/` target owns the interface and network code; `RedShelfTests/` owns parser tests. The UI follows the public Rouge App Store screenshots as a visual reference; do not use Rouge branding or copied media.

Generate the Xcode project with `xcodegen generate`; build with `xcodebuild -scheme RedShelf -destination 'generic/platform=tvOS' CODE_SIGNING_ALLOWED=NO build`. Run parser tests with `swift test`; run UI verification on a configured tvOS simulator or Apple TV.

`project.yml` is the source of truth; `RedShelf.xcodeproj` is generated and ignored. Never commit credentials, cookies, personal content, or signing profiles. Keep authentication opt-in and use secure storage; do not describe inaccessible endpoints or sample data as working features. Test focus behavior on a real Apple TV before claiming visual parity.
