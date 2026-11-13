# RedShelf

An experimental native Apple TV client inspired by public Rouge App Store screenshots. It is not affiliated with Xiaohongshu or Rouge.

**Status:** the home and profile tabs share a QR login screen. QR creation and waiting for a scan have been tested; completion of login, authenticated recommendations, note details and playback are not yet verified. Video, live, search and profile are incomplete. Do not treat this as a working replacement yet.

## Build and test

Requires Xcode, XcodeGen, Bun and Go 1.27.1 or newer:

```sh
./scripts/build-signer.sh
./scripts/build-web-signer.sh
xcodegen generate
xcodebuild -scheme RedShelf -destination 'generic/platform=tvOS' CODE_SIGNING_ALLOWED=NO build
swift test
(cd Signer && go test ./...)
./scripts/test-auth-flow.sh
```

Open `RedShelf.xcodeproj` and choose your own signing team and bundle identifier for a physical Apple TV. The XCFramework and Xcode project are generated locally and are not committed.

The JavaScriptCore signer bundles the MIT-licensed [`xhshow-ts`](https://github.com/ikenxuan/xhshow-ts) and Apache-licensed `@jspm/core` shims; dependency versions are fixed in `WebSigner/bun.lock` and license notices are in `RedShelf/ThirdParty`. The build-only polyfill plugin is deprecated; replace it when a maintained equivalent is verified. The native signing bridge uses [`tamnd/xiaohongshu-cli`](https://github.com/tamnd/xiaohongshu-cli), pinned in `Signer/go.mod` and licensed Apache-2.0. The build tool is the BSD-licensed [`netbirdio/gomobile-tvos-fork`](https://github.com/netbirdio/gomobile-tvos-fork), pinned in `scripts/build-signer.sh`. These unofficial interfaces may change without notice. Session data is intended to stay in the device Keychain; never add credentials or cookies to the repository.

The QR polling, session completion and feed request shapes were cross-checked against [`jackwener/xiaohongshu-cli`](https://github.com/jackwener/xiaohongshu-cli) at commit `4d63f3c`. Its preferred login uses a browser; our direct tvOS completion path is still unverified.

`test-auth-flow.sh` uses an in-memory HTTP server and synthetic credentials to test waiting, scan, confirmation, identity mismatch, expiry, note details, comments and query encoding. It does not prove that the upstream service accepts the requests or that a real account can sign in.
