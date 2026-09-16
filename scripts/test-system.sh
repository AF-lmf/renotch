#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
TEST_BINARY="$PROJECT_DIR/.build/renotch-system-tests"

cd "$PROJECT_DIR"
mkdir -p "$PROJECT_DIR/.build"
swiftc \
    -swift-version 5 \
    Sources/Renotch/System/**/*.swift \
    Tests/SystemMetricsTests.swift \
    -framework AppKit \
    -framework IOKit \
    -o "$TEST_BINARY"
"$TEST_BINARY"
