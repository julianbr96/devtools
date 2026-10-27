#!/bin/bash
# Compiles the non-UI sources with the tests into one binary and runs it.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="$(mktemp -d "${TMPDIR:-/tmp}/devtools-test.XXXXXX")"
trap 'rm -rf "$BUILD"' EXIT
swiftc -swift-version 5 -parse-as-library -module-cache-path "$BUILD/ModuleCache" \
  "$ROOT/Sources/Core/ProcessRunner.swift" "$ROOT/Sources/Core/DashboardError.swift" \
  "$ROOT/Sources/Tools/CSWAP/LocalData.swift" "$ROOT/Sources/Tools/CSWAP/Models.swift" \
  "$ROOT/Sources/Tools/CSWAP/CLI.swift" "$ROOT/Sources/Tools/CSWAP/Store.swift" \
  "$ROOT/Sources/Tools/VPN/VPN.swift" "$ROOT/Sources/Tools/VPN/VPNStore.swift" \
  "$ROOT/Sources/Tools/Machine/Machine.swift" "$ROOT/Sources/Tools/Machine/MachineStore.swift" \
  "$ROOT/Sources/Tools/Logins/AWS.swift" "$ROOT/Sources/Tools/Logins/AWSStore.swift" "$ROOT/Sources/Tools/Logins/CLILogins.swift" \
  "$ROOT"/Tests/*.swift -o "$BUILD/tests"
"$BUILD/tests"
