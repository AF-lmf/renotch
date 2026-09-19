<div align="center">

<img src="public/renotch_logo.png" alt="Re:notch" width="120">

# Re:notch

Turn your Mac's notch into a lightweight, native developer command center.

[![macOS 13+](https://img.shields.io/badge/macOS-13%2B-black?logo=apple)](https://developer.apple.com/macos/)
[![Release](https://img.shields.io/github/v/release/yosaiy/renotch?label=release)](https://github.com/yosaiy/renotch/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE.md)

[**Upstream Releases**](https://github.com/yosaiy/renotch/releases/latest) • [**Fork Source**](https://github.com/AF-lmf/renotch/tree/feature/system-metrics)

</div>

---

## Features

This fork's `feature/system-metrics` branch adds:

- **System metrics**: CPU, GPU, memory, network, battery, temperature, fans and process activity, with a compact C/G/M/N display that adapts to the available width.
- **AI usage**: Codex limits from local logs, an opt-in Claude Code status-line bridge, and optional DeepSeek balance queries with the API key stored in macOS Keychain. Hidden AI views stop automatic polling.
- **Simplified Chinese UI** and update-check fixes. Automatic upstream update checks are disabled by default for this fork.

- **Dev Activity**: Track local servers, ports, Git status, Docker containers, and build jobs.

![Dev Activity](public/Dev-Activity.gif)

- **Media Control**: Apple Music & Spotify playback with album art and controls.

![Media Control](public/Music-Demo.gif)

- **Pomodoro + Website Blocker**: Stop doomscrolling mid-task. Renotch now lets you block specific websites during Pomodoro sessions so you actually get things done.

![Pomodoro + Website Blocker](public/Pomodoro.gif)

- **Browser Bridge**: YouTube playback and Chromium download monitor.
- **Native & Private**: Swift/SwiftUI, fluid animations, local settings, zero telemetry.

---

## Install

### Download
The **[upstream releases](https://github.com/yosaiy/renotch/releases/latest)** do not include this fork's changes. Build this branch as described below, then move `dist/Re:notch.app` to `/Applications`.

### Build from Source
```bash
git clone --branch feature/system-metrics https://github.com/AF-lmf/renotch.git
cd renotch
swift run Renotch
```

To build a standalone `.app` bundle:
```bash
./scripts/build-app.sh
```

The app bundle includes Apple Silicon and Intel binaries. `./scripts/build-zip.sh` also creates a ZIP in `dist/`. Without a configured signing identity, local builds use ad-hoc signing and are not notarized; rebuilding may require granting macOS permissions again.

Run the regression tests with `./scripts/test.sh`, including compact layout rendering and AI usage lifecycle checks.

---

## Browser Extension (Optional)

Enables YouTube and download tracking:
1. Open `chrome://extensions` in Chrome/Arc/Brave/Edge.
2. Enable **Developer mode**.
3. Click **Load unpacked** and select the `BrowserExtension` directory.

---

## Privacy

Re:notch has no app account, telemetry or cloud sync. System history and settings are stored locally. Codex limits are parsed from local logs; connecting Claude Code explicitly installs a local status-line bridge with a backup of the existing configuration. If you configure DeepSeek, its API key is stored in macOS Keychain and sent over HTTPS to `api.deepseek.com` to query your balance. Media artwork and manually requested upstream update checks can also access the network.

---

## License

MIT © [yosaiy](https://github.com/yosaiy)
