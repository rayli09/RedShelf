#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
mkdir -p "$root/Generated"
cd "$root/WebSigner"
bun install --frozen-lockfile
bun run build.mjs
