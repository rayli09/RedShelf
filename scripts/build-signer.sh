#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
version=v0.0.0-20260129172842-a56582c0e7c9
mkdir -p "$root/.tools/bin" "$root/Frameworks"
GOBIN="$root/.tools/bin" go install "github.com/netbirdio/gomobile-tvos-fork/cmd/gomobile-netbird@$version"
GOBIN="$root/.tools/bin" go install "github.com/netbirdio/gomobile-tvos-fork/cmd/gobind-netbird@$version"
cd "$root/Signer"
PATH="$root/.tools/bin:$PATH" gomobile-netbird bind -target=tvos,tvossimulator -tvosversion=16.0 -o "$root/Frameworks/Signer.xcframework" .
