#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
"$root/scripts/build-web-signer.sh" >/dev/null
version=v0.0.0-20260129172842-a56582c0e7c9
mkdir -p "$root/.tools/bin" "$root/.build/auth-flow"
GOBIN="$root/.tools/bin" go install "github.com/netbirdio/gomobile-tvos-fork/cmd/gomobile-netbird@$version"
GOBIN="$root/.tools/bin" go install "github.com/netbirdio/gomobile-tvos-fork/cmd/gobind-netbird@$version"
cd "$root/Signer"
PATH="$root/.tools/bin:$PATH" gomobile-netbird bind -target=macos -o "$root/.build/auth-flow/Signer.xcframework" .
cd "$root"
swiftc -swift-version 5 -parse-as-library -F "$root/.build/auth-flow/Signer.xcframework/macos-arm64_x86_64" RedShelf/Feed.swift RedShelf/SignedClient.swift RedShelf/WebSigner.swift RedShelf/SessionKeyExchange.swift TestsSupport/AuthFlowChecks.swift -framework Signer -o "$root/.build/auth-flow/checks"
"$root/.build/auth-flow/checks"
