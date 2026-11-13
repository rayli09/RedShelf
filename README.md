# RedShelf

An experimental native Apple TV client inspired by public Rouge App Store screenshots. It is not affiliated with Xiaohongshu or Rouge.

**Status:** the home and profile tabs share a QR login screen. QR creation and waiting for a scan have been tested; completion of login, authenticated recommendations, note details and playback are not yet verified. Video, live, search and profile are incomplete. Do not treat this as a working replacement yet.

## Build and test

Requires Xcode, XcodeGen and Go 1.27.1 or newer:

```sh
./scripts/build-signer.sh
xcodegen generate
xcodebuild -scheme RedShelf -destination 'generic/platform=tvOS' CODE_SIGNING_ALLOWED=NO build
swift test
(cd Signer && go test ./...)
```

Open `RedShelf.xcodeproj` and choose your own signing team and bundle identifier for a physical Apple TV. The XCFramework and Xcode project are generated locally and are not committed.

The native signing bridge uses [`tamnd/xiaohongshu-cli`](https://github.com/tamnd/xiaohongshu-cli), pinned in `Signer/go.mod` and licensed Apache-2.0. The build tool is the BSD-licensed [`netbirdio/gomobile-tvos-fork`](https://github.com/netbirdio/gomobile-tvos-fork), pinned in `scripts/build-signer.sh`. These unofficial interfaces may change without notice. Session data is intended to stay in the device Keychain; never add credentials or cookies to the repository.

The QR polling, session completion and feed request shapes were cross-checked against [`jackwener/xiaohongshu-cli`](https://github.com/jackwener/xiaohongshu-cli) at commit `4d63f3c`. Its preferred login uses a browser; our direct tvOS completion path is still unverified.
