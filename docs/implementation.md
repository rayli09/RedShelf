# Implementation and verification

`RedShelf/` contains the native tvOS app, `Signer/` contains the Go signing bridge, and `WebSigner/` builds the JavaScriptCore signer. `project.yml` is the source for the XcodeGen project. The generated project, signer framework, bundled JavaScript and tools are ignored by Git.

The app stores account sessions in the device Keychain. Authentication and content use unofficial web interfaces that can change without notice. RedNote accounts use a separate regional session; the live interface is hidden from navigation.

## Tests

The commands in the README cover parser and account-vault tests, Go tests, and the synthetic authentication flow. They do not prove a real account or media stream works.

Run remote-control UI tests on an installed tvOS Simulator runtime:

```sh
xcodebuild test -scheme RedShelf \
  -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation) (at 1080p)' \
  -only-testing:RedShelfUITests
```

Use the same destination with `-only-testing:RedShelfTests/SecureSessionTests` to test an isolated Keychain item containing synthetic data. UI tests also use synthetic fixtures; verify affected interactions on a physical Apple TV.

## Artwork

The layered icon and Top Shelf assets are generated from `Artwork/pixel-top-shelf.png`:

```sh
swift scripts/generate-icon.swift
```

Commit the source artwork and generated assets together.

## References

- The JavaScriptCore signer uses [`xhshow-ts`](https://github.com/ikenxuan/xhshow-ts) and `@jspm/core`; the Go bridge uses [`xiaohongshu-cli`](https://github.com/tamnd/xiaohongshu-cli) and the tvOS build uses [`gomobile-tvos-fork`](https://github.com/netbirdio/gomobile-tvos-fork). Versions are pinned in the project. License notices are in [`RedShelf/ThirdParty`](../RedShelf/ThirdParty/NOTICE.txt).
- QR and feed request shapes were compared with [`jackwener/xiaohongshu-cli`](https://github.com/jackwener/xiaohongshu-cli) at `4d63f3c` and the Xiaohongshu web client's [login](https://fe-platform-s10.rednotecdn.com/formula-static/xhs-pc-web/public/resource/js/async/Login.8458d1bf.js) and [regional routing](https://fe-platform-s10.rednotecdn.com/formula-static/xhs-pc-web/public/resource/js/async/3375.8d7cb300.js) code.
- Live request and public room formats were studied using [`catbus`](https://github.com/cv-cat/catbus) at `0048604` and [`pure_live`](https://github.com/wzgrx/pure_live) at `ddd83cb`. Live playback remains unverified on a real account and device.
