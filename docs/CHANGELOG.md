# Changelog

## 1.0.0 - 2026-10-02

- Simplified headless startup to one per-user login item that silently starts
  `Sidecar Auto Setup.app`; the app then prepares the built-in virtual display
  after the desktop session is ready.
- Added a guarded “登录后静默启动 Sidecar Auto” setting, cleanup for the
  previous development login item, and a check that the app is installed in
  `/Applications` before enabling launch-on-login.
- Added regression coverage for headless preparation with a physical display,
  an already-online helper, and the disabled configuration path.
- Hardened login startup with a session-ready wrapper, explicit `HOME`/`PATH`,
  crash retry, and App-side retries when WindowServer or the virtual-display
  helper is still settling.
- Added an in-app GitHub Releases update checker and arm64 DMG downloader.
- Fixed a macOS `FileHandle` output-reader race that could crash the setup app while
  a helper process was finishing, normalized legacy literal `$HOME` executable paths
  so `sidecarctl` remains discoverable after upgrades, and auto-repaired stale runtime
  scripts before a manual connect or disconnect.
- Made login-after-start explicit and required for no-monitor mode; the
  environment check now treats it as a required prerequisite when the built-in
  virtual display is selected.
- Updated the user guide, English overview, configuration examples, and
  troubleshooting steps to describe the single-app startup flow.

- Consolidated shared runtime helpers for connection, disconnection and the
  post-login announcement. Logs now rotate at about 1 MiB, and the bundled
  app and source installer deploy the helper as part of the runtime payload.
- Fixed the menu-bar recovery path by keeping a scene-scoped openWindow
  action in the app delegate. Closing the settings window no longer leaves
  “打开设置” without a window to show. Reorganized the environment page into
  a current wired/wireless readiness card, required checks, and a collapsed
  optional diagnostics section so FileVault, Shortcuts, BetterDisplay and
  non-required privacy items cannot inflate or obscure connection readiness.
- Bluetooth permission requests are now user-triggered only. The app records
  that it has already requested access and opens the Bluetooth privacy pane
  instead of repeatedly creating a new authorization prompt.
- Improved Bluetooth status reconciliation after returning from System Settings:
  the app reads CoreBluetooth authorization on the main queue and performs a
  non-prompting manager callback check when macOS has not refreshed the cached
  result. The optional diagnostics section now keeps only the shortcut status,
  combined startup-security rows, BetterDisplay inspection and login notice.
- When a user has already opened Bluetooth settings, returning to the app now
  performs one explicit synchronization probe. This handles the macOS state
  where the System Settings switch is on but CoreBluetooth still reports
  notDetermined; startup and ordinary refreshes still never create a manager.

- Added a read-only BetterDisplay inspection panel, cancellable manual operations
  with live diagnostic-tail updates. Cancellation now terminates the active
  controller's child processes and the log view is scoped to the current run;
  the UI no longer reports a cancelled operation as a success. Added a repeatable
  signed release script for notarized DMG production.

- Added a visual USB iPad candidate picker for setups with multiple connected
  iPads, so users can select a serial number in the app instead of copying it
  from the IORegistry.

- Added deterministic controller integration tests for transport selection,
  wireless preflight, ambiguous USB refusal, and action-lock cleanup. Failed or
  cancelled headless connections now reclaim virtual fallback displays created
  by that operation while preserving user-owned displays.

- Added an in-app optional login-agent toggle. It reports whether the current
  user's post-login desktop announcement is loaded and can enable or disable
  it without starting Sidecar or touching iPad state.

- Added a menu-bar extra and app-delegate window lifecycle handling. Closing
  the settings window now keeps the app reachable, with menu actions for
  opening settings, one-shot connect/disconnect, cancellation, and quit.

- Added a first-run configuration wizard, USB iPad scanning with automatic target
  field filling, separate Mac/iPad readiness messaging, and live connection-stage
  feedback in the manual test view.
- Added safe USB detector regression tests to CI.

- Prepared a clean public source distribution for Sidecar Auto.
- Added the native SwiftUI `Sidecar Auto Setup.app` build, with a visual
  configuration guide, prebuilt runtime resources, status checks, and explicit
  one-shot connect/disconnect controls.
- Added universal App packaging, DMG creation, release signing guidance, and a
  security model that separates Bluetooth authorization from radio state and
  documents FileVault, Handoff, Shortcuts, and BetterDisplay limits.
- Added a documented one-command installer, read-only doctor, USB transport
  detection, wireless preflight and headless BetterDisplay setup.
- Removed generated binaries, logs and machine-specific identifiers from the
  source distribution.
- Documented licensing and attribution for the retained `sidecarctl` source.
- Added the built-in resident virtual-display helper with `auto`, `builtin`,
  and `betterdisplay` backend selection. The built-in profile is intentionally
  fixed and its undocumented macOS API compatibility is called out.
- Redesigned the setup app with a sidebar workflow, a focused overview, grouped
  device/display/shortcut settings, clearer status pills, one-shot test controls,
  and a bundled Sidecar Auto app icon.
- Added an explicit Bluetooth permission flow: the app triggers the native macOS
  confirmation only after the user clicks, refreshes after returning from Settings,
  and avoids requesting unnecessary Accessibility or Screen Recording access.
- Added one-click Shortcut template generation: the app installs the local helper,
  signs the two shell-action templates, and opens Apple's confirmation flow one at a
  time. Added the current macOS 27 AirDrop/Handoff settings deep link and separate
  FileVault and automatic-login guidance.

## 2026-09-30

- Added the `sidecarctl snapshot` path used by the one-shot controllers.
- Added explicit USB (`ForceUSB`) and direct wireless (`ForceAWDL`) selection.
- Added audible and Chinese speech feedback for progress, success and failure.
- Added conservative guards against unknown state, duplicate device names and
  taking over another active iPad session.

This project follows calendar dates for release notes. A release is only
considered wireless or headless verified when the README records the exact
hardware, macOS version and test conditions.
