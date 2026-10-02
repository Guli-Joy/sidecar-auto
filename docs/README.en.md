# Sidecar Auto

> Connect an iPad as a Mac display with one macOS Shortcut.

[![CI](https://github.com/Guli-Joy/sidecar-auto/actions/workflows/ci.yml/badge.svg)](https://github.com/Guli-Joy/sidecar-auto/actions/workflows/ci.yml)
[![Latest release](https://img.shields.io/github/v/release/Guli-Joy/sidecar-auto?display_name=tag)](https://github.com/Guli-Joy/sidecar-auto/releases)
[![macOS](https://img.shields.io/badge/macOS-13%2B-111827)](#requirements)
[![License](https://img.shields.io/badge/license-MIT-2563eb)](../LICENSE)

Sidecar Auto is built for people who use an iPad as a Mac display, especially Mac mini setups without a permanent monitor. It checks the current state, chooses USB or direct wireless transport, prepares a headless display when needed, and verifies that the Sidecar picture is actually online.

## Core capabilities

| Need | Experience |
| --- | --- |
| iPad data cable connected | Prefers a wired connection and skips unnecessary wireless setup. |
| No cable connected | Prepares Wi‑Fi, Bluetooth, and Handoff before trying wireless mode. |
| No physical monitor | Starts the built-in virtual screen or an optional BetterDisplay backend. |
| Temporary or repeated use | Runs only after an explicit click or Shortcut action; it never retries forever in the background. |

Every action is explicit, bounded, and single-shot. The controller does not retry forever or connect in the background.

## Download

Download the latest DMG from [GitHub Releases](https://github.com/Guli-Joy/sidecar-auto/releases). The first stable release is [v1.0.0](https://github.com/Guli-Joy/sidecar-auto/releases/tag/v1.0.0), with an Apple Silicon (arm64) installer.

The app's Overview page includes **Check for Updates**. It reads GitHub Releases and, when a newer arm64 build is available, downloads the DMG to your Downloads folder. Open the DMG, drag the new app to Applications, and relaunch it.

If macOS blocks the first launch, open **System Settings → Privacy & Security** and allow the app to open. Depending on the macOS version, the control may be shown as **Allow applications from anywhere** or **Open Anyway**.

For a source installation, macOS 13+ and Xcode Command Line Tools are required:

```sh
git clone https://github.com/Guli-Joy/sidecar-auto.git
cd sidecar-auto
./installer/install-sidecar-auto.sh
```

## Quick start

1. Open `Sidecar Auto Setup.app` and click **Install / Repair**.
2. Click **Refresh** and confirm the target iPad and display checks.
3. Use **Configure Shortcuts** and accept the macOS import prompts.
4. Run **Connect Sidecar** from Shortcuts.
5. Run **Disconnect Sidecar** when the session should end.

The command-line entries are:

```sh
"$HOME/.local/bin/sidecar-connect-once.sh" auto
"$HOME/.local/bin/sidecar-disconnect-once.sh"
```

Use `wired` or `wireless` instead of `auto` when troubleshooting a specific transport.

## Requirements

- macOS 13 or later.
- A Sidecar-compatible Mac and iPad using the same Apple Account with two-factor authentication.
- A trusted, data-capable USB cable for wired mode.
- Wi‑Fi, Bluetooth, and Handoff enabled on both devices for wireless mode.
- An awake and unlocked iPad. Sidecar cannot create a screen session at the login or FileVault unlock screen.

## Headless mode

The default `auto` provider prefers the built-in 1920×1080, 60 Hz virtual screen. It does not require BetterDisplay, but it relies on undocumented macOS virtual-display APIs.

On a Mac without a physical monitor, **Start Sidecar Auto quietly after login** is required. The app must start in the logged-in desktop session before it can create the virtual screen that lets the iPad become the main display. Enable it in Connection Settings and save the configuration; it never connects or disconnects Sidecar by itself.

Choose BetterDisplay when you need HiDPI, additional resolutions, or advanced layouts:

```sh
VIRTUAL_DISPLAY_BACKEND="betterdisplay"
VIRTUAL_DISPLAY_NAME="SidecarHeadlessFallback"
```

Supported providers are `auto`, `builtin`, and `betterdisplay`. Failed or cancelled operations clean up only the virtual display created by that operation.

## Configuration

The installer creates `~/.config/sidecar-auto/config` and preserves an existing file:

```sh
IPAD_NAME="iPad"
# IPAD_USB_SERIAL_NUMBER=""
AUTO_ENABLE_HANDOFF=1
# Start the app quietly after login; prepare a virtual screen when headless.
AUTO_START_HEADLESS_DISPLAY=1
VIRTUAL_DISPLAY_BACKEND="auto"
VIRTUAL_DISPLAY_NAME="SidecarHeadlessFallback"
```

Runtime scripts accept only allowlisted fields. The file must be owned by the current user and must not be writable by the group or other users; its contents are never executed as shell code.

## Diagnostics

These commands are read-only:

```sh
"$HOME/.local/bin/sidecar-doctor.sh"
"$HOME/.local/bin/sidecarctl" snapshot
```

Logs stay in `~/Library/Logs/sidecar-auto.log` and rotate automatically. When multiple iPads are connected, set both the exact `IPAD_NAME` and the target `IPAD_USB_SERIAL_NUMBER`.

## User documentation

- [App guide](APP_GUIDE.md): download, setup, permissions, and daily use.
- [Troubleshooting](TROUBLESHOOTING.md): USB, wireless, display, and permission issues.
- [Security model](SECURITY_MODEL.md): local data, configuration boundaries, and macOS permissions.

## Limitations and privacy

Sidecar Auto calls Apple's private `SidecarCore` API. The built-in virtual screen uses undocumented macOS APIs and may need updates after a system release. The project collects no telemetry, uploads no configuration or logs, and does not bypass BetterDisplay licensing, TCC permissions, FileVault, or macOS security controls.

The automation code is MIT licensed. The retained upstream `sidecarctl` source keeps its own MIT notice; see [NOTICE.md](NOTICE.md).
