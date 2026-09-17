#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
TEST_BINARY="$PROJECT_DIR/.build/renotch-update-checker-tests"

cd "$PROJECT_DIR"
mkdir -p "$PROJECT_DIR/.build"
swiftc \
    -swift-version 5 \
    Sources/Renotch/Models/NotchModels.swift \
    Sources/Renotch/Services/NotificationService.swift \
    Sources/Renotch/Services/UpdateChecker.swift \
    Tests/UpdateCheckerTests.swift \
    -framework AppKit \
    -framework UserNotifications \
    -o "$TEST_BINARY"
"$TEST_BINARY"
