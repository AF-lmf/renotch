#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"

cd "$PROJECT_DIR"
mkdir -p "$PROJECT_DIR/.build"

# The AI usage tests run hermetically: temporary directories, an in-memory
# secret store and a fake DeepSeek server. Refuse to build them if one reaches
# for the real Keychain, home directory or network.
if grep -nE 'KeychainSecretStore|AIUsageEnvironment\.live|ClaudeBridgePaths\.live|homeDirectoryForCurrentUser|NSHomeDirectory|liveFetch' \
    Tests/AIUsageFormattingTests.swift \
    Tests/CodexUsageTests.swift \
    Tests/ClaudeBridgeTests.swift \
    Tests/DeepSeekBalanceTests.swift \
    Tests/AppModelAIUsageTests.swift \
    Tests/Support/AIUsageTestDoubles.swift; then
    echo 'AI usage tests must not use live stores, paths or network' >&2
    exit 1
fi

AI_USAGE_SOURCES=(
    Sources/Renotch/Models/NotchModels.swift
    Sources/Renotch/AIUsage/**/*.swift
    Tests/Support/AIUsageTestDoubles.swift
)

for TEST_NAME in AIUsageFormattingTests CodexUsageTests ClaudeBridgeTests DeepSeekBalanceTests; do
    TEST_BINARY="$PROJECT_DIR/.build/renotch-${TEST_NAME}"
    swiftc \
        -swift-version 5 \
        "${AI_USAGE_SOURCES[@]}" \
        "Tests/${TEST_NAME}.swift" \
        -framework Security \
        -o "$TEST_BINARY"
    "$TEST_BINARY" "$PROJECT_DIR/Tests/Fixtures"
done
