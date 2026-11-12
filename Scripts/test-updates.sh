#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/test-cache
swiftc -module-cache-path build/test-cache Scripts/verify-update.swift -o build/verify-update
swift -module-cache-path build/test-cache Tests/UpdateSignatureTests.swift "$PWD/build/verify-update"
