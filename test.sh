#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="$(mktemp -d "${TMPDIR:-/tmp}/cswap-test.XXXXXX")"
trap 'rm -rf "$BUILD"' EXIT
swiftc -swift-version 5 -parse-as-library -module-cache-path "$BUILD/ModuleCache" \
  "$ROOT/Sources/LocalData.swift" "$ROOT/Sources/Models.swift" "$ROOT/Sources/CLI.swift" "$ROOT/Sources/Store.swift" "$ROOT/Tests/CoreTests.swift" -o "$BUILD/tests"
"$BUILD/tests"
