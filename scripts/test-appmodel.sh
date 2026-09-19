#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"

cd "$PROJECT_DIR"

APP_MODEL_SOURCES=(
    Sources/Renotch/Models/NotchModels.swift
    Sources/Renotch/Models/BrowserActivityModels.swift
    Sources/Renotch/Models/DeveloperActivityGlance.swift
    Sources/Renotch/Services/SettingsStore.swift
    Sources/Renotch/Services/TimerService.swift
    Sources/Renotch/Services/ShelfStore.swift
    Sources/Renotch/Services/TodoStore.swift
    Sources/Renotch/Services/MusicService.swift
    Sources/Renotch/Services/BrowserActivityService.swift
    Sources/Renotch/Services/DeveloperActivityService.swift
    Sources/Renotch/Services/AppleCalendarService.swift
    Sources/Renotch/Services/LaunchAtLoginService.swift
    Sources/Renotch/Services/NotificationService.swift
    Sources/Renotch/Services/FocusBlockerService.swift
    Sources/Renotch/System/**/*.swift
    Sources/Renotch/AIUsage/**/*.swift
    Sources/Renotch/Window/FocusBlockerOverlayController.swift
    Sources/Renotch/State/AppModel.swift
    Tests/Support/AIUsageTestDoubles.swift
)

for TEST_NAME in AppModelFileDropTests AppModelSystemMetricsTests AppModelAIUsageTests CompactSystemLayoutTests; do
    TEST_BINARY="$PROJECT_DIR/.build/renotch-${TEST_NAME}"
    UI_SOURCES=()
    if [[ "$TEST_NAME" == CompactSystemLayoutTests ]]; then
        UI_SOURCES=(
            Sources/Renotch/UI/Compact/CompactSystemView.swift
            Sources/Renotch/UI/AIUsageView.swift
            Sources/Renotch/UI/Components/NotchComponents.swift
            Sources/Renotch/UI/Components/SystemMetricsComponents.swift
        )
    fi
    swiftc \
        -swift-version 5 \
        "${APP_MODEL_SOURCES[@]}" \
        "${UI_SOURCES[@]}" \
        "Tests/${TEST_NAME}.swift" \
        -framework AppKit \
        -framework EventKit \
        -framework IOKit \
        -framework Security \
        -framework ServiceManagement \
        -framework UserNotifications \
        -framework WebKit \
        -o "$TEST_BINARY"
    "$TEST_BINARY"
done
