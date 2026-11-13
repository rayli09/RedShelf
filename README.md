# RedShelf

[![tvOS 16+](https://img.shields.io/badge/tvOS-16%2B-000000?logo=apple)](https://developer.apple.com/tvos/)
[![Swift](https://img.shields.io/badge/Swift-5-F05138?logo=swift&logoColor=white)](https://www.swift.org/)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![GitHub stars](https://img.shields.io/github/stars/rayli09/RedShelf?style=flat&logo=github)](https://github.com/rayli09/RedShelf/stargazers)

An experimental native Xiaohongshu client for Apple TV. Browse recommendations, videos and notes, search, and switch accounts with the Siri Remote.

![RedShelf pixel artwork](Artwork/pixel-top-shelf.png)

QR sign-in and the recommendation feed have been observed on a physical Apple TV. Other features are still being verified; see the [roadmap](docs/roadmap.md).

## Get started

Requires macOS, Xcode, XcodeGen, Bun, Go 1.27.1+, and an Apple TV running tvOS 16 or later.

```sh
git clone https://github.com/rayli09/RedShelf.git
cd RedShelf
./scripts/build-signer.sh
./scripts/build-web-signer.sh
xcodegen generate
open RedShelf.xcodeproj
```

In Xcode, choose your signing team and a unique bundle identifier, select your Apple TV, and run the app. Regenerating the project resets Xcode project changes.

## Verify

```sh
swift test
(cd Signer && go test ./...)
./scripts/test-auth-flow.sh
```

See [implementation and UI tests](docs/implementation.md) for simulator commands, architecture, and references.

## License

[MIT](LICENSE). Third-party components retain their own [licenses](RedShelf/ThirdParty/NOTICE.txt). RedShelf is independent and is not affiliated with Xiaohongshu or Rouge.
