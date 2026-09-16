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
    Sources/Renotch/Window/FocusBlockerOverlayController.swift
    Sources/Renotch/State/AppModel.swift
)

for TEST_NAME in AppModelFileDropTests AppModelSystemMetricsTests; do
    TEST_BINARY="$PROJECT_DIR/.build/renotch-${TEST_NAME}"
    swiftc \
        -swift-version 5 \
        "${APP_MODEL_SOURCES[@]}" \
        "Tests/${TEST_NAME}.swift" \
        -framework AppKit \
        -framework EventKit \
        -framework IOKit \
        -framework ServiceManagement \
        -framework UserNotifications \
        -framework WebKit \
        -o "$TEST_BINARY"
    "$TEST_BINARY"
done
